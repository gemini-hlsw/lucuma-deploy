#!/usr/bin/env bash

# Usage: rollback.sh <env> [<bundle-id>] [--dry-run] [--skip-slack] [--debug]
# Example: rollback.sh production                         (list the bundles)
# Example: rollback.sh production 2026-10-30T14-37-37Z --dry-run
#
# Rolls an environment back to the systems recorded in one of its bundles: Heroku images, Firebase
# versions of the Firebase systems, the S3 build of the systems on AWS, and the Observe and
# Navigate tags (which the operator deploys by hand with `observe update` / `navigate update`).
# Database migrations are never undone, and Hasura is not touched. Writes a new bundle recording
# the rollback, and commits and pushes it.

set -euo pipefail

# Bundles older than this are removed from the tree (they stay in git history).
BUNDLE_RETENTION_MONTHS=6

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$SCRIPT_DIR

# The aws cli would page its output through less in a terminal.
export AWS_PAGER=""

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/systems.sh
source "$SCRIPT_DIR/lib/systems.sh"
# shellcheck source=lib/github.sh
source "$SCRIPT_DIR/lib/github.sh"
# shellcheck source=lib/heroku.sh
source "$SCRIPT_DIR/lib/heroku.sh"
# shellcheck source=lib/firebase.sh
source "$SCRIPT_DIR/lib/firebase.sh"
# shellcheck source=lib/aws.sh
source "$SCRIPT_DIR/lib/aws.sh"
# shellcheck source=lib/slack.sh
source "$SCRIPT_DIR/lib/slack.sh"
# shellcheck source=lib/bundle.sh
source "$SCRIPT_DIR/lib/bundle.sh"

usage() {
  echo "Usage: rollback.sh <env> [<bundle-id>] [--dry-run] [--skip-slack] [--debug]"
  echo "  <env> is staging or production. Without a bundle id, lists the bundles of <env>."
  exit 1
}

