#!/bin/bash
# Offline tests of the Observe and Navigate server scripts in servers/.
# A stub docker replaces the real one and current.tags is served from a local file:// URL through
# LUCUMA_DEPLOY_RAW_URL, so nothing touches the network or a docker daemon.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Only the docker stub goes in front of PATH: the other stubs in test/stubs (curl in particular)
# would shadow the real curl, which is needed here for file:// URLs.
mkdir "$TMP/bin"
ln -s "$ROOT/test/stubs/docker" "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export TERM=dumb
export LUCUMA_DEPLOY_RAW_URL="file://$TMP/raw"
unset NAVIGATE_TAG
mkdir -p "$HOME" "$TMP/raw/bundles/staging" "$TMP/raw/bundles/production"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# check <description> <condition...>: passes when the command succeeds.
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

# run <stdin> <command...>: sets OUT and RC.
run() {
    local input="$1"
    shift
    OUT=$(printf '%s' "$input" | "$@" 2>&1)
    RC=$?
}

out_has() { [[ "$OUT" == *"$1"* ]]; }
out_lacks() { [[ "$OUT" != *"$1"* ]]; }
out_is() { [ "$OUT" = "$1" ]; }
rc_is() { [ "$RC" -eq "$1" ]; }
rc_isnt() { [ "$RC" -ne "$1" ]; }
file_is() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }
no_file() { [ ! -e "$1" ]; }

write_tags() { # <env> <bundle> <observe> <navigate>
    printf 'bundle=%s\nobserve=%s\nnavigate=%s\n' "$2" "$3" "$4" >"$TMP/raw/bundles/$1/current.tags"
}

# Scenarios shared by both apps. Arguments: app name, command, state dir, environment, tags key.
scenarios() {
    local app="$1" cmd="$2" dir="$3" env="$4" tags_key="$5"
    local t1="TAG-ONE" t2="TAG-TWO" t3="TAG-THREE"
    local b1="2026-10-30T14-37-37Z" b2="2026-10-31T09-00-00Z"
    local tags_file="$TMP/raw/bundles/$env/current.tags"
    echo "--- $app ($env)"

    rm -f "$dir/deployed-version" "$dir/deployed-bundle"
    write_tags "$env" "$b1" "$t1" "$t1"

    run "" "$cmd" version
    check "$app: version with nothing deployed fails" rc_isnt 0

    run "" "$cmd" update "$t1"
    check "$app: old syntax 'update <tag>' is rejected" rc_isnt 0
    check "$app: old syntax names the unexpected argument" out_has "Unexpected argument"
    check "$app: old syntax changes nothing" no_file "$dir/deployed-version"

    run "" "$cmd" update
    check "$app: bare update deploys" rc_is 0
    check "$app: bare update writes deployed-version" file_is "$dir/deployed-version" "$t1"
    check "$app: bare update writes deployed-bundle" file_is "$dir/deployed-bundle" "$b1"
    check "$app: bare update pulled the image" out_has "[stub docker] pull noirlab/gpp-"

    run "" "$cmd" update
    check "$app: second update succeeds" rc_is 0
    check "$app: second update says Already on" out_has "Already on $t1 (bundle $b1)"
    check "$app: second update does not touch docker" out_lacks "[stub docker]"

    run "" "$cmd" version
    check "$app: version shows tag and bundle" out_is "$t1 (bundle $b1)"

    run "no" "$cmd" update --force-version "$t2"
    check "$app: forced update answered no fails" rc_isnt 0
    check "$app: forced update answered no says Aborted" out_has "Aborted. Nothing was changed."
    check "$app: forced update answered no keeps deployed-version" file_is "$dir/deployed-version" "$t1"
    check "$app: forced update answered no keeps deployed-bundle" file_is "$dir/deployed-bundle" "$b1"
    check "$app: forced update warns about the promoted tag" out_has "is $t1"

    run "yes" "$cmd" update --force-version "$t2"
    check "$app: forced update answered yes deploys" rc_is 0
    check "$app: forced update writes deployed-version" file_is "$dir/deployed-version" "$t2"
    check "$app: forced update removes deployed-bundle" no_file "$dir/deployed-bundle"
    run "" "$cmd" version
    check "$app: version after forced update is just the tag" out_is "$t2"

    run "" "$cmd" update --force-version "$t1"
    check "$app: forced update to the promoted tag needs no prompt" rc_is 0
    check "$app: forced update to the promoted tag does not warn" out_lacks "REALLY"
    check "$app: forced update to the promoted tag writes deployed-version" file_is "$dir/deployed-version" "$t1"

    # A bare update after a forced one must re-deploy even though the tag matches.
    run "" "$cmd" update
    check "$app: bare update after a forced one deploys again" out_has "[stub docker] pull"
    check "$app: bare update after a forced one restores deployed-bundle" file_is "$dir/deployed-bundle" "$b1"

    # No ordering checks: a rollback is just another update.
    write_tags "$env" "$b2" "$t3" "$t3"
    run "" "$cmd" update
    check "$app: new bundle deploys" file_is "$dir/deployed-version" "$t3"
    check "$app: new bundle writes its id" file_is "$dir/deployed-bundle" "$b2"
    write_tags "$env" "$b1" "$t1" "$t1"
    run "" "$cmd" update
    check "$app: going back to an earlier tag is accepted" file_is "$dir/deployed-version" "$t1"

    # Same tag, different bundle id: not "already on".
    write_tags "$env" "$b2" "$t1" "$t1"
    run "" "$cmd" update
    check "$app: same tag in a new bundle deploys again" file_is "$dir/deployed-bundle" "$b2"

    # Broken or missing current.tags must fail without touching the server.
    write_tags "$env" "$b1" "$t2" "$t2"
    sed "/^$tags_key=/d" "$tags_file" >"$TMP/tags.edit" && mv "$TMP/tags.edit" "$tags_file"
    run "" "$cmd" update
    check "$app: missing $tags_key= line fails" rc_isnt 0
    check "$app: missing $tags_key= line says nothing was changed" out_has "Nothing was changed."
    check "$app: missing $tags_key= line keeps deployed-version" file_is "$dir/deployed-version" "$t1"

    write_tags "$env" "$b1" "$t2" "$t2"
    sed '/^bundle=/d' "$tags_file" >"$TMP/tags.edit" && mv "$TMP/tags.edit" "$tags_file"
    run "" "$cmd" update
    check "$app: missing bundle= line fails" rc_isnt 0
    check "$app: missing bundle= line keeps deployed-version" file_is "$dir/deployed-version" "$t1"

    rm -f "$tags_file"
    run "" "$cmd" update
    check "$app: missing current.tags fails" rc_isnt 0
    check "$app: missing current.tags says nothing was changed" out_has "Nothing was changed."
    check "$app: missing current.tags keeps deployed-version" file_is "$dir/deployed-version" "$t1"

    run "no" "$cmd" update --force-version "$t2"
    check "$app: forced update with missing current.tags says the promoted version is unknown" out_has "Could not determine the version last promoted"
    run "yes" "$cmd" update --force-version "$t2"
    check "$app: forced update with missing current.tags still works on yes" file_is "$dir/deployed-version" "$t2"
}

