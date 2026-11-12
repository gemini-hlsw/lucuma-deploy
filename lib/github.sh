# GitHub API calls: deployment records (read and write) and the git trees lookup that gives the
# Flyway migration numbers of a lucuma-odb commit. Needs GPP_GITHUB_TOKEN (see github_auth).

github_curl_opts() {
  GH_CURL_OPTS=("-s" "--fail-with-body" "-H" "Accept: application/vnd.github.v3+json")
  GH_CURL_OPTS+=("${DEBUG_CURL[@]}")
  if [ -n "${GPP_GITHUB_TOKEN:-}" ]; then
    GH_CURL_OPTS+=("-H" "Authorization: Bearer $GPP_GITHUB_TOKEN")
  fi
}

# Fetch the latest deployment record of a system in an environment. Sets GH_RECORD to the record
# as compact JSON, or to "null" when there is none. Runs in the current shell (not in a command
# substitution) so that a failure stops the script.
github_get_deployment() {
  local system=$1
  local env=$2

  local repo_name=${repo["$system"]}
  local deploy_env
  deploy_env=$(get_github_deploy_env "$system" "$env")
  local task
  task=$(get_github_task "$system")

  github_curl_opts
  local curl_output
  local curl_success
  if curl_output=$(curl "${GH_CURL_OPTS[@]}" \
    "https://api.github.com/repos/$repo_name/deployments?environment=${deploy_env}&task=${task}&per_page=1"); then
    curl_success=true
  else
    curl_success=false
  fi

  if [ "$DEBUG" = true ]; then echo "*** RESPONSE: $curl_output"; fi

  if [ "$curl_success" = false ]; then
    echo "  ! Error querying GitHub API Deployment for $system in $env"
    exit 1
  fi

  GH_RECORD=$(echo "$curl_output" | jq -c '.[0] // null')
}

# Field accessors over a record from github_get_deployment. They print "none" when the field is
# absent. The payload can be an object or an empty string depending on who created the record.
record_sha() {
  echo "$1" | jq -r '.sha // "none"'
}

record_image_shas() {
  echo "$1" | jq -r '(.payload | objects | .docker_image_shas) // null | if . == null then "none" else tojson end'
}

# Observe records the tag in the payload; Navigate's dev record has no payload and its ref is the
# release tag, which is the docker tag.
record_docker_tag() {
  echo "$1" | jq -r '(.payload | objects | .docker_tag) // .ref // "none"'
}

# Create a deployment record. The body carries the same fields promote.sh has always sent; the
# payload argument is a JSON object or empty for systems without one.
github_record_deployment() {
  local system=$1
  local ref=$2
  local orig_env=$3
  local deploy_env=$4
  local description=$5
  local payload=${6:-}

  local repo_name=${repo["$system"]}
  local task
  task=$(get_github_task "$system")

  github_curl_opts
  local body
  body=$(jq -nc \
    --arg ref "$ref" \
    --arg orig "$orig_env" \
    --arg env "$deploy_env" \
    --arg description "$description" \
    --arg task "$task" \
    --arg payload "$payload" \
    '{ref: $ref, auto_merge: false, original_environment: $orig, environment: $env,
      description: $description, required_contexts: [], task: $task}
     + (if $payload == "" then {} else {payload: ($payload | fromjson)} end)')

  echo "  Creating deployment record for $system in $deploy_env environment..."
  if [ "$DEBUG" = true ]; then echo "  ** Debug: POST https://api.github.com/repos/$repo_name/deployments $body"; fi

  local curl_output
  local curl_success
  if curl_output=$(curl "${GH_CURL_OPTS[@]}" -X POST "https://api.github.com/repos/$repo_name/deployments" -d "$body"); then
    curl_success=true
  else
    curl_success=false
  fi

  if [ "$DEBUG" = true ]; then echo "*** RESPONSE: $curl_output"; fi

  if [ "$curl_success" = true ] && echo "$curl_output" | grep -q '"id"'; then
    echo "  ✓ Deployment record created successfully"
  else
    echo "  ! Failed to record deployment: $curl_output"
    exit 1
  fi
}

declare -A GH_TREE_CACHE

# Highest V<n>__ Flyway migration under a path prefix of the lucuma-odb tree at a commit. Sets
# FLYWAY_NUMBER (0 when the prefix has no migrations). A truncated tree would silently give a
# lower number, so it is an error instead.
github_flyway_number() {
  local sha=$1
  local prefix=$2

  if [ -z "${GH_TREE_CACHE["$sha"]:-}" ]; then
    github_curl_opts
    local curl_output
    if ! curl_output=$(curl "${GH_CURL_OPTS[@]}" \
      "https://api.github.com/repos/gemini-hlsw/lucuma-odb/git/trees/${sha}?recursive=1"); then
      echo "  ! Error reading the lucuma-odb tree at $sha: $curl_output"
      exit 1
    fi
    if [ "$(echo "$curl_output" | jq -r '.truncated')" != "false" ]; then
      echo "  ! The lucuma-odb tree at $sha is truncated (or unreadable); cannot read migration numbers"
      exit 1
    fi
    GH_TREE_CACHE["$sha"]=$curl_output
  fi

  FLYWAY_NUMBER=$(echo "${GH_TREE_CACHE["$sha"]}" | jq --arg p "$prefix" \
    '[.tree[] | select(.type == "blob") | .path | select(startswith($p))
      | split("/") | last | select(test("^V[0-9]+__")) | capture("^V(?<n>[0-9]+)__").n | tonumber]
     | max // 0')
}
