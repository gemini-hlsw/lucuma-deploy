# Tests

```
test/run.sh            # everything: promote, rollback, libraries, server scripts
test/servers.sh        # only the Observe and Navigate server scripts
KEEP_TMP=1 test/run.sh # keep the temp dir to inspect bundles, logs and the fake remote
```

Both scripts are plain bash and need `git`, `jq` and `curl`. Nothing touches the network, a
docker daemon, Heroku, Firebase, Hasura or GitHub: every external CLI is replaced by a stub, so
the suite runs anywhere in a few seconds and exits non-zero on the first `FAIL:` line.

## What `test/run.sh` does

It runs `promote.sh` and `rollback.sh` end to end against fakes and checks their effects.

**Setup.** A temp dir gets a copy of this repo (without `.git`) committed to a fresh local bare
repo that acts as `origin`, so pulls, commits and pushes are real git operations against a repo
the test can inspect. The user's global git config is replaced by a minimal one (no signing, no
hooks). Then `test/stubs` is put first on `PATH`.

**Fixtures.** Before running anything the test plants:

- GitHub deployment records for all nine systems in `development`, `staging` and `production`,
  served by the stub `curl` from `$STUB_FIXTURES/deployments/<owner>/<repo>/<env>/<task>.json`.
  They are built so that each situation the scripts must handle exists at least once: systems
  that changed, systems at the same sha in both environments (so their identifiers must come from
  the target record), a Navigate dev record whose ref is the release tag, Explore records with no
  payload.
- Git trees for the lucuma-odb shas (`$STUB_FIXTURES/trees/<sha>.json`), with Flyway files in
  several modules, so the migration numbers per database can be checked, plus one marked
  `truncated` to prove the scripts refuse it.
- A fake lucuma-apps checkout with two Hasura `user-prefs` migrations, pointed at by
  `LUCUMA_APPS_CHECKOUT`, so no sparse checkout is attempted.
- Two staging bundles: one dated 2020 that the next promotion must prune, and one a month old
  that must survive.

**Scenarios**, in order:

1. `promote dev staging --dry-run`: prints the plan, calls nothing, writes nothing; the only AWS
   calls are the archive check and the three `--dryrun` Explore copies, never an invalidation.
1a. `promote dev staging` with the Explore build missing from the archive: fails before any
   Heroku PATCH, backup, Firebase clone, record or bundle.
2. `promote dev staging --skip-slack`: deploys through the stubs; a staging bundle appears,
   `current.json` and `current.tags` are updated, the old bundle is pruned, the commit is pushed
   to the fake origin, and the stub logs show the expected Heroku, Firebase (ResourceUi and
   AdminUi only, none for Explore), AWS (assets copy, the rest, stale-file sync, invalidation),
   Hasura and GitHub calls, with one Explore record.
3. `promote staging production` when nothing changed and production has no bundle: the
   bootstrap bundle is written (dry run only prints it).
4. `promote staging production --skip-slack` twice: the first run promotes, the second is a
   no-op because the deployment records already match.
5. `rollback production` lists the bundles, newest first.
6. `rollback production <id> --dry-run` prints the migration warning and never prompts.
7. `rollback production <id>` with a wrong confirmation word changes nothing.
8. `rollback production <id>` with the right word: Heroku formations patched to the bundle's
   image ids, the Firebase sites of ResourceUi and AdminUi cloned from the bundle's versions,
   Explore (no Firebase) copied from its archived build onto the production bucket and the
   distribution invalidated, records created, a new bundle with `rollback_of` set, commit pushed.
9. `rollback production <id>` where Explore would change (its `s3_build` differs from the current
   bundle's) and its build is not archived (a planted bundle, which also carries the obsolete
   Firebase fields of Explore that must be ignored, `STUB_AWS_MISSING` set to its build): exits
   non-zero naming the build and the archive, with and without `--dry-run`, before the migration
   check and the prompt, and makes no Heroku PATCH, Firebase clone, deployment POST, copy or bundle.
9a. `rollback production <id>` to a planted copy of the current bundle whose only difference is an
   obsolete Explore Firebase version: nothing to roll back, because Explore is compared by
   `s3_build` alone; no AWS, Firebase or GitHub write is made.
10. Library checks: a truncated tree is an error, the retention cutoff is six months back, and
   every script passes `bash -n`.
11. `test/servers.sh` (below), run with the real `curl` restored on `PATH`.

**What a check looks like.** `check "<description>" <command>` passes when the command succeeds,
`check_eq` compares two strings. Most checks read a bundle field with `jq`, compare `HEAD` of the
work tree with `main` of the fake origin, or grep the stub logs in `$STUB_LOG`.

## What `test/servers.sh` does

It runs `servers/observe/observe.sh` and `servers/navigate/navigate.sh` in a temp `HOME` with a
stub `docker` and with `LUCUMA_DEPLOY_RAW_URL` pointing at a `file://` directory, so
`current.tags` is a local file the test rewrites between steps. It needs the real `curl`, which
is why only the docker stub is put on `PATH`.

For each app it checks: `version` fails with nothing deployed; the old `update <tag>` syntax is
rejected; bare `update` deploys the promoted tag and records tag and bundle id; a second `update`
says `Already on` and does not call docker; a new bundle with the same tag redeploys; a new tag
redeploys; `--force-version` of a different tag warns, needs `yes`, and clears the recorded bundle
id; `--force-version` of the promoted tag does not warn; a missing or incomplete `current.tags`
fails without changing anything; an invalid `SITE` is rejected.

## The stubs

Each stub in `test/stubs` logs its arguments to `$STUB_LOG/<name>.log` (`curl` logs one JSON
line per request to `curl.jsonl`). All but `docker` exit non-zero on anything they do not
recognise, so an unexpected call fails the test instead of silently succeeding.

- `curl` routes on the URL: deployment records and trees from `$STUB_FIXTURES`, deployment
  creation returns `{"id": 1}`, Heroku and Slack return success.
- `heroku` answers `container:login` and `pg:backups:capture`.
- `firebase` answers `hosting:channel:list` and `hosting:clone`; with `STUB_STATE_DIR` set it
  remembers clones so a later list returns the cloned version, which is how the rollback test
  verifies the restored versions.
- `aws` answers `s3 ls` (a fake listing line, or exit 1 with "stub aws: not found" when the path
  contains a sha of the space-separated `STUB_AWS_MISSING`), `s3 cp` and `s3 sync` (a fake `copy:`
  line, prefixed `(dryrun)` with `--dryrun`; fail unless `--copy-props metadata-directive` is given,
  `cp` also unless `--recursive`) and
  `cloudfront create-invalidation` (printing `I2FAKE123`).
- `hasura` answers `migrate status` (one migration pending unless `STUB_HASURA_PENDING=0`),
  `metadata diff` and `migrate apply`, logging the directory it ran in.
- `gh` always fails: the tests set `GPP_GITHUB_TOKEN` and `GPP_PROMOTER`, so a call to `gh` is a
  bug.
- `docker` accepts anything and echoes `[stub docker] <args>` to stdout, which the server tests
  grep for.

## Adding a test

Add fixtures next to the existing ones, a new numbered section in `test/run.sh` (or a scenario
in `test/servers.sh`), and `check` lines. If a script starts calling a CLI in a new way, teach
the stub that call first: the stub's "unexpected command" failure is the signal.
