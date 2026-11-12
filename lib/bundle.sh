# Bundles: the snapshot of an environment written after each promotion or rollback. The JSON is
# assembled with jq from explicit fields only, never from an API response, so nothing beyond the
# listed identifiers (and certainly no secret) can end up in the repo.

BUNDLE_SCHEMA=1
BUNDLE_ID_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z$'

# Sets BUNDLE_ID (YYYY-MM-DDTHH-MM-SSZ, safe in a file name) and BUNDLE_CREATED_AT (ISO 8601) from
# the same instant.
bundle_new_id() {
  BUNDLE_CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  BUNDLE_ID=${BUNDLE_CREATED_AT//:/-}
}

# Start an empty systems object; the bundle_add_* functions append to it in call order.
bundle_reset_systems() {
  BUNDLE_SYSTEMS='{}'
}

bundle_append_system() {
  BUNDLE_SYSTEMS=$(echo "$BUNDLE_SYSTEMS" | jq -c --arg name "$1" --argjson value "$2" '. + {($name): $value}')
}

# Keep only the declared process types of the system, as strings, so the bundle carries exactly
# the images Heroku is running and nothing else from the record.
bundle_clean_image_shas() {
  local system=$1
  local shas=$2
  echo "$shas" | jq -c --arg types "${process_types["$system"]}" \
    '($types | split(" ")) as $t | [$t[] as $k | {key: $k, value: (.[$k] | tostring)}] | from_entries'
}

bundle_add_heroku() {
  local system=$1 sha=$2 changed=$3 app=$4 shas=$5 backup_id=${6:-}
  local clean
  clean=$(bundle_clean_image_shas "$system" "$shas")
  bundle_append_system "$system" "$(jq -nc \
    --arg repo "${repo["$system"]}" --arg sha "$sha" --argjson changed "$changed" \
    --arg app "$app" --argjson shas "$clean" --arg backup "$backup_id" \
    '{repo: $repo, sha: $sha, changed: $changed, heroku_app: $app, docker_image_shas: $shas}
     + (if $backup == "" or $backup == "unknown" then {} else {backup: $backup} end)')"
}

bundle_add_firebase() {
  local system=$1 sha=$2 changed=$3 site=$4 version=$5
  bundle_append_system "$system" "$(jq -nc \
    --arg repo "${repo["$system"]}" --arg sha "$sha" --argjson changed "$changed" \
    --arg site "$site" --arg version "$version" \
    '{repo: $repo, sha: $sha, changed: $changed, firebase_site: $site, firebase_version: $version}')"
}

# A system hosted on S3 + CloudFront: the bucket, the distribution and the archived build (the sha),
# which is what a rollback restores. Bundles written while Explore was also on Firebase carry
# firebase_site and firebase_version for it; nothing reads them any more.
bundle_add_aws() {
  local system=$1 sha=$2 changed=$3 bucket=$4 distribution=$5 build=$6
  bundle_append_system "$system" "$(jq -nc \
    --arg repo "${repo["$system"]}" --arg sha "$sha" --argjson changed "$changed" \
    --arg bucket "$bucket" --arg dist "$distribution" --arg build "$build" \
    '{repo: $repo, sha: $sha, changed: $changed, s3_bucket: $bucket, cloudfront_distribution: $dist, s3_build: $build}')"
}

bundle_add_manual() {
  local system=$1 sha=$2 changed=$3 tag=$4
  bundle_append_system "$system" "$(jq -nc \
    --arg repo "${repo["$system"]}" --arg sha "$sha" --argjson changed "$changed" --arg tag "$tag" \
    '{repo: $repo, sha: $sha, changed: $changed, docker_tag: $tag}')"
}

# Print the bundle JSON. source and rollback_of are passed as "" for null. migrations is a JSON
# object of database -> number.
bundle_build() {
  local env=$1 source=$2 rollback_of=$3 created_by=$4 migrations=$5
  jq -n \
    --argjson schema "$BUNDLE_SCHEMA" \
    --arg id "$BUNDLE_ID" \
    --arg env "$env" \
    --arg source "$source" \
    --arg rollback_of "$rollback_of" \
    --arg created_at "$BUNDLE_CREATED_AT" \
    --arg created_by "$created_by" \
    --argjson migrations "$migrations" \
    --argjson systems "$BUNDLE_SYSTEMS" \
    '{schema: $schema, id: $id, environment: $env,
      source: (if $source == "" then null else $source end),
      rollback_of: (if $rollback_of == "" then null else $rollback_of end),
      created_at: $created_at, created_by: $created_by,
      migrations: ($migrations | with_entries(.value |= tonumber)),
      systems: $systems}'
}

