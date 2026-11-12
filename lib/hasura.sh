# Hasura (user preferences database of Explore). Migrations and metadata are applied from a sparse
# checkout of lucuma-apps at the Explore commit being promoted, not from whatever the operator has
# checked out locally.

HASURA_CHECKOUT=""
HASURA_TMP=""

hasura_cleanup() {
  if [ -n "$HASURA_TMP" ]; then
    rm -rf "$HASURA_TMP"
  fi
}

hasura_endpoint() {
  case $1 in
    "production") echo "https://prefs.gpp.gemini.edu" ;;
    "staging") echo "https://prefs-test.gpp.gemini.edu" ;;
    *) echo "" ;;
  esac
}

# Make explore/hasura/user-prefs at a lucuma-apps commit available under HASURA_CHECKOUT.
# LUCUMA_APPS_CHECKOUT, when set, is used as is (tests, offline work); otherwise a blobless sparse
# clone is made in a temp dir that is removed on exit.
hasura_prepare_checkout() {
  local sha=$1
  if [ -n "${LUCUMA_APPS_CHECKOUT:-}" ]; then
    HASURA_CHECKOUT=$LUCUMA_APPS_CHECKOUT
    echo "  Using lucuma-apps checkout at $HASURA_CHECKOUT (LUCUMA_APPS_CHECKOUT)"
  else
    HASURA_TMP=$(mktemp -d)
    trap hasura_cleanup EXIT
    echo "  Sparse checkout of lucuma-apps at $sha..."
    git clone --quiet --filter=blob:none --sparse --no-checkout "$LUCUMA_APPS_URL" "$HASURA_TMP" \
      || die "Could not clone $LUCUMA_APPS_URL"
    git -C "$HASURA_TMP" sparse-checkout set explore/hasura/user-prefs \
      || die "Could not set up the sparse checkout"
    git -C "$HASURA_TMP" checkout --quiet "$sha" \
      || die "Could not check out lucuma-apps at $sha"
    HASURA_CHECKOUT=$HASURA_TMP
  fi
  if [ ! -d "$HASURA_CHECKOUT/explore/hasura/user-prefs" ]; then
    die "$HASURA_CHECKOUT has no explore/hasura/user-prefs"
  fi
}

hasura_dir() {
  echo "$HASURA_CHECKOUT/explore/hasura/user-prefs"
}

# Highest numeric prefix of the migration directories, which is the version the database is at
# once they are applied. Sets USER_PREFS_NUMBER (0 when there are none).
hasura_user_prefs_number() {
  local dir
  dir="$(hasura_dir)/migrations/default"
  USER_PREFS_NUMBER=0
  if [ -d "$dir" ]; then
    local latest
    latest=$(find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
      | sed -n 's/^\([0-9][0-9]*\).*/\1/p' | sort -n | tail -1)
    if [ -n "$latest" ]; then
      USER_PREFS_NUMBER=$latest
    fi
  fi
}

## TODO sync hasura instances, we always get that changes are needed
# Returns 0 when there are pending migrations or metadata differences, 1 otherwise.
check_hasura_changes() {
  local target_env=$1
  echo "Checking for Hasura changes..."

  local endpoint
  endpoint=$(hasura_endpoint "$target_env")
  if [ -z "$endpoint" ]; then
    echo "  ! Unknown environment: $target_env, assuming changes needed"
    return 0
  fi

  local has_changes=false
  local status_output
  local pending_migrations
  local metadata_diff_output

  pushd "$(hasura_dir)" > /dev/null
  unset NODE_OPTIONS

  # Check for pending migrations
  status_output=$(hasura migrate status --endpoint "$endpoint" --database-name default 2>/dev/null || true)
  pending_migrations=$(echo "$status_output" | grep -c "Not Present" || true)

  if [ "$pending_migrations" -gt 0 ]; then
    echo "  ✓ Hasura has $pending_migrations pending migration(s)"
    has_changes=true
  else
    echo "  ✗ Hasura has no pending migrations"
  fi

  # Check for metadata differences
  echo "  Checking metadata differences..."
  metadata_diff_output=$(hasura metadata diff --endpoint "$endpoint" 2>/dev/null || echo "error")

  if [ "$metadata_diff_output" = "error" ]; then
    echo "  ! Could not check metadata diff - assuming changes needed"
    has_changes=true
  elif [ -n "$metadata_diff_output" ] && [ "$metadata_diff_output" != "Metadata is consistent" ]; then
    echo "  ✓ Hasura metadata has differences:"
    echo "$metadata_diff_output" | head -5 | sed 's/^/    /'
    if [ "$(echo "$metadata_diff_output" | wc -l)" -gt 5 ]; then
      echo "    ... (truncated, $(echo "$metadata_diff_output" | wc -l | tr -d ' ') total lines)"
    fi
    has_changes=true
  else
    echo "  ✗ Hasura metadata is consistent"
  fi

  popd > /dev/null

  if [ "$has_changes" = true ]; then
    return 0
  else
    echo "  ✗ No Hasura changes detected (migrations and metadata are up to date)"
    return 1
  fi
}

hasura_apply() {
  local target_env=$1
  local endpoint
  endpoint=$(hasura_endpoint "$target_env")
  if [ -z "$endpoint" ]; then
    echo "Unknown environment: $target_env"
    exit 1
  fi

  echo "## Promote user preferences db to $target_env"
  if (
    cd "$(hasura_dir)" || exit 1
    unset NODE_OPTIONS
    hasura migrate apply --endpoint "$endpoint" --database-name default \
      && hasura metadata apply --endpoint "$endpoint" \
      && hasura metadata reload --endpoint "$endpoint"
  ); then
    echo "  ✓ Hasura migration successful"
  else
    echo "  ! Hasura migration FAILED"
    exit 1
  fi
  echo
}
