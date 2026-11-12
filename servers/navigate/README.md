# Running a docker Navigate instance (Production and Staging)

You can install a navigate cluster using the installation script in this directory and in
[this link](https://raw.githubusercontent.com/gemini-hlsw/lucuma-deploy/refs/heads/main/servers/navigate/install.sh).

IMPORTANT!
A running docker service is required to install navigate, the user installing navigate should have permissions to run docker commands. Also, the docker images are hosted under `noirlab` organization, so the `nlsoftware` user should be used to pull docker images, which requires a `docker login`,

After running the install.sh script, the `navigate` command will be enabled to `start`, `stop` and `update` the cluster. For more information try the command `navigate help`.

`navigate update` deploys the release tag of the current lucuma-deploy bundle of the server's environment (`staging` or `production`, taken from `SITE` in `.env`). It reads that tag, and the bundle id, from `bundles/<environment>/current.tags` in the lucuma-deploy repo, which `promote.sh` and `rollback.sh` rewrite, so the server needs access to raw.githubusercontent.com. If the server is already on that tag and bundle, `navigate update` says so and does nothing. A rollback is just another `navigate update` once `rollback.sh` has been run. `navigate update --force-version <tag>` deploys another tag instead, after a warning and a confirmation prompt: anything other than the promoted version may be incompatible with the other systems of the environment. The tag is stored in `~/navigate/deployed-version` and the bundle id in `~/navigate/deployed-bundle` (both written only by `update`; a forced deploy removes `deployed-bundle`). `navigate version` shows `<tag> (bundle <id>)`, or just the tag when there is no bundle.

The env vars and mounts of each container are listed in `../CONTRACT.md`.

This snippet can be used in order to run the `install.sh` script.

```bash
curl https://raw.githubusercontent.com/gemini-hlsw/lucuma-deploy/refs/heads/main/servers/navigate/install.sh >install.sh
chmod +x install.sh
./install.sh
```
