# Heroku: container registry login, database backups and formation updates through the Platform
# API. The API is used instead of the CLI so a release can name an exact docker image id.

heroku_login() {
  if ! heroku container:login; then
    echo "  ! Failed to login to Heroku container registry"
    exit 1
  fi
}

# Capture a backup of an app's database. Sets BACKUP_ID to the backup id or "unknown". A failed
# capture does not stop the promotion, as before; the id is just not recorded.
heroku_capture_backup() {
  local app=$1
  local backup_output
  backup_output=$(heroku pg:backups:capture --app "$app" 2>&1 || true)
  BACKUP_ID=$(echo "$backup_output" | grep -o 'b[0-9]\{3,\}' | head -1 || true)
  if [ -n "$BACKUP_ID" ]; then
    echo "$app database backup created: $BACKUP_ID"
  else
    BACKUP_ID="unknown"
    echo "$app database backup created (ID not captured)"
  fi
}

# Release one process type of an app on a given docker image id.
heroku_patch_formation() {
  local app=$1
  local process_type=$2
  local docker_image_sha=$3
  local env_label=$4

  local curl_opts=("-s" "--netrc" "--fail-with-body" "-H" "Content-Type: application/json" "-H" "Accept: application/vnd.heroku+json; version=3.docker-releases")
  curl_opts+=("${DEBUG_CURL[@]}")

  local body
  body=$(jq -nc --arg type "$process_type" --arg image "$docker_image_sha" \
    '{updates: [{type: $type, docker_image: $image}]}')

  local curl_output
  local curl_success
  if curl_output=$(curl "${curl_opts[@]}" -X PATCH "https://api.heroku.com/apps/${app}/formation" -d "$body"); then
    curl_success=true
  else
    curl_success=false
  fi

  if [ "$DEBUG" = true ]; then echo "*** RESPONSE: $curl_output"; fi

  if [ "$curl_success" = false ]; then
    echo "  ! Error deploying ${app}/${process_type} to $env_label: $curl_output"
    exit 1
  fi
  echo "  ✓ ${app}/${process_type} deployed successfully to $env_label"
}

# Docker image id of one process type in a docker_image_shas object, or "none".
image_for_process() {
  echo "$1" | jq -r --arg p "$2" '.[$p] // "none"'
}

# Fail unless an image shas object has an entry for every process type of the system, so the
# deploy phase cannot stop half way on a missing entry.
check_image_shas() {
  local system=$1
  local shas=$2
  local where=$3
  local -a proc_types
  read -r -a proc_types <<< "${process_types["$system"]}"
  local process_type
  for process_type in "${proc_types[@]}"; do
    if [ "$(image_for_process "$shas" "$process_type")" = "none" ]; then
      echo "  ! Docker image SHA for $system/$process_type in $where is not set - cannot proceed."
      exit 1
    fi
  done
}