parse_args "$@" || usage
if [ ${#POSITIONAL[@]} -lt 1 ] || [ ${#POSITIONAL[@]} -gt 2 ]; then
  usage
fi
ENV=${POSITIONAL[0]}
TARGET_ID=${POSITIONAL[1]:-}

if [ "$ENV" != "staging" ] && [ "$ENV" != "production" ]; then
  echo "Error: Invalid environment '$ENV'. Must be staging or production."
  exit 1
fi

BUNDLE_DIR="$REPO_ROOT/bundles/$ENV"

# Without a bundle id: list the bundles, newest first, and stop.
if [ -z "$TARGET_ID" ]; then
  require_tools git jq
  # Best effort: a stale list is still useful, the real run does the strict preflight.
  git -C "$REPO_ROOT" pull --ff-only --quiet 2> /dev/null \
    || echo "(could not update $REPO_ROOT, the list may be stale)"
  echo "Bundles of $ENV (newest first):"
  found=false
  while IFS= read -r file; do
    found=true
    jq -r '"  \(.id)  \(.created_at)  "
           + (if .rollback_of != null then "rollback of \(.rollback_of)" else "from \(.source)" end)
           + "  changed: "
           + ([.systems | to_entries[] | select(.value.changed) | .key] | if length == 0 then "none" else join(" ") end)' \
      "$file"
  done < <(find "$BUNDLE_DIR" -maxdepth 1 -name '*.json' ! -name 'current.json' 2> /dev/null | sort -r)
  if [ "$found" = false ]; then
    echo "  (none)"
  fi
  echo
  echo "To roll back, re-run with the desired bundle id: rollback.sh $ENV <bundle-id>"
  exit 1
fi

if ! [[ "$TARGET_ID" =~ $BUNDLE_ID_PATTERN ]]; then
  echo "Error: '$TARGET_ID' is not a bundle id (YYYY-MM-DDTHH-MM-SSZ)"
  exit 1
fi

require_tools git gh jq curl heroku firebase aws
repo_preflight "$REPO_ROOT"
github_auth
print_env_status
resolve_promoter

TARGET_FILE="$BUNDLE_DIR/$TARGET_ID.json"
CURRENT_FILE="$BUNDLE_DIR/current.json"
[ -f "$TARGET_FILE" ] || die "No bundle $TARGET_ID in bundles/$ENV"
[ -f "$CURRENT_FILE" ] || die "No bundles/$ENV/current.json"

TARGET_BUNDLE=$(jq -c '.' "$TARGET_FILE")
CURRENT_BUNDLE=$(jq -c '.' "$CURRENT_FILE")
CURRENT_ID=$(echo "$CURRENT_BUNDLE" | jq -r '.id')

# Field of a system in a bundle, as a string (objects as compact JSON), or "none".
bundle_field() {
  echo "$1" | jq -r --arg s "$2" --arg f "$3" \
    '.systems[$s][$f] // null | if . == null then "none" elif type == "string" then . else tojson end'
}

# The identifier that decides whether a system changes, per kind.
identifier_field() {
  if is_docker_system "$1"; then
    echo "docker_image_shas"
  elif is_firebase_system "$1"; then
    echo "firebase_version"
  elif is_aws_system "$1"; then
    echo "s3_build"
  else
    echo "docker_tag"
  fi
}

declare -A target_sha
declare -A target_ident
declare -A target_s3_build
declare -A changed
declare -A live_version

echo "##### Rolling $ENV back from bundle $CURRENT_ID to bundle $TARGET_ID"
echo
ANY_CHANGE=false
for system in "${all_systems[@]}"; do
  field=$(identifier_field "$system")
  target_sha["$system"]=$(bundle_field "$TARGET_BUNDLE" "$system" "sha")
  target_ident["$system"]=$(bundle_field "$TARGET_BUNDLE" "$system" "$field")
  current_ident=$(bundle_field "$CURRENT_BUNDLE" "$system" "$field")

  if [ "${target_sha["$system"]}" = "none" ] || [ "${target_ident["$system"]}" = "none" ]; then
    die "Bundle $TARGET_ID has no $field for $system - cannot roll back to it"
  fi
  if is_docker_system "$system"; then
    check_image_shas "$system" "${target_ident["$system"]}" "bundle $TARGET_ID"
    # Compare as JSON so key order does not matter.
    if [ "$current_ident" != "none" ] \
      && [ "$(jq -n --argjson a "${target_ident["$system"]}" --argjson b "$current_ident" '$a == $b')" = true ]; then
      changed["$system"]=false
    else
      changed["$system"]=true
    fi
  elif [ "${target_ident["$system"]}" = "$current_ident" ]; then
    changed["$system"]=false
  else
    changed["$system"]=true
  fi

  if [ "${changed["$system"]}" = true ]; then
    ANY_CHANGE=true
    echo "  • $system: $current_ident → ${target_ident["$system"]}"
  else
    echo "    $system: unchanged"
  fi
done
echo

# A changed AWS system is restored from the build archive, so its build must be there. Checked
# before anything is touched or confirmed. The change itself was detected above by comparing the
# s3_build of the target bundle with the one of the current bundle. Dev is not a rollback target
# (only staging and production are accepted above) because no bundle is ever written for it: the
# CI deploys dev on every merge, and that is how it is restored.
for system in "${aws_systems[@]}"; do
  if [ "${changed["$system"]}" = true ]; then
    # The s3_build is the identifier that decides the change, already checked above, so a bundle
    # without one was refused there.
    target_s3_build["$system"]=${target_ident["$system"]}
    archive=$(aws_archive_url "$system" "${target_s3_build["$system"]}")
    if ! aws_archive_exists "$archive"; then
      echo "Error: Build ${target_s3_build["$system"]} of $system (bundle $TARGET_ID) is not archived at $archive;"
      echo "it cannot be restored on AWS. Nothing was changed."
      exit 1
    fi
  fi
done

if [ "$ANY_CHANGE" = false ]; then
  echo "##### $ENV already runs what bundle $TARGET_ID records - nothing to roll back."
  exit 0
fi

# The databases only move forward, so compare the target's numbers with the highest ever recorded
# for this environment, not just with the current bundle.
MAX_MIGRATIONS=$(bundle_max_migrations "$BUNDLE_DIR")
TARGET_MIGRATIONS=$(echo "$TARGET_BUNDLE" | jq -c '.migrations // {}')
echo "##### Migration check"
SCHEMA_AHEAD=false
for db in "${databases[@]}"; do
  target_n=$(echo "$TARGET_MIGRATIONS" | jq -r --arg d "$db" '.[$d] // "none"')
  current_n=$(echo "$MAX_MIGRATIONS" | jq -r --arg d "$db" '.[$d] // "none"')
  if [ "$target_n" = "none" ] || [ "$current_n" = "none" ]; then
    echo "  ? $db: unknown (target $target_n, current $current_n)"
  elif [ "$target_n" -lt "$current_n" ]; then
    SCHEMA_AHEAD=true
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  !!! WARNING: $db schema is AHEAD of the build being rolled back to."
    echo "  !!! The database is at migration $current_n, bundle $TARGET_ID was built for $target_n."
    echo "  !!! This rollback WILL NOT undo the migrations. Make sure the older build works"
    echo "  !!! with the newer schema."
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  else
    echo "  ✓ $db: $target_n (database at $current_n)"
  fi
done
if [ "$SCHEMA_AHEAD" = false ]; then
  echo "  No database is ahead of the target bundle."
fi
echo

build_bundle() {
  bundle_new_id
  bundle_reset_systems
  local system
  for system in "${all_systems[@]}"; do
    local sha=${target_sha["$system"]}
    local c=${changed["$system"]}
    if is_docker_system "$system"; then
      bundle_add_heroku "$system" "$sha" "$c" "$(get_heroku_app "$system" "$ENV")" "${target_ident["$system"]}"
    elif is_firebase_system "$system"; then
      bundle_add_firebase "$system" "$sha" "$c" "$(get_firebase_site "$system" "$ENV")" \
        "${live_version["$system"]:-${target_ident["$system"]}}"
    elif is_aws_system "$system"; then
      bundle_add_aws "$system" "$sha" "$c" "$(get_aws_bucket "$system" "$ENV")" \
        "$(get_aws_distribution "$system" "$ENV")" "${target_ident["$system"]}"
    else
      bundle_add_manual "$system" "$sha" "$c" "${target_ident["$system"]}"
    fi
  done
  BUNDLE_JSON=$(bundle_build "$ENV" "" "$TARGET_ID" "$PROMOTER" "$TARGET_MIGRATIONS")
}

# A dry run stops before the confirmation: it changes nothing, so there is nothing to confirm.
if [ "$DRY_RUN" = true ]; then
  echo "##### DRY RUN MODE - nothing will be changed"
  for system in "${all_systems[@]}"; do
    if [ "${changed["$system"]}" = true ]; then
      echo "  Would roll back $system to ${target_sha["$system"]} (${target_ident["$system"]})"
    fi
  done
  echo
  echo "##### Bundle that would be written to bundles/$ENV/:"
  build_bundle
  echo "$BUNDLE_JSON"
  exit 0
fi

reply=""
read -r -p "Type the environment name ($ENV) to roll it back to bundle $TARGET_ID: " reply || true
echo
if [ "$reply" != "$ENV" ]; then
  echo "Aborted: confirmation did not match '$ENV'. Nothing was changed."
  exit 1
fi


record_rollback() {
  local system=$1
  local payload=""
  if is_docker_system "$system"; then
    payload=$(jq -nc --argjson shas "${target_ident["$system"]}" '{docker_image_shas: $shas}')
  elif is_manual_system "$system"; then
    payload=$(jq -nc --arg tag "${target_ident["$system"]}" '{docker_tag: $tag}')
  fi
  local deploy_env
  deploy_env=$(get_github_deploy_env "$system" "$ENV")
  github_record_deployment "$system" "${target_sha["$system"]}" "$deploy_env" "$deploy_env" \
    "Rollback to bundle $TARGET_ID" "$payload"
}

echo "##### Rolling back $ENV to bundle $TARGET_ID"
if [ "$SKIP_SLACK" = true ]; then
  echo "Slack notifications: DISABLED (--skip-slack flag)"
else
  echo "Slack notifications: ENABLED"
fi
echo

for system in "${all_systems[@]}"; do
  if [ "${changed["$system"]}" != true ]; then
    continue
  fi
  echo "## Roll back $system"
  if is_docker_system "$system"; then
    app=$(get_heroku_app "$system" "$ENV")
    read -r -a proc_types <<< "${process_types["$system"]}"
    for process_type in "${proc_types[@]}"; do
      image=$(image_for_process "${target_ident["$system"]}" "$process_type")
      echo "  Deploying ${app}/${process_type} -> $image"
      heroku_patch_formation "$app" "$process_type" "$image" "$ENV"
    done
  elif is_firebase_system "$system"; then
    site=$(get_firebase_site "$system" "$ENV")
    firebase_clone "$site@${target_ident["$system"]}" "$site:live" "${firebase_project["$system"]}" "$system"
  elif is_aws_system "$system"; then
    aws_deploy_build "$(aws_archive_url "$system" "${target_s3_build["$system"]}")" \
      "$(get_aws_bucket "$system" "$ENV")" "$system (S3)"
    aws_invalidate "$(get_aws_distribution "$system" "$ENV")" "$system (CloudFront)"
  else
    echo "  Run on the GN and GS $ENV $system servers:"
    echo "      $(get_manual_command "$system")    (deploys ${target_ident["$system"]})"
  fi
  echo "  Recording deployment to GitHub..."
  record_rollback "$system"
  send_rollback_slack_notification "$system" "$ENV" "${target_sha["$system"]}" "$TARGET_ID" \
    "${target_ident["$system"]}"
  echo
done

echo "##### Writing the $ENV bundle"
for system in "${firebase_systems[@]}"; do
  site=$(get_firebase_site "$system" "$ENV")
  firebase_live_version "$site" "${firebase_project["$system"]}"
  live_version["$system"]=$FIREBASE_VERSION
  echo "  $system live version on $site: $FIREBASE_VERSION"
done
build_bundle
bundle_write "$BUNDLE_DIR" "$BUNDLE_JSON"
bundle_prune "$REPO_ROOT" "$ENV" "$BUNDLE_RETENTION_MONTHS"
bundle_commit_push "$REPO_ROOT" "$ENV" "bundle: $ENV $BUNDLE_ID (rollback of $TARGET_ID)"
slack_send_text "$(bundle_slack_message "$ENV" "$BUNDLE_ID")"
echo

PENDING=false
for system in "${manual_systems[@]}"; do
  if [ "${changed["$system"]}" = true ]; then
    if [ "$PENDING" = false ]; then
      echo "Manual steps still pending:"
      PENDING=true
    fi
    echo "  $system (on the GN and GS $ENV servers):"
    echo "      $(get_manual_command "$system")    (deploys ${target_ident["$system"]})"
  fi
done