# Write <id>.json, current.json and current.tags. Bundle files are only ever added, so an existing
# file with the same id is an error rather than something to overwrite.
bundle_write() {
  local dir=$1
  local json=$2
  local id
  id=$(echo "$json" | jq -r '.id')
  mkdir -p "$dir"
  if [ -e "$dir/$id.json" ]; then
    die "$dir/$id.json already exists; bundles are never overwritten"
  fi
  echo "$json" > "$dir/$id.json"
  cp "$dir/$id.json" "$dir/current.json"
  # The servers have no jq, so they read this flat file instead of current.json.
  jq -r '"bundle=\(.id)\nobserve=\(.systems.Observe.docker_tag)\nnavigate=\(.systems.Navigate.docker_tag)"' \
    "$dir/current.json" > "$dir/current.tags"
  echo "  ✓ Wrote $dir/$id.json, current.json and current.tags"
}

# Id of the oldest bundle to keep. Works with BSD date (macOS) and GNU date.
bundle_cutoff_id() {
  local months=$1
  date -u -v-"${months}"m +%Y-%m-%dT%H-%M-%SZ 2> /dev/null \
    || date -u -d "${months} months ago" +%Y-%m-%dT%H-%M-%SZ
}

# git rm the bundles older than the retention period. Ids are ISO timestamps, so a lexical compare
# against the cutoff id is a date compare. current.json and current.tags never match the id
# pattern, so they are never pruned. Pruned bundles stay in git history.
bundle_prune() {
  local root=$1
  local env=$2
  local months=$3
  if ! [[ "$months" =~ ^[0-9]+$ ]] || [ "$months" -lt 1 ]; then
    die "Invalid bundle retention: '$months' months"
  fi
  local cutoff
  cutoff=$(bundle_cutoff_id "$months")
  local file id
  for file in "$root/bundles/$env"/*.json; do
    [ -e "$file" ] || continue
    id=$(basename "$file" .json)
    [[ "$id" =~ $BUNDLE_ID_PATTERN ]] || continue
    if [[ "$id" < "$cutoff" ]]; then
      echo "  Pruning bundle $id (older than $months months)"
      git -C "$root" rm --quiet "bundles/$env/$id.json"
    fi
  done
}

# Commit the bundle directory and push. A rejected push means someone else pushed a bundle in the
# meantime; rebase on it (during a rebase `theirs` is our commit, which wins on current.*) and try
# again, twice. If it still fails the environment is deployed but unrecorded, so say exactly what
# to run by hand.
bundle_commit_push() {
  local root=$1
  local env=$2
  local message=$3

  git -C "$root" add -A "bundles/$env"
  git -C "$root" commit --quiet -m "$message"
  echo "  ✓ Committed: $message"

  local attempt
  for attempt in 1 2 3; do
    if git -C "$root" push --quiet; then
      echo "  ✓ Pushed $(git -C "$root" rev-parse --short HEAD)"
      return 0
    fi
    if [ "$attempt" -eq 3 ]; then
      break
    fi
    echo "  ! Push rejected, rebasing on the remote and retrying..."
    if ! git -C "$root" pull --quiet --rebase -X theirs; then
      git -C "$root" rebase --abort > /dev/null 2>&1 || true
      break
    fi
  done

  echo "  ! Could not push the bundle commit. The environment IS deployed; only the bundle is unrecorded."
  echo "  ! Commit: $(git -C "$root" rev-parse HEAD) ($message)"
  echo "  ! Push it by hand with: git -C \"$root\" pull --rebase -X theirs && git -C \"$root\" push"
  return 1
}

# Maximum migration number per database over every bundle of an environment. The databases only
# move forward, so this is what they are at now, whatever the current bundle says.
bundle_max_migrations() {
  local dir=$1
  local -a files=()
  local file
  for file in "$dir"/*.json; do
    [ -e "$file" ] && files+=("$file")
  done
  if [ ${#files[@]} -eq 0 ]; then
    echo '{}'
    return 0
  fi
  jq -s -c '[.[].migrations // {} | to_entries[]] | group_by(.key)
            | map({key: .[0].key, value: (map(.value) | max)}) | from_entries' "${files[@]}"
}
