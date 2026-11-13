#!/usr/bin/env bash

# Usage: promote.sh <source_env> <target_env> [--dry-run] [--skip-slack] [--debug]
#        promote.sh --snapshot <env> [--dry-run] [--skip-slack] [--debug]
# Example: promote.sh dev staging
# Example: promote.sh dev staging --dry-run --debug
# Example: promote.sh dev staging --skip-slack
# Example: promote.sh --snapshot staging
#
# Promotes every system whose deployment record in the source environment differs from the
# target's, records the new deployments on GitHub, then writes a bundle (the snapshot of the target
# environment) under bundles/<target_env>/ and commits and pushes it.
#
# Observe and Navigate run on private servers and are updated by hand with `observe update` /
# `navigate update`, which deploy the tag in the environment's current bundle. This script does
# NOT deploy them: it records the GitHub deployment, sends the Slack message and prints the
# command the operator must run.
#
# With --snapshot nothing is promoted: the script only writes a bundle of what <env> runs now, so
# that state can be rolled back to. Use it before the first promotion from this repo, or after
# an environment was changed by other means.

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
# shellcheck source=lib/hasura.sh
source "$SCRIPT_DIR/lib/aws.sh"
# shellcheck source=lib/hasura.sh
source "$SCRIPT_DIR/lib/hasura.sh"
# shellcheck source=lib/slack.sh
source "$SCRIPT_DIR/lib/slack.sh"
# shellcheck source=lib/bundle.sh
source "$SCRIPT_DIR/lib/bundle.sh"

usage() {
  echo "Usage: promote.sh <source_env> <target_env> [--dry-run] [--skip-slack] [--debug]"
  echo "       promote.sh --snapshot <env> [--dry-run] [--skip-slack] [--debug]"
  echo "Example: promote.sh dev staging"
  echo "Example: promote.sh dev staging --dry-run"
  echo "Example: promote.sh dev staging --skip-slack"
  echo "Example: promote.sh dev staging --dry-run --skip-slack"
  echo "Example: promote.sh --snapshot staging"
  exit 1
}

