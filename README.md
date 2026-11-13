# lucuma-deploy

Everything about promoting, rolling back and deploying the GPP systems (Sso, Itc, Odb, Resource,
Explore, ResourceUi, AdminUi, Observe, Navigate):

- `promote.sh` promotes every changed system from one environment to the next.
- `rollback.sh` rolls an environment back to an earlier snapshot.
- `bundles/<env>/` holds one snapshot ("bundle") of staging and production per promotion or
  rollback, plus `current.json` and `current.tags`.
- `servers/` holds the scripts installed on the Observe and Navigate servers.

The design, the bundle format and the rules behind them are in [DESIGN.md](DESIGN.md).

## Setup

Needed: `bash` 4 or later, `git`, `gh`, `jq`, `curl`, `heroku`, `firebase`, `aws` and `hasura`. The
easiest way to get them is the dev shell: with [Nix](https://nixos.org) and
[direnv](https://direnv.net) installed, `cd` into the repo and everything is on `PATH`. Once per
clone:

1. `direnv allow`. The first time, Nix downloads the tools, which takes a few minutes.
2. Log in: `gh auth login`, `heroku login`, `firebase login`. `hasura` needs nothing: the
   user-prefs instances have no admin secret. `aws` needs no login either: the shared credentials
   for the Explore buckets come from `secrets.yaml` (step 3).
3. Put the GPP age key in the repo as `deploy-keys.txt` (gitignored). It is the same key used by
   `secrets.yaml` in lucuma-apps, so if you already have the key in lucuma-apps, copy it:
   ```
   cp ../lucuma-apps/apps-keys.txt deploy-keys.txt
   ```
   A symlink works too (`ln -s ../lucuma-apps/apps-keys.txt deploy-keys.txt`) and follows the
   lucuma-apps file if the key is ever replaced. Otherwise ask a team member for the key. With it
   in place, direnv decrypts `secrets.yaml` into the environment on every `cd`, which is where
   `GPP_SLACK_WEBHOOK_URL` and the AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
   `AWS_REGION`) come from.

Without the dev shell, install the tools yourself and export those four variables. GitHub auth
comes from `GPP_GITHUB_TOKEN` or, when unset, from `gh auth token`. Slack messages go to channel
`GPP_SLACK_CHANNEL` (default `#gpp`); `--skip-slack` turns them off.

The scripts write and push bundles from the checkout they live in, so before doing anything they
check that it is on `main` with a clean tree and run `git pull --ff-only`; they abort otherwise.

**Do not require pull requests or restrict who can push on `main`.** Every promotion and rollback
ends by pushing a bundle commit straight to `main`. If that push is refused, the systems are
deployed but the bundle is not recorded, and the Observe and Navigate servers keep reading the old
`current.tags`. Everyone who promotes needs write access to this repo. Blocking force pushes and
deletion of `main` is fine, and recommended, since it protects the bundle history.

## Promote

```
./promote.sh dev staging --dry-run       # what would change, the Slack messages, the bundle
./promote.sh dev staging
./promote.sh staging production
```

`promoteDevAllToStaging.sh` and `promoteStagingAllToProduction.sh` are shortcuts for the two
lines above and pass extra flags through. Other flags: `--skip-slack`, `--debug`.

Explore is hosted on AWS only (S3 + CloudFront). The build is copied from the build archive
(`s3://gemini-edu-explore-dev/builds/<sha>/`, filled by the CI on every dev deploy) onto the `latest/`
prefix of the target bucket, which the CloudFront distribution serves, then the CloudFront cache of
the target is invalidated. Every file is copied unconditionally (an S3 sync would skip the
same-sized but older `index.html` of an earlier build), then stale files are removed. The script
stops before deploying anything when the build is not archived. `--dry-run` lists what the S3 copy
would do and never invalidates.

Observe and Navigate are not deployed by the script: it prints the `observe update` /
`navigate update` command to run on the GN and GS servers of the environment.

Re-running after a failure is safe: systems whose GitHub deployment record already matches are
skipped. The bundle is written, committed and pushed only after every system succeeded.

## Roll back

```
./rollback.sh production                                  # list bundles, newest first
./rollback.sh production 2026-10-30T14-37-37Z --dry-run
./rollback.sh production 2026-10-30T14-37-37Z
```

The script warns loudly when a database has migrations newer than the bundle (migrations are
never undone), then asks you to type the environment name. It redeploys the Heroku images and
Firebase versions of the bundle (Resource UI and Admin UI), prints the Observe and Navigate
commands, records the deployments, and writes a new bundle with `rollback_of` set. Explore is
rolled back on AWS, by copying the bundle's build from the archive; a build older than the archive
retention cannot be restored, and the script then refuses, before changing anything.

## How the servers use bundles

Next to each `current.json` there is a flat `current.tags` with just what the Observe and Navigate
servers need, in a format their scripts can read with plain shell tools:

```
bundle=2026-10-30T14-37-37Z
observe=20261021-517c78c5
navigate=v0.16.24
```

`observe update` / `navigate update` fetch
`https://raw.githubusercontent.com/gemini-hlsw/lucuma-deploy/refs/heads/main/bundles/<env>/current.tags`
and deploy the tag in it, so after a promotion or a rollback the operator only runs `update`. What
each server image expects (env vars, mounts) is in [servers/CONTRACT.md](servers/CONTRACT.md).

## Tests

```
test/run.sh
```

Fully offline: stub CLIs, a throwaway copy of this repo and a local bare remote. What is covered
and how the harness works is in [TESTS.md](TESTS.md).
