# lucuma-deploy design

One repo, one branch, holding everything about promoting, rolling back and deploying the GPP
systems: the promotion and rollback scripts, a snapshot ("bundle") of every environment after
each promotion or rollback, and the scripts that run on the Observe and Navigate servers.

## Repository layout

```
promote.sh                       promote all systems from one environment to the next
rollback.sh                      roll an environment back to a bundle
promoteDevAllToStaging.sh        wrappers kept for muscle memory
promoteStagingAllToProduction.sh
lib/                             bash sourced by the scripts above
  common.sh                      logging, argument helpers, tool checks, repo preflight
  systems.sh                     the table of systems (repos, Heroku apps, Firebase sites...)
  github.sh                      deployment records, migration lookups, trees API
  heroku.sh                      formation updates, backups
  firebase.sh                    clone, live version lookup
  aws.sh                         S3 bucket to bucket sync, CloudFront invalidation
  hasura.sh                      sparse checkout of lucuma-apps, migration status/apply
  slack.sh                       notifications
  bundle.sh                      build, write, prune, commit and push bundles
bundles/
  staging/                       one file per promotion or rollback, plus current.json and
  production/                    current.tags (see below)
servers/
  CONTRACT.md                    env vars and mounts each server image expects
  observe/                       scripts installed on the Observe servers
  navigate/                      scripts installed on the Navigate servers
test/
  run.sh                         promote/rollback end to end with stubbed CLIs, no network
  servers.sh                     Observe/Navigate server scripts with a stub docker
  stubs/                         fake curl, heroku, firebase, aws, hasura, docker, gh
flake.nix, .envrc, .sopsrc       dev shell with the CLIs above, sops-encrypted secrets.yaml
DESIGN.md                        this file
TESTS.md                         what the tests cover and how to run them
```

## Systems

| System     | Repo                    | Kind     | Identifier in a bundle                 |
|------------|-------------------------|----------|----------------------------------------|
| Sso        | gemini-hlsw/lucuma-odb  | Heroku   | `docker_image_shas` per process type   |
| Itc        | gemini-hlsw/lucuma-odb  | Heroku   | `docker_image_shas`                    |
| Odb        | gemini-hlsw/lucuma-odb  | Heroku   | `docker_image_shas`                    |
| Resource   | gemini-hlsw/lucuma-odb  | Heroku   | `docker_image_shas`                    |
| Explore    | gemini-hlsw/lucuma-apps | AWS (S3 + CloudFront) | `s3_build` (plus `s3_bucket`, `cloudfront_distribution`) |
| ResourceUi | gemini-hlsw/lucuma-ts   | Firebase | `firebase_version`                     |
| AdminUi    | gemini-hlsw/lucuma-ts   | Firebase | `firebase_version`                     |
| Observe    | gemini-hlsw/lucuma-apps | Manual   | `docker_tag` (`YYYYMMDD-<sha8>`)       |
| Navigate   | gemini-hlsw/lucuma-ts   | Manual   | `docker_tag` (release tag `vX.Y.Z`)    |

Heroku apps are `<image_name>-<env>`: `lucuma-sso`, `itc`, `lucuma-postgres-odb` (process types
`web calibration obscalc pdfsummary`), `lucuma-resource`. Sso and Odb get a `pg:backups:capture`
before promotion.

Firebase sites and projects (ResourceUi and AdminUi; Explore is not on Firebase):

| System     | Project         | dev                  | staging                   | production         |
|------------|-----------------|----------------------|---------------------------|--------------------|
| ResourceUi | `resource-ae0b7`| `resource-ae0b7-dev` | `resource-ae0b7-staging`  | `resource-ae0b7`   |
| AdminUi    | `admin-679f7`   | `admin-679f7-dev`    | `admin-679f7-staging`     | `admin-679f7`      |

AWS buckets and CloudFront distributions (Explore only, which is hosted on S3 + CloudFront and
nowhere else):

| Env        | Bucket                   | Distribution     |
|------------|--------------------------|------------------|
| dev        | `gemini-edu-explore-dev` | `E3DZG7GNUB60T6` |
| staging    | `gemini-edu-explore-test`| `E2E5A5UYD8VLF7` |
| production | `gemini-edu-explore-prd` | `E1VDJ0RPRW1PVL` |