# --- Observe, staging-gn
mkdir -p "$HOME/observe/conf" "$HOME/observe/log"
cp "$ROOT"/servers/observe/*.sh "$HOME/observe/"
chmod +x "$HOME"/observe/*.sh
cat >"$HOME/observe/config.sh" <<CONF
#!/bin/bash
SITE=staging-gn
DOCKERHUB_USER=nlsoftware
DOCKERHUB_TOKEN=not-a-token
LOCAL_LOG_DIR=$HOME/observe/log
CONF
scenarios observe "$HOME/observe/observe.sh" "$HOME/observe" staging observe

echo "--- observe: SITE validation"
sed -i.bak 's/^SITE=.*/SITE=bogus-gn/' "$HOME/observe/config.sh"
write_tags staging "2026-10-30T14-37-37Z" "TAG-ONE" "TAG-ONE"
before=$(cat "$HOME/observe/deployed-version")
run "" "$HOME/observe/observe.sh" update
check "observe: bad SITE is rejected" rc_isnt 0
check "observe: bad SITE explains itself" out_has "Cannot determine the environment"
check "observe: bad SITE changes nothing" file_is "$HOME/observe/deployed-version" "$before"
sed -i.bak 's/^SITE=.*/SITE=staging-gn/' "$HOME/observe/config.sh"
run "" "$HOME/observe/observe.sh" help
check "observe: help mentions the bundle" out_has "bundle"

# --- Navigate, production-gs
mkdir -p "$HOME/navigate/conf"
cp "$ROOT/servers/navigate/navigate.sh" "$ROOT/servers/navigate/docker-compose.yml" "$HOME/navigate/"
chmod +x "$HOME/navigate/navigate.sh"
cat >"$HOME/navigate/.env" <<ENVF
POSTGRES_VERSION=17
DB_NAME=navigate
DB_USER=navigate
DB_PASS=secret
SITE=production-gs
ENVF
scenarios navigate "$HOME/navigate/navigate.sh" "$HOME/navigate" production navigate

echo "--- navigate: SITE validation"
sed -i.bak 's/^SITE=.*/SITE=production/' "$HOME/navigate/.env"
write_tags production "2026-10-30T14-37-37Z" "TAG-ONE" "TAG-ONE"
before=$(cat "$HOME/navigate/deployed-version")
run "" "$HOME/navigate/navigate.sh" update
check "navigate: bad SITE is rejected" rc_isnt 0
check "navigate: bad SITE explains itself" out_has "Cannot determine the environment"
check "navigate: bad SITE changes nothing" file_is "$HOME/navigate/deployed-version" "$before"
sed -i.bak 's/^SITE=.*/SITE=production-gs/' "$HOME/navigate/.env"
run "" "$HOME/navigate/navigate.sh" help
check "navigate: help mentions the bundle" out_has "bundle"

echo
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES check(s) FAILED"
    exit 1
fi
echo "All server checks passed"
