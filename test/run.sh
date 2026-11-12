#!/usr/bin/env bash
# Smoke tests for promote.sh and rollback.sh, fully offline.
#
# Builds a throwaway copy of the repo whose origin is a local bare repo, puts the stub CLIs of
# test/stubs first on PATH, and runs a dev -> staging -> production promotion followed by a
# production rollback, checking the bundles, commits, pushes and the calls made to the stubs.
# Then runs test/servers.sh when it exists. Exits non-zero if any check fails.
#
# KEEP_TMP=1 keeps the temp dir for inspection.

set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_REPO=$(dirname "$TEST_DIR")

TMP=$(mktemp -d)
if [ "${KEEP_TMP:-}" = 1 ]; then
  echo "Temp dir: $TMP"
else
  trap 'rm -rf "$TMP"' EXIT
fi

FAILED=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  FAILED=$((FAILED + 1))
}
# check <description> <command...>: PASS when the command succeeds.
check() {
  local description=$1
  shift
  if "$@" > /dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}
# check_eq <description> <expected> <actual>
check_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1 (expected '$2', got '$3')"
  fi
}

WORK=$TMP/work
ORIGIN=$TMP/origin.git
FIXTURES=$TMP/fixtures
CHECKOUT=$TMP/lucuma-apps
LOGS=$TMP/logs
STATE=$TMP/firebase-state
mkdir -p "$WORK" "$FIXTURES" "$LOGS" "$STATE"

# Keep the user's git config (signing, hooks, templates) out of the throwaway repos.
export GIT_CONFIG_GLOBAL=$TMP/gitconfig
export GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" << 'GITCONFIG'
[user]
  name = Test Promoter
  email = test@example.com
[commit]
  gpgsign = false
[init]
  defaultBranch = main
GITCONFIG

fake_sha() {
  printf '%s' "$1" | git hash-object --stdin
}

firebase_default_version() {
  printf '%s' "$1" | git hash-object --stdin | cut -c1-16
}

########## Fixtures

# record <owner/repo> <environment> <task> <sha> <ref> <payload json>
record() {
  local dir="$FIXTURES/deployments/$1/$2"
  mkdir -p "$dir"
  jq -n --arg sha "$4" --arg ref "$5" --argjson payload "$6" --arg env "$2" --arg task "$3" \
    '[{url: "https://api.github.com/repos/x/deployments/1", id: 1, sha: $sha, ref: $ref,
       task: $task, payload: $payload, original_environment: $env, environment: $env,
       description: "fixture", creator: {login: "ci"}, created_at: "2026-10-01T00:00:00Z"}]' \
    > "$dir/${3//:/_}.json"
}

images() {
  jq -nc --arg p "$1" --arg types "$2" '[$types | split(" ")[] | {key: ., value: "sha256:\($p)-\(.)"}] | from_entries'
}

ODB_TYPES="web calibration obscalc pdfsummary"
ODB_DEV=$(fake_sha odb-dev)
ODB_STG=$(fake_sha odb-staging)
ODB_STG2=$(fake_sha odb-staging-2)
ODB_PRD=$(fake_sha odb-production)
APPS_DEV=$(fake_sha apps-dev)
APPS_STG=$(fake_sha apps-staging)
APPS_STG2=$(fake_sha apps-staging-2)
APPS_PRD=$(fake_sha apps-production)
TS_DEV=$(fake_sha ts-dev)
TS_STG=$(fake_sha ts-staging)
TS_STG2=$(fake_sha ts-staging-2)
TS_PRD=$(fake_sha ts-production)

# lucuma-odb: Sso, Odb, Resource differ between all environments. Itc is at the same sha in dev
# and staging but with different images in the staging record, to prove that an unchanged system
# takes its identifiers from the target record.
heroku_records() {
  local env=$1 sha=$2 tag=$3
  record gemini-hlsw/lucuma-odb "$env" deploy:SSO "$sha" "$sha" "{\"docker_image_shas\": $(images "sso-$tag" web)}"
  record gemini-hlsw/lucuma-odb "$env" deploy:ODB "$sha" "$sha" "{\"docker_image_shas\": $(images "odb-$tag" "$ODB_TYPES")}"
  record gemini-hlsw/lucuma-odb "$env" deploy:RESOURCE "$sha" "$sha" "{\"docker_image_shas\": $(images "res-$tag" web)}"
}
heroku_records development "$ODB_DEV" dev
heroku_records staging "$ODB_STG" stg
heroku_records production "$ODB_PRD" prd
record gemini-hlsw/lucuma-odb development deploy:ITC "$ODB_DEV" "$ODB_DEV" "{\"docker_image_shas\": $(images itc-dev web)}"
record gemini-hlsw/lucuma-odb staging deploy:ITC "$ODB_DEV" "$ODB_DEV" "{\"docker_image_shas\": $(images itc-stg web)}"
record gemini-hlsw/lucuma-odb production deploy:ITC "$ODB_PRD" "$ODB_PRD" "{\"docker_image_shas\": $(images itc-prd web)}"

# lucuma-apps: Explore records have no payload; Observe records carry the docker tag.
record gemini-hlsw/lucuma-apps development deploy:Explore "$APPS_DEV" main '{}'
record gemini-hlsw/lucuma-apps staging deploy:Explore "$APPS_STG" "$APPS_STG" '{}'
record gemini-hlsw/lucuma-apps production deploy:Explore "$APPS_PRD" "$APPS_PRD" '{}'
record gemini-hlsw/lucuma-apps development deploy:Observe "$APPS_DEV" main '{"docker_tag": "20261021-aaaaaaaa"}'
record gemini-hlsw/lucuma-apps staging deploy:Observe "$APPS_STG" "$APPS_STG" '{"docker_tag": "20261001-bbbbbbbb"}'
record gemini-hlsw/lucuma-apps production deploy:Observe "$APPS_PRD" "$APPS_PRD" '{"docker_tag": "20260901-cccccccc"}'