Credentials are shared ones kept in `secrets.yaml` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_REGION`), which direnv decrypts into the environment.

Each distribution serves its bucket with origin path `/latest`, so the live site of an environment
is `s3://<bucket>/latest/`, never the bucket root.

Build archive: the CI archives every Explore build at `s3://gemini-edu-explore-dev/builds/<git-sha>/`
(same object metadata as the live copy). The archive is always in the dev bucket, whatever the
source environment. A promotion deploys the source record's sha, a rollback the bundle's
`s3_build`. Before anything is touched, `aws s3 ls <archive>/index.html` must succeed, otherwise
the run stops. The copy is, assets first so a user loading the new `index.html` mid-copy still
finds its bundles, then the rest, then stale files are removed:

```
aws s3 cp <archive>/assets s3://<bucket>/latest/assets --recursive --only-show-errors --copy-props metadata-directive
aws s3 cp <archive> s3://<bucket>/latest --recursive --only-show-errors --exclude "assets/*" --copy-props metadata-directive
aws s3 sync <archive> s3://<bucket>/latest --delete --only-show-errors --copy-props metadata-directive
aws cloudfront create-invalidation --distribution-id <id> --paths "/*" --query Invalidation.Id --output text
```

The copy is `cp`, not `sync`: `sync` skips files of the same size when the source is older, which is
the case whenever an earlier build is deployed (a rollback, or a staging to production promotion
whose archive predates production's last write), and it would keep the newer `index.html` and
`sw.js` (`index.html` has the same size across builds, only the asset hashes in it change). The
final `sync --delete` only removes what the archive no longer has, once the new build is complete.
`--copy-props metadata-directive` keeps the archive's Cache-Control and Content-Type. Because the
target is a prefix, `--delete` never
reaches `builds/` when the target is the dev bucket itself. Dev is still not a `rollback.sh` target,
simply because no bundle is written for it: the CI deploys dev on every merge (the same archive to
`latest/` copy), and that is how it is restored.

GitHub deployment records (environment / task) per system:

| System     | dev                      | staging               | production               | task            |
|------------|--------------------------|-----------------------|--------------------------|-----------------|
| Sso, Itc, Odb, Resource, Explore, Observe | `development` | `staging`  | `production`             | `deploy:SSO`, `deploy:ITC`, `deploy:ODB`, `deploy:RESOURCE`, `deploy:Explore`, `deploy:Observe` |
| ResourceUi | `resource-ui-dev`        | `resource-ui-staging` | `resource-ui-production` | `deploy`        |
| AdminUi    | `admin-ui-dev`           | `admin-ui-staging`    | `admin-ui-production`    | `deploy`        |
| Navigate   | `navigate-dev-gn`        | `navigate-staging`    | `navigate-production`    | `deploy`        |

Dev records are written by CI. Heroku records carry `payload.docker_image_shas`; Observe and
Navigate records carry `payload.docker_tag`; Navigate's dev record has no payload, its `ref` is the
release tag.

Databases with migrations, and where the version number comes from:

| Database   | Where                                                           | Version                       |
|------------|-----------------------------------------------------------------|-------------------------------|
| odb        | lucuma-odb `modules/service/src/main/` (sql and scala files)    | max `V<n>__` number           |
| sso        | lucuma-odb `modules/sso-service/src/main/`                      | max `V<n>__` number           |
| resource   | lucuma-odb `resource/service/src/main/`                         | max `V<n>__` number           |
| user_prefs | lucuma-apps `explore/hasura/user-prefs/migrations/default/`     | max numeric directory prefix  |

The three Flyway numbers are read from the GitHub trees API at the promoted lucuma-odb commit
(`GET /repos/gemini-hlsw/lucuma-odb/git/trees/<sha>?recursive=1`, filtered by path prefix). The
call fails if the response says `truncated: true` rather than recording a lower number. The
user_prefs number is read from the sparse checkout described under Hasura.

## Sources of truth

- **GitHub deployment records** stay the per-system audit trail and the thing `promote.sh`
  compares to decide what changed. They are written by CI for dev, and by `promote.sh` and
  `rollback.sh` for staging and production. This keeps `promote.sh` idempotent: re-running after a
  partial failure skips the systems whose records already match.
- **Bundles** are the environment snapshot. They are written after the fact, from the identifiers
  that were just deployed plus the ones that did not change. `rollback.sh` reads them, and the
  servers read them.

Secrets never go in a bundle. The bundle writer builds its JSON from an explicit list of fields; it
never dumps an API response.

## Bundles

Path: `bundles/<env>/<id>.json`, id `YYYY-MM-DDTHH-MM-SSZ` in UTC. Files are only added, never
edited. `bundles/<env>/current.json` is a copy of the newest one.

```json
{
  "schema": 1,
  "id": "2026-10-30T14-37-37Z",
  "environment": "staging",
  "source": "dev",
  "rollback_of": null,
  "created_at": "2026-10-30T14:37:37Z",
  "created_by": "cquiroz",
  "migrations": { "odb": 1376, "sso": 4, "resource": 0, "user_prefs": 1792331515894 },
  "systems": {
    "Sso":        { "repo": "gemini-hlsw/lucuma-odb",  "sha": "…", "changed": true,  "heroku_app": "lucuma-sso-staging", "docker_image_shas": { "web": "sha256:…" }, "backup": "b123" },
    "Itc":        { "repo": "gemini-hlsw/lucuma-odb",  "sha": "…", "changed": false, "heroku_app": "itc-staging", "docker_image_shas": { "web": "sha256:…" } },
    "Odb":        { "repo": "gemini-hlsw/lucuma-odb",  "sha": "…", "changed": true,  "heroku_app": "lucuma-postgres-odb-staging", "docker_image_shas": { "web": "…", "calibration": "…", "obscalc": "…", "pdfsummary": "…" }, "backup": "b124" },
    "Resource":   { "repo": "gemini-hlsw/lucuma-odb",  "sha": "…", "changed": false, "heroku_app": "lucuma-resource-staging", "docker_image_shas": { "web": "…" } },
    "Explore":    { "repo": "gemini-hlsw/lucuma-apps", "sha": "…", "changed": true,  "s3_bucket": "gemini-edu-explore-test", "cloudfront_distribution": "E2E5A5UYD8VLF7", "s3_build": "…" },
    "ResourceUi": { "repo": "gemini-hlsw/lucuma-ts",   "sha": "…", "changed": false, "firebase_site": "resource-ae0b7-staging", "firebase_version": "…" },
    "AdminUi":    { "repo": "gemini-hlsw/lucuma-ts",   "sha": "…", "changed": false, "firebase_site": "admin-679f7-staging", "firebase_version": "…" },
    "Observe":    { "repo": "gemini-hlsw/lucuma-apps", "sha": "…", "changed": false, "docker_tag": "20261021-517c78c5" },
    "Navigate":   { "repo": "gemini-hlsw/lucuma-ts",   "sha": "…", "changed": true,  "docker_tag": "v0.16.24" }
  }
}
```

Rules:

- Every system appears in every bundle. An unchanged system repeats its identifiers with
  `changed: false`, so any bundle is a complete rollback target on its own.
- `migrations` are the numbers the deployed builds carry, which is what the database is at once the
  apps start (Flyway runs at boot; Hasura migrations are applied by `promote.sh`).
- `source` is the environment promoted from, or `null` for a rollback; `rollback_of` is the id of
  the bundle rolled back to, or `null` for a promotion.
- `backup` is the Heroku backup id captured before the promotion, when there was one.
- Firebase versions are read from the live channel after the clone, for the two Firebase systems
  (ResourceUi and AdminUi) whether or not they changed, so the bundle records what is actually live.
- Explore's entry has `s3_bucket`, `cloudfront_distribution` and `s3_build`: the target
  environment's bucket and distribution, and the archived build live on it (the same value as
  `sha`, kept as the explicit restore identifier), whether or not Explore changed. No other system
  has these fields. Explore has no Firebase fields; bundles written while it was also on Firebase
  still carry `firebase_site` and `firebase_version` for it, which are ignored when reading them.

