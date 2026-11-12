- Place these files on `~/observe` in each server.
- Set the `SITE`, `DOCKERHUB_TOKEN` and `LOCAL_LOG_DIR` variables in `config.sh`.

The deployed version is not part of `config.sh`. The only way to change it is `observe update`,
which deploys the tag of the current lucuma-deploy bundle of the server's environment (`staging` or
`production`, taken from `SITE`). It reads that tag, and the bundle id, from
`bundles/<environment>/current.tags` in the lucuma-deploy repo, which `promote.sh` and
`rollback.sh` rewrite, so the server needs access to raw.githubusercontent.com. If the server is
already on that tag and bundle, `observe update` says so and does nothing. A rollback is just
another `observe update` once `rollback.sh` has been run. `observe update --force-version <tag>`
deploys another tag instead, after a warning and a confirmation prompt: anything other than the
promoted version may be incompatible with the other systems of the environment. Tags are
`YYYYMMDD-<sha8>` as published by CI (e.g. `20260916-4b3faa6d`). The current tag is stored in
`~/observe/deployed-version` and the bundle id in `~/observe/deployed-bundle` (both written only by
`update`; a forced deploy removes `deployed-bundle`, since the server is no longer on a bundle).
`observe version` shows `<tag> (bundle <id>)`, or just the tag when there is no bundle.
`observe start` and `observe restart` reuse the tag.

The per-subsystem control modes (`observe-engine.subsystem-control-modes`) live in
`~/observe/conf/subsystems.conf`, which is now written by the Observe UI (Subsystems dialog) for the
subsystems of the running site. The UI can also restart the server for the new modes to take
effect, when nothing is running: the server exits cleanly and the container's
`--restart unless-stopped` policy brings it back (the server exits with code 3 on such a restart).

The env vars and mounts the image expects are listed in `../CONTRACT.md`.

You can use the commands in `install.sh` to copy the latest version of the scripts:

```
curl https://raw.githubusercontent.com/gemini-hlsw/lucuma-deploy/refs/heads/main/servers/observe/install.sh >install.sh
chmod +x install.sh
./install.sh
```