parse_args "$@" || usage
if [ "$SNAPSHOT" = true ]; then
  if [ ${#POSITIONAL[@]} -ne 1 ]; then
    usage
  fi
  # Reading the environment as its own source makes every system unchanged, so the bundle carries
  # exactly what the environment's records and live sites say.
  SOURCE_ENV=${POSITIONAL[0]}
  TARGET_ENV=${POSITIONAL[0]}
  # Only the environments that can be rolled back have bundles.
  if [ "$TARGET_ENV" != staging ] && [ "$TARGET_ENV" != production ]; then
    echo "Error: a snapshot can only be taken of staging or production"
    echo "Provided: '$TARGET_ENV'"
    exit 1
  fi
else
  if [ ${#POSITIONAL[@]} -ne 2 ]; then
    usage
  fi
  SOURCE_ENV=${POSITIONAL[0]}
  TARGET_ENV=${POSITIONAL[1]}

  # Validate environment names against allowlist
  if ! is_valid_env "$SOURCE_ENV" || ! is_valid_env "$TARGET_ENV"; then
    echo "Error: Invalid environment names. Must be one of: ${VALID_ENVS[*]}"
    echo "Provided: SOURCE_ENV='$SOURCE_ENV', TARGET_ENV='$TARGET_ENV'"
    exit 1
  fi
  if [ "$SOURCE_ENV" = "$TARGET_ENV" ]; then
    echo "Error: source and target environments must differ"
    exit 1
  fi
fi

require_tools git gh jq curl heroku firebase aws hasura
repo_preflight "$REPO_ROOT"
github_auth
print_env_status
resolve_promoter

# Per-system state, filled by set_system_vars. source_* is what will be deployed, target_* is
# what the target environment runs now.
declare -A source_sha
declare -A target_sha
declare -A docker_image_shas_object
declare -A target_image_shas
declare -A docker_tag
declare -A target_docker_tag
declare -A promote
declare -A backup_id
declare -A live_version
declare -A migrations

PROMOTE_HASURA=false

set_system_vars() {
  local system
  for system in "${all_systems[@]}"; do
    echo "Checking for $system changes..."

    github_get_deployment "$system" "$SOURCE_ENV"
    local source_record=$GH_RECORD
    source_sha["$system"]=$(record_sha "$source_record")

    if [[ "${source_sha["$system"]}" == "none" ]]; then
      echo "  ! Source SHA for $system in $SOURCE_ENV is not set - cannot proceed."
      exit 1
    fi

    if is_docker_system "$system"; then
      docker_image_shas_object["$system"]=$(record_image_shas "$source_record")
      if [[ "${docker_image_shas_object["$system"]}" == "none" ]]; then
        echo "  ! Docker image SHAs for $system in $SOURCE_ENV are not set - cannot proceed."
        exit 1
      fi
      check_image_shas "$system" "${docker_image_shas_object["$system"]}" "$SOURCE_ENV"
    fi

    if is_manual_system "$system"; then
      docker_tag["$system"]=$(record_docker_tag "$source_record")
      if [[ -z "${docker_tag["$system"]}" ]] || [[ "${docker_tag["$system"]}" == "none" ]]; then
        echo "  ! Docker tag for $system in $SOURCE_ENV is not set - cannot proceed."
        exit 1
      fi
    fi

    github_get_deployment "$system" "$TARGET_ENV"
    local target_record=$GH_RECORD
    target_sha["$system"]=$(record_sha "$target_record")

    if [ "${target_sha["$system"]}" = "none" ] || [ "${source_sha["$system"]}" != "${target_sha["$system"]}" ]; then
      promote["$system"]=true
    else
      promote["$system"]=false
    fi

    # An unchanged system goes into the bundle with what the target runs, which is in its record.
    if [ "${promote["$system"]}" = false ]; then
      if is_docker_system "$system"; then
        target_image_shas["$system"]=$(record_image_shas "$target_record")
        if [ "${target_image_shas["$system"]}" = "none" ]; then
          echo "  ! Docker image SHAs for $system in $TARGET_ENV are not set - cannot proceed."
          exit 1
        fi
        check_image_shas "$system" "${target_image_shas["$system"]}" "$TARGET_ENV"
      fi
      if is_manual_system "$system"; then
        target_docker_tag["$system"]=$(record_docker_tag "$target_record")
        if [ "${target_docker_tag["$system"]}" = "none" ]; then
          echo "  ! Docker tag for $system in $TARGET_ENV is not set - cannot proceed."
          exit 1
        fi
      fi
    fi
  done
}

# The sha a system will be at once the promotion is done.
final_sha() {
  if [ "${promote["$1"]}" = true ]; then
    echo "${source_sha["$1"]}"
  else
    echo "${target_sha["$1"]}"
  fi
}

# Migration numbers the promoted builds carry: Flyway from the lucuma-odb tree at the sha of the
# system that runs each database's migrations, user_prefs from the Hasura checkout.
read_migration_numbers() {
  echo "Reading migration numbers..."
  local db
  for db in "${flyway_databases[@]}"; do
    github_flyway_number "$(final_sha "${flyway_system["$db"]}")" "${flyway_prefix["$db"]}"
    migrations["$db"]=$FLYWAY_NUMBER
  done
  hasura_user_prefs_number
  migrations["user_prefs"]=$USER_PREFS_NUMBER
  for db in "${databases[@]}"; do
    echo "  $db: ${migrations["$db"]}"
  done
  echo
}

migrations_json() {
  local json='{}'
  local db
  for db in "${databases[@]}"; do
    json=$(echo "$json" | jq -c --arg k "$db" --argjson v "${migrations["$db"]}" '. + {($k): $v}')
  done
  echo "$json"
}

# Read the live Firebase versions (Explore is on AWS only and has none). After a promotion the
# target sites are read; for a dry run the site whose content will end up live is read instead
# (the source site for a changed system).
read_live_versions() {
  local mode=$1
  local system site
  for system in "${firebase_systems[@]}"; do
    if [ "$mode" = "preview" ] && [ "${promote["$system"]}" = true ]; then
      site=$(get_firebase_site "$system" "$SOURCE_ENV")
    else
      site=$(get_firebase_site "$system" "$TARGET_ENV")
    fi
    firebase_live_version "$site" "${firebase_project["$system"]}"
    live_version["$system"]=$FIREBASE_VERSION
    echo "  $system live version on $site: $FIREBASE_VERSION"
  done
}

build_bundle() {
  bundle_new_id
  bundle_reset_systems
  local system
  for system in "${all_systems[@]}"; do
    local sha
    sha=$(final_sha "$system")
    local changed=${promote["$system"]}
    if is_docker_system "$system"; then
      local shas
      if [ "$changed" = true ]; then
        shas=${docker_image_shas_object["$system"]}
      else
        shas=${target_image_shas["$system"]}
      fi
      bundle_add_heroku "$system" "$sha" "$changed" "$(get_heroku_app "$system" "$TARGET_ENV")" \
        "$shas" "${backup_id["$system"]:-}"
    elif is_firebase_system "$system"; then
      bundle_add_firebase "$system" "$sha" "$changed" "$(get_firebase_site "$system" "$TARGET_ENV")" \
        "${live_version["$system"]}"
    elif is_aws_system "$system"; then
      bundle_add_aws "$system" "$sha" "$changed" "$(get_aws_bucket "$system" "$TARGET_ENV")" \
        "$(get_aws_distribution "$system" "$TARGET_ENV")" "$sha"
    else
      local tag
      if [ "$changed" = true ]; then
        tag=${docker_tag["$system"]}
      else
        tag=${target_docker_tag["$system"]}
      fi
      bundle_add_manual "$system" "$sha" "$changed" "$tag"
    fi
  done
  # A snapshot has no source environment.
  local bundle_source=$SOURCE_ENV
  if [ "$SNAPSHOT" = true ]; then
    bundle_source=""
  fi
  BUNDLE_JSON=$(bundle_build "$TARGET_ENV" "$bundle_source" "" "$PROMOTER" "$(migrations_json)")
}

record_promotion() {
  local system=$1
  local payload=""
  if is_docker_system "$system"; then
    payload=$(jq -nc --argjson shas "${docker_image_shas_object["$system"]}" '{docker_image_shas: $shas}')
  elif is_manual_system "$system"; then
    payload=$(jq -nc --arg tag "${docker_tag["$system"]}" '{docker_tag: $tag}')
  fi
  github_record_deployment "$system" "${source_sha["$system"]}" \
    "$(get_github_deploy_env "$system" "$SOURCE_ENV")" "$(get_github_deploy_env "$system" "$TARGET_ENV")" \
    "Promotion from $SOURCE_ENV to $TARGET_ENV" "$payload"
}

# Promote Docker images between environments in Heroku.
promote_heroku_docker_images() {
  # Login to Heroku container registry once (for all images)
  heroku_login

  local system
  for system in "${docker_systems[@]}"; do
    if [ "${promote["$system"]}" = true ]; then
      echo "## Promote ${system} to $TARGET_ENV"

      local app
      app=$(get_heroku_app "$system" "$TARGET_ENV")
      echo "$app"

      local this_backup="omited"
      if [ "${backup["$system"]}" = true ]; then
        echo "Capturing database backup before ${system} promotion..."
        heroku_capture_backup "$app"
        this_backup=$BACKUP_ID
        backup_id["$system"]=$BACKUP_ID
      fi

      local -a proc_types
      read -r -a proc_types <<< "${process_types["$system"]}"
      local process_type
      for process_type in "${proc_types[@]}"; do
        echo "  Processing ${app}/${process_type}"
        local image
        image=$(image_for_process "${docker_image_shas_object["$system"]}" "$process_type")
        echo "    Docker image to promote: $image"
        heroku_patch_formation "$app" "$process_type" "$image" "$TARGET_ENV"
      done

      echo "  Recording deployment to GitHub..."
      record_promotion "$system"

      send_slack_notification "$system" "$SOURCE_ENV" "$TARGET_ENV" "$this_backup"

      echo
    else
      echo "## Skipping ${system} promotion (no changes)"
      echo
    fi
  done
}

# Promote a hosted UI. A Firebase system has its source site cloned onto the target site; an AWS
# system is copied from the build archive onto the target bucket and its CloudFront cache is
# invalidated. A system that is in both lists gets both.
promote_hosted_ui() {
  local system=$1
  local label=$2

  if [ "${promote["$system"]}" != true ]; then
    echo "## Skipping $label promotion (no changes)"
    echo
    return 0
  fi

  echo "## Promote $label from $SOURCE_ENV to $TARGET_ENV"

  if is_firebase_system "$system"; then
    local source_site
    source_site=$(get_firebase_site "$system" "$SOURCE_ENV")
    local target_site
    target_site=$(get_firebase_site "$system" "$TARGET_ENV")

    if [ -z "$source_site" ] || [ -z "$target_site" ]; then
      echo "  ! No Firebase site configured for $label in $SOURCE_ENV or $TARGET_ENV"
      exit 1
    fi

    firebase_clone "$source_site:live" "$target_site:live" "${firebase_project["$system"]}" "$label"
  fi

  if is_aws_system "$system"; then
    local archive target_bucket target_distribution
    archive=$(aws_archive_url "$system" "${source_sha["$system"]}")
    target_bucket=$(get_aws_bucket "$system" "$TARGET_ENV")
    target_distribution=$(get_aws_distribution "$system" "$TARGET_ENV")
    if [ -z "$target_bucket" ] || [ -z "$target_distribution" ]; then
      echo "  ! No AWS bucket or distribution configured for $label in $TARGET_ENV"
      exit 1
    fi
    aws_deploy_build "$archive" "$target_bucket" "$label (S3)"
    aws_invalidate "$target_distribution" "$label (CloudFront)"
  fi

  # One deployment record and one Slack message, whichever hosting the system uses.
  echo "  Recording deployment to GitHub..."

  record_promotion "$system"

  send_slack_notification "$system" "$SOURCE_ENV" "$TARGET_ENV"
  echo
}

# Promote systems that are updated by hand on private servers: print the command to run,
# record the deployment on GitHub and announce it on Slack.
promote_manual_systems() {
  local system
  for system in "${manual_systems[@]}"; do
    if [ "${promote["$system"]}" = true ]; then
      echo "## $system → $TARGET_ENV requires a manual step"
      echo "  Run on the GN and GS $TARGET_ENV $system servers:"
      echo "      $(get_manual_command "$system")    $(get_manual_command_note "$system")"

      record_promotion "$system"

      send_slack_notification "$system" "$SOURCE_ENV" "$TARGET_ENV"

      echo
    else
      echo "## Skipping $system promotion (no changes)"
      echo
    fi
  done
}

# Print the manual commands of the promoted manual systems, ready to copy.
show_manual_commands() {
  local header=$1
  local printed=false
  local system
  for system in "${manual_systems[@]}"; do
    if [ "${promote["$system"]}" = true ]; then
      if [ "$printed" = false ]; then
        echo "$header"
        printed=true
      fi
      echo "  $system (on the GN and GS $TARGET_ENV servers):"
      echo "      $(get_manual_command "$system")    $(get_manual_command_note "$system")"
    fi
  done
}

# Read the live Firebase versions, build the bundle, write it, prune, commit, push and announce it.
# Used after a promotion, to write the first bundle of an environment that has none, and for a
# snapshot.
record_bundle() {
  echo "##### Writing the $TARGET_ENV bundle"
  read_live_versions live
  build_bundle
  bundle_write "$REPO_ROOT/bundles/$TARGET_ENV" "$BUNDLE_JSON"
  bundle_prune "$REPO_ROOT" "$TARGET_ENV" "$BUNDLE_RETENTION_MONTHS"
  local origin="from $SOURCE_ENV"
  if [ "$SNAPSHOT" = true ]; then
    origin="snapshot"
  fi
  bundle_commit_push "$REPO_ROOT" "$TARGET_ENV" "bundle: $TARGET_ENV $BUNDLE_ID ($origin)"
  slack_send_text "$(bundle_slack_message "$TARGET_ENV" "$BUNDLE_ID")"
  echo
}

if [ "$SNAPSHOT" = true ]; then
  echo "##### Reading what $TARGET_ENV runs now"
else
  echo "##### Checking for changes between $SOURCE_ENV and $TARGET_ENV"
fi
echo

set_system_vars

echo "Preparing the Hasura migrations of Explore ${source_sha["Explore"]}..."
hasura_prepare_checkout "${source_sha["Explore"]}"
# A snapshot applies nothing, so pending Hasura changes are not looked for.
if [ "$SNAPSHOT" = false ] && check_hasura_changes "$TARGET_ENV"; then
  PROMOTE_HASURA=true
fi
echo

read_migration_numbers

if [ "$SNAPSHOT" = true ]; then
  if [ "$DRY_RUN" = true ]; then
    echo "##### DRY RUN MODE - snapshot bundle that would be written to bundles/$TARGET_ENV/:"
    read_live_versions live
    build_bundle
    echo "$BUNDLE_JSON"
    exit 0
  fi
  record_bundle
  exit 0
fi

ANY_PROMOTION=$PROMOTE_HASURA
for system in "${all_systems[@]}"; do
  if [ "${promote["$system"]}" = true ]; then ANY_PROMOTION=true; fi
done

if [ "$ANY_PROMOTION" = false ]; then
  # An environment promoted before this repo existed has no bundle, and its servers cannot
  # `update` without current.tags, so the first run records what it already runs.
  if [ ! -f "$REPO_ROOT/bundles/$TARGET_ENV/current.json" ]; then
    echo "##### No changes to promote, but $TARGET_ENV has no bundle yet: writing the initial one"
    echo
    if [ "$DRY_RUN" = true ]; then
      echo "##### DRY RUN MODE - bundle that would be written to bundles/$TARGET_ENV/:"
      read_live_versions live
      build_bundle
      echo "$BUNDLE_JSON"
      exit 0
    fi
    record_bundle
    exit 0
  fi
  echo "##### No changes detected - nothing to promote!"
  echo "All services are already up to date between $SOURCE_ENV and $TARGET_ENV"
  exit 0
fi

# Show what will be promoted
echo "##### Summary of services to promote:"
for system in "${all_systems[@]}"; do
  if [ "${promote["$system"]}" = true ]; then echo "  • $system will be promoted"; fi
done
if [ "$PROMOTE_HASURA" = true ]; then echo "  • Hasura migrations will be applied"; fi
echo

# Every changed AWS system needs its build in the archive. Checked before anything is deployed, in
# a dry run too.
for system in "${aws_systems[@]}"; do
  if [ "${promote["$system"]}" = true ]; then
    archive=$(aws_archive_url "$system" "${source_sha["$system"]}")
    if ! aws_archive_exists "$archive"; then
      echo "  ! Build ${source_sha["$system"]} is not archived at $archive; deploy it to dev again to archive it"
      exit 1
    fi
  fi
done

if [ "$DRY_RUN" = true ]; then
  echo "##### DRY RUN MODE - No actual promotions will be performed"
  echo
  echo "##### Slack notifications that would be sent:"
  for system in "${all_systems[@]}"; do
    if [ "${promote["$system"]}" = true ]; then
      show_slack_message "$system" "$SOURCE_ENV" "$TARGET_ENV"
    fi
  done
  show_manual_commands "##### Manual steps that would be required:"
  echo
  for system in "${aws_systems[@]}"; do
    if [ "${promote["$system"]}" = true ]; then
      echo "##### AWS copy that would be made for $system (dry run, no invalidation):"
      aws_deploy_build "$(aws_archive_url "$system" "${source_sha["$system"]}")" \
        "$(get_aws_bucket "$system" "$TARGET_ENV")" "$system (S3 dry run)" dryrun
      echo
    fi
  done
  echo "##### Bundle that would be written to bundles/$TARGET_ENV/:"
  read_live_versions preview
  build_bundle
  echo "$BUNDLE_JSON"
  exit 0
fi

echo "##### Promoting services from $SOURCE_ENV to $TARGET_ENV"
if [ "$SKIP_SLACK" = true ]; then
  echo "Slack notifications: DISABLED (--skip-slack flag)"
else
  echo "Slack notifications: ENABLED"
fi
echo

promote_heroku_docker_images

promote_manual_systems

# Update user preferences
if [ "$PROMOTE_HASURA" = true ]; then
  hasura_apply "$TARGET_ENV"
else
  echo "## Skipping Hasura migration (no changes)"
  echo
fi

# Promote the hosted UIs (S3 + CloudFront for Explore, Firebase for the others)
promote_hosted_ui "Explore" "Explore"
promote_hosted_ui "ResourceUi" "Resource UI"
promote_hosted_ui "AdminUi" "Admin UI"

# Final summary
echo "##### Promotion completed!"
echo "Services promoted:"
for system in "${all_systems[@]}"; do
  if [ "${promote["$system"]}" = true ]; then echo "  ✓ $system"; fi
done
if [ "$PROMOTE_HASURA" = true ]; then echo "  ✓ Hasura migrations"; fi
echo "Services skipped (no changes):"
for system in "${all_systems[@]}"; do
  if [ "${promote["$system"]}" = false ]; then echo "  ✗ $system"; fi
done
if [ "$PROMOTE_HASURA" = false ]; then echo "  ✗ Hasura migrations"; fi
echo

record_bundle

show_manual_commands "Manual steps still pending:"