### current.tags

The server scripts parse with plain shell tools only, so next to `current.json` the writer also emits `current.tags`, a flat
file derived from it:

```
bundle=2026-10-30T14-37-37Z
observe=20261021-517c78c5
navigate=v0.16.24
```

The servers fetch
`https://raw.githubusercontent.com/gemini-hlsw/lucuma-deploy/refs/heads/main/bundles/<env>/current.tags`.

### Retention

`BUNDLE_RETENTION_MONTHS=6` at the top of `promote.sh`. After writing a bundle, files whose id is
older than the cutoff are `git rm`'d in the same commit. Ids are ISO timestamps, so the comparison
is a lexical compare of the file name against the cutoff. `current.json` and `current.tags` are
never pruned. Pruned bundles stay in git history.

### Commit and push

Bundle files are written only after every system succeeded. Then, from the repo this script lives
in: `git add bundles/<env>`, commit `bundle: <env> <id> (from <source>)` or
`bundle: <env> <id> (rollback of <target id>)`, `git push`. If the push is rejected, `git pull
--rebase -X theirs` (during a rebase, `theirs` is our commit) and push again, twice. If it still
fails, print the commit and the push command to run by hand. Deploy, records, bundle, commit, push,
in that order: a push failure never leaves the environment half-deployed, only unrecorded.