# lucuma-ts: ResourceUi is unchanged between dev and staging. Navigate's dev record has no
# payload, its ref is the release tag.
record gemini-hlsw/lucuma-ts resource-ui-dev deploy "$TS_DEV" main '{}'
record gemini-hlsw/lucuma-ts resource-ui-staging deploy "$TS_DEV" "$TS_DEV" '{}'
record gemini-hlsw/lucuma-ts resource-ui-production deploy "$TS_PRD" "$TS_PRD" '{}'
record gemini-hlsw/lucuma-ts admin-ui-dev deploy "$TS_DEV" main '{}'
record gemini-hlsw/lucuma-ts admin-ui-staging deploy "$TS_STG" "$TS_STG" '{}'
record gemini-hlsw/lucuma-ts admin-ui-production deploy "$TS_PRD" "$TS_PRD" '{}'
record gemini-hlsw/lucuma-ts navigate-dev-gn deploy "$TS_DEV" v0.16.24 '{}'
record gemini-hlsw/lucuma-ts navigate-staging deploy "$TS_STG" "$TS_STG" '{"docker_tag": "v0.16.20"}'
record gemini-hlsw/lucuma-ts navigate-production deploy "$TS_PRD" "$TS_PRD" '{"docker_tag": "v0.16.10"}'

# tree <sha> <truncated> <paths...>
tree() {
  local sha=$1 truncated=$2
  shift 2
  mkdir -p "$FIXTURES/trees"
  printf '%s\n' "$@" | jq -R . | jq -s --arg sha "$sha" --argjson truncated "$truncated" \
    '{sha: $sha, url: "https://api.github.com/x", truncated: $truncated,
      tree: ([.[] | {path: ., mode: "100644", type: "blob", sha: "0"}]
             + [{path: "modules/service/src/main/resources/db/migration", type: "tree", sha: "0"}])}' \
    > "$FIXTURES/trees/$sha.json"
}
odb_tree() {
  local sha=$1 latest=$2
  tree "$sha" false \
    "modules/service/src/main/resources/db/migration/V1001__first.sql" \
    "modules/service/src/main/resources/db/migration/V${latest}__latest.sql" \
    "modules/service/src/main/scala/db/migration/V1002__Scala.scala" \
    "modules/service/src/main/resources/db/migration/R__repeatable.sql" \
    "modules/sso-service/src/main/resources/db/migration/V3__three.sql" \
    "modules/sso-service/src/main/resources/db/migration/V4__four.sql" \
    "modules/other/src/main/resources/db/migration/V9999__elsewhere.sql" \
    "README.md"
}
odb_tree "$ODB_DEV" 1376
odb_tree "$ODB_STG" 1370
odb_tree "$ODB_STG2" 1377
TRUNCATED_SHA=$(fake_sha truncated)
tree "$TRUNCATED_SHA" true "modules/service/src/main/resources/db/migration/V1__a.sql"

# Hasura migrations of the lucuma-apps "checkout".
for d in 1700000000000_init 1792331515894_add_prefs; do
  mkdir -p "$CHECKOUT/explore/hasura/user-prefs/migrations/default/$d"
  echo "select 1;" > "$CHECKOUT/explore/hasura/user-prefs/migrations/default/$d/up.sql"
done
echo "version: 3" > "$CHECKOUT/explore/hasura/user-prefs/config.yaml"

########## Throwaway repo with a bare origin

(cd "$SOURCE_REPO" && tar cf - --exclude=.git .) | (cd "$WORK" && tar xf -)

# Planted staging bundles: one past the retention period, which the next staging bundle must
# prune, and a recent one that must stay.
RECENT_ID=$(date -u -v-1m +%Y-%m-%dT%H-%M-%SZ 2> /dev/null || date -u -d "1 month ago" +%Y-%m-%dT%H-%M-%SZ)
OLD_ID=2020-01-01T00-00-00Z
for id in "$OLD_ID" "$RECENT_ID"; do
  jq -n --arg id "$id" '{schema: 1, id: $id, environment: "staging", source: "dev", rollback_of: null,
    created_at: $id, created_by: "planted", migrations: {odb: 1, sso: 1, resource: 0, user_prefs: 1},
    systems: {}}' > "$WORK/bundles/staging/$id.json"
done

git init -q --bare -b main "$ORIGIN"
git -C "$WORK" init -q -b main
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "initial"
git -C "$WORK" remote add origin "$ORIGIN"
git -C "$WORK" push -q -u origin main

########## Environment

# test/servers.sh needs the real curl (file:// URLs), so it gets the PATH from before the stubs.
ORIG_PATH=$PATH
export PATH="$WORK/test/stubs:$PATH"
export STUB_FIXTURES=$FIXTURES
export STUB_LOG=$LOGS
export STUB_STATE_DIR=$STATE
export LUCUMA_APPS_CHECKOUT=$CHECKOUT
export GPP_GITHUB_TOKEN=test
export GPP_PROMOTER=tester
unset GPP_SLACK_WEBHOOK_URL GPP_SLACK_CHANNEL NODE_OPTIONS

