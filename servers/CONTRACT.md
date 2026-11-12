# Server image contract

What the scripts in `observe/` and `navigate/` give each container, and so what each image may
rely on. If an image starts to expect a different env var or mount, change this file and the
matching script (`observe/start.sh`, `navigate/docker-compose.yml`) in the same PR, so the server
scripts and the images never drift apart.

## SITE

`SITE` is one of `staging-gn`, `staging-gs`, `production-gn`, `production-gs`; nothing else is
accepted by `update`. Dropping the `-gn` / `-gs` suffix gives the environment (`staging` or
`production`) whose `current.tags` the server follows. Inside the Observe and Navigate server
images, `SITE` selects the configuration `conf/<SITE>/site.conf` baked into the image. `SITE`
comes from `~/observe/config.sh` on Observe servers and from `~/navigate/.env` on Navigate
servers, and is passed to the container as the env var `SITE`.

## noirlab/gpp-obs (Observe server)

Started by `observe/start.sh` with `docker run --name observe-server --restart unless-stopped -d
--network host`. The tag is the content of `~/observe/deployed-version`.

Env vars:

| Variable | Value                   |
|----------|-------------------------|
| `SITE`   | `SITE` from `config.sh` |

Mounts (bind):

| Host path                           | Container path           | Purpose |
|-------------------------------------|--------------------------|---------|
| `/home/software/observe/conf`       | `/opt/docker/conf/local` | Local overrides, including `subsystems.conf` written by the Observe UI |
| `$LOCAL_LOG_DIR` (from `config.sh`) | `/log`                   | Logs |

Network: host.

## noirlab/gpp-nav (Navigate server)

Service `server` in `navigate/docker-compose.yml`, container `navigate-server`, `restart:
unless-stopped`, `network_mode: host`. The tag is `NAVIGATE_TAG`, read from
`~/navigate/deployed-version`.

Env vars:

| Variable | Value              |
|----------|--------------------|
| `SITE`   | `SITE` from `.env` |

Mounts (bind):

| Host path (from `.env`)      | Container path               | Purpose |
|------------------------------|------------------------------|---------|
| `CONFIG_DIR`                 | `/opt/docker/conf/local/`    | `secrets.conf`, `site.jks` and other local configuration |
| `LOGS_DIR`                   | `/gemsoft/var/log/navigate/` | Logs |
| `EPHEMERIDES_DIR` (required) | `/ephemerides/`              | Ephemerides files |

Ports published (ignored under host networking, kept for documentation): `NAVIGATE_EXPOSE_PORT`
to 7070, 5064, 5065.

## noirlab/gpp-nav-configs (Navigate configs API)

Service `configs`, container `navigate-configs`, same `NAVIGATE_TAG` as the server.

Env vars:

| Variable       | Value                                                            |
|----------------|------------------------------------------------------------------|
| `DATABASE_URL` | `postgresql://${DB_USER}:${DB_PASS}@navigate-db:5432/${DB_NAME}` |
| `SERVER_PORT`  | `SERVER_PORT` from `.env`                                        |

Volumes: named volume `navigate-configs-volume` at `/usr/src/app/dbinit`. Port 4000 is published.
Starts after the database is healthy.

## postgres (Navigate database)

Service `database`, container `navigate-db`, image `postgres:${POSTGRES_VERSION}` (the major version
must match the data in the volume).

Env vars:

| Variable            | Value                             |
|---------------------|-----------------------------------|
| `POSTGRES_PASSWORD` | `DB_PASS` from `.env`             |
| `POSTGRES_USER`     | `DB_USER` from `.env`             |
| `POSTGRES_DB`       | `DB_NAME` from `.env`             |
| `PGDATA`            | `/var/lib/postgresql/data/pgdata` |

Volumes: named volume `navigate-database-volume` at `/var/lib/postgresql/data`. Port
`EXPOSE_DB_PORT` is published to 5432.

`dpage/pgadmin4` (service `pgadmin`) is an optional admin tool, not part of the deployed bundle.