Preflight before touching anything: the script runs from its own repo checkout, on `main`, with a
clean tree (`git status --porcelain` empty), after `git pull --ff-only`. `--dry-run` runs the
preflight and prints the bundle it would write, but writes nothing.

## promote.sh

`promote.sh <source_env> <target_env> [--dry-run] [--skip-slack] [--debug]`, same flags as
before. Valid environments: `dev`, `staging`, `production`; source and target must differ.

1. Preflight (above). Required tools: `git gh jq curl heroku firebase aws hasura`.
2. For each system, read the source and target deployment records; `changed` when the shas differ
   or the target has no record. Fail if a source record is missing, or lacks the image shas or tag
   it should carry.
3. Hasura: sparse checkout of lucuma-apps at the Explore *source* sha (see below), then the same
   pending-migrations and metadata-diff checks as before, run from that checkout.
4. Migration numbers for the bundle: the three Flyway numbers from the lucuma-odb source sha, the
   user_prefs number from the sparse checkout.
5. Summary, then `--dry-run` prints the Slack messages, the manual commands and the bundle JSON it
   would write, and exits.
6. Promote, same order and same calls as before: Heroku formation PATCH per process type with the
   source image id (backup first for Sso and Odb), manual systems print their command, Hasura
   apply, Firebase clone `<src>:live` to `<tgt>:live` for ResourceUi and AdminUi with
   `--project`. For Explore, which is on AWS only: the build of the source sha is copied from
   the archive onto the target bucket (see above), then the target distribution is invalidated.
   After each system: deployment record, Slack message, once per system as before. Before
   anything is deployed (and in `--dry-run` too) every changed AWS system's build must be in the
   archive. `--dry-run` runs the two syncs with `--dryrun` and never invalidates.
7. Read the live Firebase version of the two target Firebase sites.
8. Build the bundle, write it, prune, commit, push. One final Slack message with the bundle id and
   a link to the file on GitHub.

Unchanged systems get their identifiers from the target deployment record (or, for Firebase, from
the live lookup in step 7).

### Hasura from a sparse checkout

Today's script applies whatever `explore/hasura/user-prefs` the operator has checked out. Instead:

```
tmp=$(mktemp -d)
git clone --quiet --filter=blob:none --sparse --no-checkout https://github.com/gemini-hlsw/lucuma-apps "$tmp"
git -C "$tmp" sparse-checkout set explore/hasura/user-prefs
git -C "$tmp" checkout --quiet "$explore_source_sha"
```

`LUCUMA_APPS_CHECKOUT=<dir>`, when set, is used instead of cloning (for tests and for working
offline). The checkout is removed on exit.

### Slack

Per-system messages keep today's wording. Manual systems:

```
⚠️ Observe promoted from dev → staging — manual step required
Changes: <compare link>
Run on the GN and GS staging Observe servers (deploys 20261021-517c78c5):
```observe update```
Time: 2026-10-22 17:39:36 UTC
```

Final message: `📦 staging bundle 2026-10-30T14-37-37Z written: <link to bundles/staging/<id>.json on GitHub>`.

## rollback.sh