head_sha() { git -C "$WORK" rev-parse HEAD; }
origin_sha() { git -C "$ORIGIN" rev-parse main; }
bundle_ids() {
  find "$WORK/bundles/$1" -maxdepth 1 -name '*.json' ! -name current.json -exec basename {} .json \; | sort
}
curl_calls() { cat "$LOGS/curl.jsonl" 2> /dev/null || true; }
reset_logs() { rm -f "$LOGS"/*; }
# The single bundle id present now but not in the given list.
new_bundle_id() {
  comm -13 <(printf '%s\n' "$2") <(bundle_ids "$1") | head -1
}
bundle_get() { jq -r "$2" "$WORK/bundles/$1"; }

########## 1. promote dev staging --dry-run

echo "=== promote.sh dev staging --dry-run"
before_head=$(head_sha)
before_ids=$(bundle_ids staging)
reset_logs
if out=$("$WORK/promote.sh" dev staging --dry-run 2>&1); then rc=0; else rc=$?; fi
echo "$out" > "$TMP/dry-run.out"
check_eq "dry-run exits 0" 0 "$rc"
check "dry-run prints the bundle JSON" grep -q '"schema": 1' "$TMP/dry-run.out"
check "dry-run prints the Observe manual step" grep -q 'observe update' "$TMP/dry-run.out"
check_eq "dry-run writes no bundle" "$before_ids" "$(bundle_ids staging)"
check_eq "dry-run makes no commit" "$before_head" "$(head_sha)"
check_eq "dry-run leaves the tree clean" "" "$(git -C "$WORK" status --porcelain)"
check_eq "dry-run makes no POST or PATCH" 0 "$(curl_calls | jq -s '[.[] | select(.method != "GET")] | length')"
check "dry-run clones nothing on Firebase" bash -c "! grep -q hosting:clone '$LOGS/firebase.log'"
ARCHIVE_DEV="s3://gemini-edu-explore-dev/builds/$APPS_DEV"
PROPS="--copy-props metadata-directive"
QUIET="--only-show-errors"
check_eq "dry-run checks the archive, then only lists the Explore S3 copies and the stale-file sync" \
  "s3 ls $ARCHIVE_DEV/index.html
s3 cp $ARCHIVE_DEV/assets s3://gemini-edu-explore-test/latest/assets --recursive $PROPS --dryrun
s3 cp $ARCHIVE_DEV s3://gemini-edu-explore-test/latest --recursive --exclude assets/* $PROPS --dryrun
s3 sync $ARCHIVE_DEV s3://gemini-edu-explore-test/latest --delete $PROPS --dryrun" \
  "$(cat "$LOGS/aws.log")"
check "dry-run still prints the bundle after the S3 listing" bash -c "grep -q '(dryrun) copy:' '$TMP/dry-run.out' && grep -q 's3_bucket' '$TMP/dry-run.out'"
check "dry-run applies no Hasura migration" bash -c "! grep -q 'migrate apply' '$LOGS/hasura.log'"

########## 1a. promote dev staging with the Explore build missing from the archive

echo "=== promote.sh dev staging (Explore build not archived)"
before_head=$(head_sha)
before_ids=$(bundle_ids staging)
reset_logs
if STUB_AWS_MISSING="$APPS_DEV" "$WORK/promote.sh" dev staging --skip-slack > "$TMP/promote-missing.out" 2>&1; then rc=0; else rc=$?; fi
check "promotion with a missing archive exits non-zero" test "$rc" -ne 0
check "promotion names the build and the archive" grep -q "Build $APPS_DEV is not archived at $ARCHIVE_DEV; deploy it to dev again to archive it" "$TMP/promote-missing.out"
check_eq "missing archive: no PATCH or POST" 0 "$(curl_calls | jq -s '[.[] | select(.method != "GET")] | length')"
check "missing archive: nothing cloned on Firebase" bash -c "! grep -q hosting:clone '$LOGS/firebase.log' 2> /dev/null"
check "missing archive: no Heroku backup" bash -c "! grep -q pg:backups '$LOGS/heroku.log' 2> /dev/null"
check "missing archive: nothing copied or invalidated" bash -c "! grep -q -e sync -e invalidation '$LOGS/aws.log'"
check_eq "missing archive: no bundle" "$before_ids" "$(bundle_ids staging)"
check_eq "missing archive: no commit" "$before_head" "$(head_sha)"

########## 2. promote dev staging --skip-slack

echo "=== promote.sh dev staging --skip-slack"
before_ids=$(bundle_ids staging)
reset_logs
if "$WORK/promote.sh" dev staging --skip-slack > "$TMP/staging.out" 2>&1; then rc=0; else rc=$?; fi
check_eq "promotion to staging exits 0" 0 "$rc"
[ "$rc" = 0 ] || tail -30 "$TMP/staging.out"
S1=$(new_bundle_id staging "$before_ids")
check "staging bundle written" test -n "$S1" -a -f "$WORK/bundles/staging/$S1.json"
B="staging/$S1.json"
check "staging bundle id has the expected format" bash -c "[[ '$S1' =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z$ ]]"
check "current.json is a copy of the new bundle" cmp "$WORK/bundles/$B" "$WORK/bundles/staging/current.json"
check_eq "current.tags content" \
  "$(printf 'bundle=%s\nobserve=20261021-aaaaaaaa\nnavigate=v0.16.24' "$S1")" \
  "$(cat "$WORK/bundles/staging/current.tags")"
check_eq "bundle header" "1 $S1 staging dev null tester" \
  "$(bundle_get "$B" '"\(.schema) \(.id) \(.environment) \(.source) \(.rollback_of) \(.created_by)"')"
check_eq "created_at matches the id" "$S1" "$(bundle_get "$B" '.created_at | gsub(":"; "-")')"
check_eq "migration numbers" '{"odb":1376,"sso":4,"resource":0,"user_prefs":1792331515894}' \
  "$(bundle_get "$B" '.migrations | tojson')"
check_eq "every system in the bundle" "Sso Itc Odb Resource Explore ResourceUi AdminUi Observe Navigate" \
  "$(bundle_get "$B" '.systems | keys_unsorted | join(" ")')"
check_eq "changed flags" "Sso=true Itc=false Odb=true Resource=true Explore=true ResourceUi=false AdminUi=true Observe=true Navigate=true" \
  "$(bundle_get "$B" '[.systems | to_entries[] | "\(.key)=\(.value.changed)"] | join(" ")')"
check_eq "changed Odb has the source images" "$(images odb-dev "$ODB_TYPES")" "$(bundle_get "$B" '.systems.Odb.docker_image_shas | tojson')"
check_eq "unchanged Itc has the target record's images" "$(images itc-stg web)" "$(bundle_get "$B" '.systems.Itc.docker_image_shas | tojson')"
check_eq "Heroku apps" "lucuma-sso-staging itc-staging lucuma-postgres-odb-staging lucuma-resource-staging" \
  "$(bundle_get "$B" '[.systems.Sso, .systems.Itc, .systems.Odb, .systems.Resource | .heroku_app] | join(" ")')"
check_eq "backups for Sso and Odb only" "b123 null b123 null" \
  "$(bundle_get "$B" '[.systems.Sso, .systems.Itc, .systems.Odb, .systems.Resource | .backup] | map(tostring) | join(" ")')"
check_eq "shas" "$ODB_DEV $ODB_DEV $APPS_DEV $TS_DEV $TS_DEV" \
  "$(bundle_get "$B" '[.systems.Odb, .systems.Itc, .systems.Explore, .systems.ResourceUi, .systems.Navigate | .sha] | join(" ")')"
check_eq "Navigate tag comes from the dev record's ref" "v0.16.24" "$(bundle_get "$B" '.systems.Navigate.docker_tag')"
check_eq "unchanged ResourceUi has the live staging version" "$(firebase_default_version resource-ae0b7-staging)" \
  "$(bundle_get "$B" '.systems.ResourceUi.firebase_version')"
check_eq "Firebase sites" "resource-ae0b7-staging admin-679f7-staging" \
  "$(bundle_get "$B" '[.systems.ResourceUi, .systems.AdminUi | .firebase_site] | join(" ")')"
check_eq "Explore has no Firebase fields" "false" \
  "$(bundle_get "$B" '.systems.Explore | has("firebase_site") or has("firebase_version")')"
check "bundle holds no token" bash -c "! grep -qi -e authorization -e bearer '$WORK/bundles/$B'"
check_eq "commit message" "bundle: staging $S1 (from dev)" "$(git -C "$WORK" log -1 --format=%s)"
check_eq "commit pushed to origin" "$(head_sha)" "$(origin_sha)"
check_eq "tree clean after the commit" "" "$(git -C "$WORK" status --porcelain)"
check "bundle, current.json and current.tags are in the pushed commit" bash -c "
  git -C '$ORIGIN' cat-file -e 'main:bundles/$B' \
  && git -C '$ORIGIN' cat-file -e main:bundles/staging/current.json \
  && git -C '$ORIGIN' cat-file -e main:bundles/staging/current.tags"
check "bundle older than the retention period is pruned" test ! -e "$WORK/bundles/staging/$OLD_ID.json"
check "pruned bundle is gone from the pushed commit" bash -c "! git -C '$ORIGIN' cat-file -e 'main:bundles/staging/$OLD_ID.json'"
check "pruning is part of the bundle commit" bash -c "git -C '$WORK' show --name-status --format= HEAD | grep -q '^D.*$OLD_ID.json'"
check "recent bundle is kept" test -f "$WORK/bundles/staging/$RECENT_ID.json"
check_eq "Odb formation patched for every process type" \
  "web=sha256:odb-dev-web calibration=sha256:odb-dev-calibration obscalc=sha256:odb-dev-obscalc pdfsummary=sha256:odb-dev-pdfsummary" \
  "$(curl_calls | jq -rs '[.[] | select(.method == "PATCH" and (.url | contains("lucuma-postgres-odb-staging"))) | .data | fromjson | .updates[0] | "\(.type)=\(.docker_image)"] | join(" ")')"
check_eq "no formation patch for the unchanged Itc" 0 \
  "$(curl_calls | jq -s '[.[] | select(.method == "PATCH" and (.url | contains("itc-staging")))] | length')"
check_eq "deployment records for the 7 changed systems" 7 \
  "$(curl_calls | jq -s '[.[] | select(.method == "POST" and (.url | endswith("/deployments")))] | length')"
check_eq "Navigate record carries the docker tag" '{"docker_tag":"v0.16.24"}' \
  "$(curl_calls | jq -rs '[.[] | select(.method == "POST") | .data | fromjson | select(.environment == "navigate-staging")][0].payload | tojson')"
check_eq "Odb record carries the image shas and the promotion description" "Promotion from dev to staging $(images odb-dev "$ODB_TYPES")" \
  "$(curl_calls | jq -rs '[.[] | select(.method == "POST") | .data | fromjson | select(.task == "deploy:ODB")][0] | "\(.description) \(.payload.docker_image_shas | tojson)"')"
check "Explore is not touched on Firebase" bash -c "! grep -q explore '$LOGS/firebase.log'"
check_eq "Explore: archive check, assets copied first, then the rest, stale files removed, then the invalidation" \
  "s3 ls $ARCHIVE_DEV/index.html
s3 cp $ARCHIVE_DEV/assets s3://gemini-edu-explore-test/latest/assets --recursive $PROPS $QUIET
s3 cp $ARCHIVE_DEV s3://gemini-edu-explore-test/latest --recursive --exclude assets/* $PROPS $QUIET
s3 sync $ARCHIVE_DEV s3://gemini-edu-explore-test/latest --delete $PROPS $QUIET
cloudfront create-invalidation --distribution-id E2E5A5UYD8VLF7 --paths /* --query Invalidation.Id --output text" \
  "$(cat "$LOGS/aws.log")"
check_eq "Explore bundle entry has the staging bucket, distribution and build" "gemini-edu-explore-test E2E5A5UYD8VLF7 $APPS_DEV" \
  "$(bundle_get "$B" '.systems.Explore | "\(.s3_bucket) \(.cloudfront_distribution) \(.s3_build)"')"
check_eq "s3_build equals the Explore sha" "$APPS_DEV" "$(bundle_get "$B" '.systems.Explore | if .s3_build == .sha then .sha else "differs" end')"
check_eq "only Explore carries S3 fields" "Explore" \
  "$(bundle_get "$B" '[.systems | to_entries[] | select(.value.s3_bucket) | .key] | join(" ")')"
check_eq "one Explore deployment record" 1 \
  "$(curl_calls | jq -s '[.[] | select(.method == "POST" and (.url | endswith("/deployments"))) | .data | fromjson | select(.task == "deploy:Explore")] | length')"
check "Sso and Odb backed up" bash -c "grep -q 'pg:backups:capture --app lucuma-sso-staging' '$LOGS/heroku.log' && grep -q 'pg:backups:capture --app lucuma-postgres-odb-staging' '$LOGS/heroku.log'"
check "Hasura applied from the lucuma-apps checkout" grep -q "^$CHECKOUT/explore/hasura/user-prefs :: migrate apply --endpoint https://prefs-test.gpp.gemini.edu" "$LOGS/hasura.log"
check "Slack skipped with --skip-slack" bash -c "! grep -q hooks.slack.com '$LOGS/curl.jsonl'"
check "final bundle message shown" grep -q "📦 staging bundle $S1 written: https://github.com/gemini-hlsw/lucuma-deploy/blob/main/bundles/staging/$S1.json" "$TMP/staging.out"

########## 3a. Bootstrap: nothing to promote, but production has no bundle yet

# Make every production record match staging and report no pending Hasura migration, so the
# promotion has nothing to do. The production fixtures are restored afterwards.
cp -R "$FIXTURES/deployments" "$TMP/deployments.saved"
while IFS= read -r file; do
  target=$(echo "$file" | sed 's#/staging/#/production/#; s#-staging/#-production/#')
  cp "$file" "$target"
done < <(find "$FIXTURES/deployments" -path '*staging/*' -name '*.json')
for site in resource-ae0b7 admin-679f7; do
  rm -f "$STATE/$site"
done

echo "=== promote.sh staging production --dry-run (bootstrap)"
before_head=$(head_sha)
reset_logs
if STUB_HASURA_PENDING=0 "$WORK/promote.sh" staging production --dry-run > "$TMP/bootstrap-dry.out" 2>&1; then rc=0; else rc=$?; fi
check_eq "bootstrap dry-run exits 0" 0 "$rc"
check "bootstrap dry-run announces the initial bundle" grep -q "No changes to promote, but production has no bundle yet: writing the initial one" "$TMP/bootstrap-dry.out"
check "bootstrap dry-run prints the bundle JSON" grep -q '"schema": 1' "$TMP/bootstrap-dry.out"
check_eq "bootstrap dry-run writes no bundle" "" "$(bundle_ids production)"
check_eq "bootstrap dry-run makes no commit" "$before_head" "$(head_sha)"

echo "=== promote.sh staging production --skip-slack (bootstrap)"
reset_logs
if STUB_HASURA_PENDING=0 "$WORK/promote.sh" staging production --skip-slack > "$TMP/bootstrap.out" 2>&1; then rc=0; else rc=$?; fi
check_eq "bootstrap exits 0" 0 "$rc"
[ "$rc" = 0 ] || tail -30 "$TMP/bootstrap.out"
P0=$(bundle_ids production)
check "bootstrap writes one production bundle" test -n "$P0" -a "$(echo "$P0" | wc -l | tr -d ' ')" = 1
check_eq "bootstrap bundle has every system unchanged" "false" \
  "$(bundle_get "production/$P0.json" '[.systems[].changed] | unique | map(tostring) | join(",")')"
check_eq "bootstrap bundle has all systems" 9 "$(bundle_get "production/$P0.json" '.systems | length')"
check_eq "bootstrap bundle takes identifiers from the production records" "$(images odb-stg "$ODB_TYPES") 20261001-bbbbbbbb v0.16.20" \
  "$(bundle_get "production/$P0.json" '"\(.systems.Odb.docker_image_shas | tojson) \(.systems.Observe.docker_tag) \(.systems.Navigate.docker_tag)"')"
check_eq "bootstrap bundle has the production bucket and the Explore build of the production record" "gemini-edu-explore-prd $APPS_STG" \
  "$(bundle_get "production/$P0.json" '.systems.Explore | "\(.s3_bucket) \(.s3_build)"')"
check_eq "bootstrap bundle has the live production Firebase version of AdminUi" "$(firebase_default_version admin-679f7)" \
  "$(bundle_get "production/$P0.json" '.systems.AdminUi.firebase_version')"
check "bootstrap current.json written" cmp "$WORK/bundles/production/$P0.json" "$WORK/bundles/production/current.json"
check_eq "bootstrap current.tags" "$(printf 'bundle=%s\nobserve=20261001-bbbbbbbb\nnavigate=v0.16.20' "$P0")" \
  "$(cat "$WORK/bundles/production/current.tags")"
check_eq "bootstrap commit message" "bundle: production $P0 (from staging)" "$(git -C "$WORK" log -1 --format=%s)"
check_eq "bootstrap commit pushed" "$(head_sha)" "$(origin_sha)"
check_eq "bootstrap deploys and records nothing" 0 "$(curl_calls | jq -s '[.[] | select(.method != "GET")] | length')"
check "bootstrap applies no Hasura migration" bash -c "! grep -q 'migrate apply' '$LOGS/hasura.log'"
check "bootstrap final bundle message shown" grep -q "📦 production bundle $P0 written" "$TMP/bootstrap.out"

echo "=== promote.sh staging production (nothing changed, bundle exists)"
before_head=$(head_sha)
if STUB_HASURA_PENDING=0 "$WORK/promote.sh" staging production --skip-slack > "$TMP/noop.out" 2>&1; then rc=0; else rc=$?; fi
check_eq "no-change promotion exits 0" 0 "$rc"
check "no-change promotion says nothing to promote" grep -q "nothing to promote" "$TMP/noop.out"
check_eq "no-change promotion writes no bundle" "$P0" "$(bundle_ids production)"
check_eq "no-change promotion makes no commit" "$before_head" "$(head_sha)"

rm -rf "$FIXTURES/deployments"
mv "$TMP/deployments.saved" "$FIXTURES/deployments"
sleep 1

########## 3. promote staging production --skip-slack (twice)

echo "=== promote.sh staging production --skip-slack"
before_ids=$(bundle_ids production)
reset_logs
if "$WORK/promote.sh" staging production --skip-slack > "$TMP/production1.out" 2>&1; then rc=0; else rc=$?; fi
check_eq "promotion to production exits 0" 0 "$rc"
[ "$rc" = 0 ] || tail -30 "$TMP/production1.out"
P1=$(new_bundle_id production "$before_ids")
check "production bundle written" test -n "$P1"
check_eq "production commit message" "bundle: production $P1 (from staging)" "$(git -C "$WORK" log -1 --format=%s)"
check_eq "production commit pushed" "$(head_sha)" "$(origin_sha)"
check_eq "production migrations come from the staging build" 1370 "$(bundle_get "production/$P1.json" '.migrations.odb')"
check "staging bundles untouched by the production promotion" test -f "$WORK/bundles/staging/$S1.json"

# A new staging build: Odb, Observe, Explore and AdminUi move on, with a newer Odb migration.
heroku_records staging "$ODB_STG" stg
record gemini-hlsw/lucuma-odb staging deploy:ODB "$ODB_STG2" "$ODB_STG2" "{\"docker_image_shas\": $(images odb-stg2 "$ODB_TYPES")}"
record gemini-hlsw/lucuma-apps staging deploy:Observe "$APPS_STG2" "$APPS_STG2" '{"docker_tag": "20261025-dddddddd"}'
record gemini-hlsw/lucuma-apps staging deploy:Explore "$APPS_STG2" "$APPS_STG2" '{}'
record gemini-hlsw/lucuma-ts admin-ui-staging deploy "$TS_STG2" "$TS_STG2" '{}'
echo "5ta9e2adminui002" > "$STATE/admin-679f7-staging"

sleep 1
before_ids=$(bundle_ids production)
reset_logs
if "$WORK/promote.sh" staging production --skip-slack > "$TMP/production2.out" 2>&1; then rc=0; else rc=$?; fi
check_eq "second promotion to production exits 0" 0 "$rc"
[ "$rc" = 0 ] || tail -30 "$TMP/production2.out"
P2=$(new_bundle_id production "$before_ids")
check "second production bundle written" test -n "$P2"
check_eq "second production bundle has the newer Odb migration" 1377 "$(bundle_get "production/$P2.json" '.migrations.odb')"
check_eq "second production bundle has the new Explore build" "$APPS_STG2 true" "$(bundle_get "production/$P2.json" '.systems.Explore | "\(.s3_build) \(.changed)"')"
check_eq "second production bundle has the new AdminUi version" "5ta9e2adminui002" "$(bundle_get "production/$P2.json" '.systems.AdminUi.firebase_version')"

########## 4. rollback.sh production (listing)

echo "=== rollback.sh production"
if "$WORK/rollback.sh" production > "$TMP/list.out" 2>&1; then rc=0; else rc=$?; fi
check_eq "listing exits 1" 1 "$rc"
check "listing shows both bundles, newest first" bash -c \
  "grep -n -e '$P1' -e '$P2' '$TMP/list.out' | cut -d: -f2- | awk '{print \$1}' | tr '\n' ' ' | grep -q '^$P2 $P1 $'"
check "listing shows the source and the changed systems" grep -q "$P1 .*from staging .*changed: .*Odb" "$TMP/list.out"

########## 4a. rollback.sh production <P1> --dry-run

echo "=== rollback.sh production $P1 --dry-run"
before_head=$(head_sha)
before_ids=$(bundle_ids production)
reset_logs
if "$WORK/rollback.sh" production "$P1" --dry-run < /dev/null > "$TMP/rollback-dry.out" 2>&1; then rc=0; else rc=$?; fi
check_eq "rollback dry-run exits 0 without confirmation" 0 "$rc"
check "rollback dry-run never prompts" bash -c "! grep -q 'Type the environment name' '$TMP/rollback-dry.out'"
check "rollback dry-run shows the migration check" grep -q "WARNING: odb schema is AHEAD" "$TMP/rollback-dry.out"
check "rollback dry-run prints the bundle JSON" grep -q "\"rollback_of\": \"$P1\"" "$TMP/rollback-dry.out"
check_eq "rollback dry-run writes no bundle" "$before_ids" "$(bundle_ids production)"
check_eq "rollback dry-run makes no commit" "$before_head" "$(head_sha)"
check_eq "rollback dry-run makes no change" 0 "$(curl_calls | jq -s '[.[] | select(.method != "GET")] | length')"

########## 5. rollback.sh production <P1> with a wrong confirmation

echo "=== rollback.sh production $P1 (wrong confirmation)"
before_head=$(head_sha)
before_ids=$(bundle_ids production)
reset_logs
if echo "staging" | "$WORK/rollback.sh" production "$P1" > "$TMP/rollback-abort.out" 2>&1; then rc=0; else rc=$?; fi
check_eq "wrong confirmation exits 1" 1 "$rc"
check_eq "wrong confirmation writes no bundle" "$before_ids" "$(bundle_ids production)"
check_eq "wrong confirmation makes no commit" "$before_head" "$(head_sha)"
check_eq "wrong confirmation makes no change" 0 "$(curl_calls | jq -s '[.[] | select(.method != "GET")] | length')"

########## 6. rollback.sh production <P1>

echo "=== rollback.sh production $P1"
sleep 1
before_ids=$(bundle_ids production)
reset_logs
export GPP_SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T000/B000/XXXX
if echo "production" | "$WORK/rollback.sh" production "$P1" > "$TMP/rollback.out" 2>&1; then rc=0; else rc=$?; fi
unset GPP_SLACK_WEBHOOK_URL
check_eq "rollback exits 0" 0 "$rc"
[ "$rc" = 0 ] || tail -30 "$TMP/rollback.out"
R=$(new_bundle_id production "$before_ids")
check "rollback bundle written" test -n "$R"
RB="production/$R.json"
check "migration warning fired for odb" grep -q "WARNING: odb schema is AHEAD" "$TMP/rollback.out"
check "no migration warning for sso" bash -c "! grep -q 'WARNING: sso' '$TMP/rollback.out'"
check_eq "rollback bundle header" "production null $P1" "$(bundle_get "$RB" '"\(.environment) \(.source) \(.rollback_of)"')"
check_eq "rollback bundle has the target's migrations" "$(bundle_get "production/$P1.json" '.migrations | tojson')" \
  "$(bundle_get "$RB" '.migrations | tojson')"
check_eq "rollback bundle has the target's systems apart from changed" \
  "$(bundle_get "production/$P1.json" '.systems | map_values(del(.changed, .backup)) | tojson')" \
  "$(bundle_get "$RB" '.systems | map_values(del(.changed)) | tojson')"
check_eq "rollback changed flags" "Odb Explore AdminUi Observe" \
  "$(bundle_get "$RB" '[.systems | to_entries[] | select(.value.changed) | .key] | join(" ")')"
check_eq "current.tags after the rollback" "$(printf 'bundle=%s\nobserve=20261001-bbbbbbbb\nnavigate=v0.16.20' "$R")" \
  "$(cat "$WORK/bundles/production/current.tags")"
check_eq "rollback commit message" "bundle: production $R (rollback of $P1)" "$(git -C "$WORK" log -1 --format=%s)"
check_eq "rollback commit pushed" "$(head_sha)" "$(origin_sha)"
check_eq "Odb formation patched back for every process type" 4 \
  "$(curl_calls | jq -s '[.[] | select(.method == "PATCH" and (.url | contains("lucuma-postgres-odb-production")) and (.data | contains("odb-stg-")))] | length')"
check_eq "only Odb patched on Heroku" 4 "$(curl_calls | jq -s '[.[] | select(.method == "PATCH")] | length')"
check "AdminUi cloned back from the bundle's version" grep -q \
  "hosting:clone admin-679f7@$(bundle_get "production/$P1.json" '.systems.AdminUi.firebase_version') admin-679f7:live --project admin-679f7" \
  "$LOGS/firebase.log"
check "Explore is not cloned on Firebase by the rollback" bash -c "! grep -q explore '$LOGS/firebase.log'"
ARCHIVE_P1="s3://gemini-edu-explore-dev/builds/$APPS_STG"
check_eq "rollback copies Explore from the archived build, then invalidates production" \
  "s3 ls $ARCHIVE_P1/index.html
s3 cp $ARCHIVE_P1/assets s3://gemini-edu-explore-prd/latest/assets --recursive $PROPS $QUIET
s3 cp $ARCHIVE_P1 s3://gemini-edu-explore-prd/latest --recursive --exclude assets/* $PROPS $QUIET
s3 sync $ARCHIVE_P1 s3://gemini-edu-explore-prd/latest --delete $PROPS $QUIET
cloudfront create-invalidation --distribution-id E1VDJ0RPRW1PVL --paths /* --query Invalidation.Id --output text" \
  "$(cat "$LOGS/aws.log")"
check_eq "rollback bundle Explore entry has the restored build" "gemini-edu-explore-prd E1VDJ0RPRW1PVL $APPS_STG" \
  "$(bundle_get "$RB" '.systems.Explore | "\(.s3_bucket) \(.cloudfront_distribution) \(.s3_build)"')"
check_eq "rollback deployment records" "deploy:ODB=Rollback to bundle $P1 deploy:Explore=Rollback to bundle $P1 deploy=Rollback to bundle $P1 deploy:Observe=Rollback to bundle $P1" \
  "$(curl_calls | jq -rs '[.[] | select(.method == "POST" and (.url | endswith("/deployments"))) | .data | fromjson | "\(.task)=\(.description)"] | join(" ")')"
check_eq "rollback record ref is the target sha" "$ODB_STG" \
  "$(curl_calls | jq -rs '[.[] | select(.method == "POST" and (.url | endswith("/deployments"))) | .data | fromjson | select(.task == "deploy:ODB")][0].ref')"
check "Slack rollback message per system" bash -c \
  "jq -rs '.[] | select(.url | startswith(\"https://hooks.slack.com\")) | .data' '$LOGS/curl.jsonl' | grep -q '⏪ Odb rolled back in production to ${ODB_STG:0:7} (bundle $P1)'"
check "Slack rollback message with the Observe command" bash -c \
  "jq -rs '.[] | select(.url | startswith(\"https://hooks.slack.com\")) | .data' '$LOGS/curl.jsonl' | grep -q 'observe update'"
check "Slack final bundle message" bash -c \
  "jq -rs '.[] | select(.url | startswith(\"https://hooks.slack.com\")) | .data' '$LOGS/curl.jsonl' | grep -q '📦 production bundle $R written'"

########## 6a. rollback.sh refuses when the Explore build is not archived

# Plant a production bundle whose Explore s3_build differs from the current one, and commit it so
# the tree stays clean. Its build is the one the stub reports as missing. It also carries the
# Firebase fields that bundles written while Explore was on Firebase have, which must be ignored.
echo "=== rollback.sh production (Explore build not archived)"
PLANTED_ID=2099-01-01T00-00-00Z
PLANTED_BUILD=$(fake_sha planted-explore-build)
ARCHIVE_PLANTED="s3://gemini-edu-explore-dev/builds/$PLANTED_BUILD"
jq --arg id "$PLANTED_ID" --arg build "$PLANTED_BUILD" '.id = $id | .created_at = $id | .systems.Explore.s3_build = $build | .systems.Explore.firebase_site = "legacy-explore-site" | .systems.Explore.firebase_version = "0ldexplore000000"' \
  "$WORK/bundles/production/$P1.json" > "$WORK/bundles/production/$PLANTED_ID.json"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "plant a bundle that would change Explore"
git -C "$WORK" push -q
before_head=$(head_sha)
before_ids=$(bundle_ids production)
reset_logs
if echo "production" | STUB_AWS_MISSING="$PLANTED_BUILD" "$WORK/rollback.sh" production "$PLANTED_ID" > "$TMP/rollback-aws.out" 2>&1; then rc=0; else rc=$?; fi
check "rollback with a missing archive exits non-zero" test "$rc" -ne 0
check "rollback names the build and the archive" grep -q "Build $PLANTED_BUILD of Explore (bundle $PLANTED_ID) is not archived at $ARCHIVE_PLANTED" "$TMP/rollback-aws.out"
check "rollback refusal comes before the migration check and the prompt" bash -c "! grep -q -e 'Migration check' -e 'Type the environment name' '$TMP/rollback-aws.out'"
check_eq "refused rollback makes no PATCH or POST" 0 "$(curl_calls | jq -s '[.[] | select(.method != "GET")] | length')"
check "refused rollback clones nothing on Firebase" bash -c "! grep -q hosting:clone '$LOGS/firebase.log' 2> /dev/null"
check "refused rollback copies and invalidates nothing" bash -c "! grep -q -e sync -e invalidation '$LOGS/aws.log'"
check_eq "refused rollback writes no bundle" "$before_ids" "$(bundle_ids production)"
check_eq "refused rollback makes no commit" "$before_head" "$(head_sha)"
reset_logs
if STUB_AWS_MISSING="$PLANTED_BUILD" "$WORK/rollback.sh" production "$PLANTED_ID" --dry-run < /dev/null > "$TMP/rollback-aws-dry.out" 2>&1; then rc=0; else rc=$?; fi
check "rollback dry-run with a missing archive exits non-zero" test "$rc" -ne 0
check "rollback dry-run names the build" grep -q "Build $PLANTED_BUILD of Explore" "$TMP/rollback-aws-dry.out"
check "rollback dry-run prints no bundle" bash -c "! grep -q '\"schema\"' '$TMP/rollback-aws-dry.out'"

########## 6b. rollback.sh ignores an obsolete Explore Firebase version

# A copy of the current production bundle that differs only in the Firebase fields Explore had
# while it was on Firebase. Explore is compared by s3_build, so nothing is rolled back.
echo "=== rollback.sh production (only an obsolete Explore Firebase version differs)"
LEGACY_ID=2099-01-02T00-00-00Z
jq --arg id "$LEGACY_ID" '.id = $id | .created_at = $id | .systems.Explore.firebase_site = "legacy-explore-site" | .systems.Explore.firebase_version = "0ldexplore111111"' \
  "$WORK/bundles/production/current.json" > "$WORK/bundles/production/$LEGACY_ID.json"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "plant a bundle that differs only in obsolete Explore Firebase fields"
git -C "$WORK" push -q
before_head=$(head_sha)
before_ids=$(bundle_ids production)
reset_logs
if echo "production" | "$WORK/rollback.sh" production "$LEGACY_ID" > "$TMP/rollback-legacy.out" 2>&1; then rc=0; else rc=$?; fi
check_eq "rollback to a bundle differing only in Explore's Firebase version exits 0" 0 "$rc"
check "Explore is reported unchanged" grep -q '^    Explore: unchanged$' "$TMP/rollback-legacy.out"
check "nothing to roll back" grep -q 'nothing to roll back' "$TMP/rollback-legacy.out"
check "no AWS call at all" bash -c "! [ -s '$LOGS/aws.log' ]"
check_eq "no PATCH or POST" 0 "$(curl_calls | jq -s '[.[] | select(.method != "GET")] | length')"
check_eq "no bundle written" "$before_ids" "$(bundle_ids production)"
check_eq "no commit made" "$before_head" "$(head_sha)"

########## 7. Library checks

echo "=== library checks"
check "a truncated lucuma-odb tree is an error" bash -c "
  ! ( DEBUG=false; DEBUG_CURL=()
      source '$WORK/lib/common.sh'; source '$WORK/lib/systems.sh'; source '$WORK/lib/github.sh'
      github_flyway_number '$TRUNCATED_SHA' modules/service/src/main/ )"
check "bundle cutoff is six months back" bash -c "
  source '$WORK/lib/common.sh'; source '$WORK/lib/bundle.sh'
  [[ \$(bundle_cutoff_id 6) < \$(date -u +%Y-%m-%dT%H-%M-%SZ) ]] && [[ \$(bundle_cutoff_id 6) > '$OLD_ID' ]] && [[ \$(bundle_cutoff_id 6) < '$RECENT_ID' ]]"
for script in "$WORK"/*.sh "$WORK"/lib/*.sh "$WORK"/test/run.sh "$WORK"/test/stubs/*; do
  check "bash -n ${script#"$WORK"/}" bash -n "$script"
done

########## 8. Server scripts

if [ -f "$TEST_DIR/servers.sh" ]; then
  echo "=== test/servers.sh"
  if PATH="$ORIG_PATH" bash "$TEST_DIR/servers.sh"; then pass "test/servers.sh"; else fail "test/servers.sh"; fi
else
  echo "=== test/servers.sh not present, skipped"
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED check(s) FAILED"
  exit 1
fi
echo "All checks passed"
