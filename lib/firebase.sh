# Firebase hosting: cloning one site's live channel (or a past version) onto another site's live
# channel, and reading which version is live.

# Clone a source onto a target live channel. The source is `<site>:live` for a promotion or
# `<site>@<version>` for a rollback.
firebase_clone() {
  local source=$1
  local target=$2
  local project=$3
  local label=$4
  if firebase hosting:clone "$source" "$target" --project "$project"; then
    echo "  ✓ $label deployed successfully"
  else
    echo "  ! $label deployment FAILED"
    exit 1
  fi
}

# Read the version id live on a site. Sets FIREBASE_VERSION. The bundle records this rather than
# anything inferred, so it is what a rollback can clone back.
firebase_live_version() {
  local site=$1
  local project=$2
  local output
  if ! output=$(firebase hosting:channel:list --site "$site" --project "$project" --json); then
    echo "  ! Could not list the Firebase channels of $site"
    exit 1
  fi
  FIREBASE_VERSION=$(echo "$output" | jq -r \
    '[(.result.channels // .result // [])[] | select(.name | endswith("/channels/live"))
      | .release.version.name // empty | split("/") | last] | first // empty')
  if [ -z "$FIREBASE_VERSION" ]; then
    echo "  ! No live version found for Firebase site $site"
    exit 1
  fi
}