`rollback.sh <env> [<bundle-id>] [--dry-run] [--skip-slack] [--debug]`. `env` is `staging` or
`production`. Replaces `rollback-servers.sh`.

Without a bundle id: list the bundles of the environment, newest first, one line each: id,
created_at, `from <source>` or `rollback of <id>`, and the systems marked changed. Exit 1.

With a bundle id:

1. Preflight as `promote.sh`.
2. Load the target bundle T and `current.json` C. For each system, `changed` when the identifier
   differs (image shas, firebase version, s3 build or docker tag; Explore is compared by its
   `s3_build`). For a changed AWS system T's `s3_build` must exist and be in the archive, otherwise
   the rollback is refused here, before the migration check, the dry-run exit, the confirmation
   and any Heroku or Firebase call.
3. Migration check. The database only moves forward, so the effective current number per database
   is the maximum over every bundle file in `bundles/<env>/`, not just C. For each database where
   T's number is lower, print a loud warning that the schema is ahead of the build and will not be
   undone. Then ask for confirmation by typing the environment name; anything else aborts.
4. `--dry-run` prints what would change and the bundle it would write, and exits.
5. Apply: Heroku formation PATCH with T's image ids; Firebase `hosting:clone <site>@<version>
   <site>:live --project <project>`; manual systems print `observe update` / `navigate update`.
   For a changed AWS system (Explore, which has no Firebase clone), the bundle's `s3_build` is
   copied from the archive onto the env's bucket and the distribution is invalidated. Hasura is
   not touched.
6. Deployment record per changed system, `ref` = T's sha, description `Rollback to bundle <id>`,
   payload as in promotion. Slack per changed system: `⏪ <System> rolled back in <env> to <sha7>
   (bundle <id>)`, manual systems with the command block.
7. New bundle: T's identifiers and migration numbers, new id, `source: null`, `rollback_of: T.id`,
   `changed` as computed in step 2, Firebase versions of ResourceUi and AdminUi re-read from the
   live channels. Write, prune, commit, push. Final Slack message as in promotion.

## Server scripts

Ported from `observe/deploy/scripts` (lucuma-apps) and `deploy/` (lucuma-ts) with these changes:

- `update` with no arguments fetches `current.tags` for the server's environment (from `SITE`:
  `staging-gn`, `staging-gs`, `production-gn`, `production-gs`, nothing else accepted), deploys the
  tag, writes it to `deployed-version` and the bundle id to `deployed-bundle`. If both already
  match, print `Already on <tag> (bundle <id>)` and exit 0.
- `update --force-version <tag>` keeps today's warning and `yes` confirmation. No tag ordering
  check anywhere: a rollback is just another `update`.
- `version` prints `<tag> (bundle <id>)`, or just the tag when `deployed-bundle` is missing.
- Installers and the `install.sh` self-check download from
  `https://raw.githubusercontent.com/gemini-hlsw/lucuma-deploy/refs/heads/main/servers/<app>/`.
- `servers/CONTRACT.md` lists, per image, the env vars it reads and the paths it expects mounted,
  so a change to an image's expectations is a change to that file.

## Tests

See [TESTS.md](TESTS.md).

## Implementation notes

- Flyway numbers are read at each database's own system sha (odb at Odb, sso at Sso, resource at Resource), not one shared lucuma-odb sha.
- Promotion aborts before deploying anything if an unchanged system's target record lacks its `docker_image_shas` or `docker_tag`.
- `promote.sh --snapshot <env>` (`staging` or `production`) writes a bundle of what the environment runs now and promotes nothing, whatever is pending: the environment is read as its own source, so every system is `changed: false` with the identifiers of its own records and live Firebase versions; `source` is `null`, the commit message ends in `(snapshot)`, and Hasura is not checked. `--dry-run` only prints it.
- When nothing changed but `bundles/<target>/current.json` is missing, `promote.sh` writes the initial bundle (every system `changed: false`, identifiers from the target records); `--dry-run` only prints it.
- `rollback.sh --dry-run` exits after the migration check and never asks for confirmation.
- `rollback.sh <env>` (listing) does a best-effort `git pull --ff-only` only, not the full preflight.
- If the push still fails after the retries, the script prints the commit and push command and exits 1 without the final Slack message.
