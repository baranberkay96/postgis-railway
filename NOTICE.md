# NOTICE: PostGIS 3.6 Spatial Database on Postgres 18 template

This is a community template. It is not affiliated with or endorsed by the PostGIS project, OSGeo, the PostgreSQL Global Development Group or Railway. Product names belong to their owners.

## Software used

| Component | Source | License | How it is used |
|---|---|---|---|
| Railway SSL Postgres image | `ghcr.io/railwayapp-templates/postgres-ssl:18`, built from https://github.com/railwayapp-templates/postgres-ssl (`Dockerfile.18`) | MIT, "Copyright (c) 2023 Railway" | Base image of the PostGIS service, used unmodified (its `wrapper.sh`, `init-ssl.sh` and pgBackRest scripts run as shipped). `entrypoint.sh` execs that wrapper. The `include_dir` detection regex in `common.sh` is taken from `wrapper.sh` so both scripts recognise the same line; `rp_detect_cpus` follows the same cgroup-reading approach as its `detect_cpus`. |
| PostgreSQL 18 | PGDG packages inside the base image (18.6-1.pgdg13+2 at check time) | PostgreSQL License | Run unmodified |
| PostGIS 3.6 | `postgresql-18-postgis-3` and `postgresql-18-postgis-3-scripts` 3.6.x from apt.postgresql.org (trixie-pgdg), installed at image build | GPL-2.0-or-later (PostGIS); dependencies GEOS, PROJ, GDAL, SFCGAL, json-c, protobuf-c under their own licenses | Installed unmodified at build time on the user's Railway build. This repository contains no PostGIS code or binaries. |
| Official PostGIS Docker images | https://github.com/postgis/docker-postgis (`18-3.6/Dockerfile`, `initdb-postgis.sh`, `update-postgis.sh`) | MIT, "Copyright (c) 2014, Docker PostGIS Authors (See AUTHORS)" | Reference. The package names, the `template_postgis` template database and the default extension set (postgis, postgis_topology, fuzzystrmatch, postgis_tiger_geocoder before 3.7) follow upstream's `initdb-postgis.sh`; the scripts here were written for this template. |
| Alpine Linux 3.24 | `alpine:3.24.2` with `postgresql18-client` (18.6), `rclone` (1.74.x), `bash`, `curl`, `ca-certificates` from the Alpine repositories | Alpine packages under their own licenses (PostgreSQL License for the client, MIT for rclone) | Base image and packages of the backup service, installed unmodified |

Files written for this template: `services/postgis/Dockerfile`, `services/postgis/railway-postgis/{common.sh,entrypoint.sh,initdb-postgis.sh,postgis-update.sql}`, `services/backup/Dockerfile`, `services/backup/bin/{lib.sh,postgis-backup,postgis-restore}`, `template.json`, `TEMPLATE.md`, `README.md`, this file.

## Upstream files and docs checked (2026-10-20)

- `postgis/docker-postgis` at commit `148ce95110aaf09bd6db17283e12e5f4f4c510e8` (2026-10-18, "Move Debian images to trixie with PostGIS 3.6; add 19rc1 and 3.7.0rc2"): `18-3.6/Dockerfile` (`postgres:18-trixie`, `POSTGIS_VERSION=3.6.4+dfsg-2.pgdg13+1`), `18-3.6/initdb-postgis.sh`, `18-3.6/update-postgis.sh`, `LICENSE`. Identical to the copy in `_upstream/`.
- PostGIS release tags on `postgis/postgis`: latest stable 3.6.4; 3.7.0 is at rc2 (not released). Docker Hub `postgis/postgis:18-3.6` (digest `sha256:b4466ea2…`, pushed 2026-10-19, PG 18.6, PostGIS 3.6.4).
- `railwayapp-templates/postgres-ssl` (`_upstream/` copy): `Dockerfile.18`, `wrapper.sh` (volume locks, SSL renewal, pg_hba repair, pg_stat_statements, `conf.d` include, pgBackRest), `init-ssl.sh`, `README.md`, `LICENSE` (MIT). GHCR `postgres-ssl:18` = `18.6` (digest `sha256:fcc6686a…`, created 2026-10-09).
- `docker-library/postgres`: `18/trixie/docker-entrypoint.sh` (init script execution, `pg_hba.conf` catch-all rule, temp server) and `18/alpine3.24/Dockerfile` (`--with-zstd`, `--with-lz4`).
- apt.postgresql.org `trixie-pgdg` `Packages` and `Contents-amd64` (PostGIS 3.6.2–3.6.4 packages, control files), Debian `postgis` packaging `debian/postgresql-generic-postgis-scripts.postinst.in` (update-alternatives for the unversioned control files).
- Alpine 3.24 `APKINDEX` (main: `postgresql18-client` 18.6-r0; community: `rclone` 1.74.1-r3) and package contents (`/usr/libexec/postgresql18/`).
- PostGIS 3.6 source `postgis/sqldefines.h.in` (function cost levels, `_COST_HIGH COST 5000`).
- Railway docs: Storage Buckets (virtual-hosted URLs, no lifecycle rules, billing, service egress for uploads), Cron Jobs and `railway cron`, Point-in-Time Recovery, volume backups.

## Market templates and repositories reviewed

| Template / repo | License | Use |
|---|---|---|
| `postgis` "PostGIS" (721 active projects, `postgis/postgis:16-master`) | n/a (template config) | Variable names and TCP proxy layout compared; nothing copied. |
| `postgis-17` "PG 17 + PostGIS 3.5" (42 active, `postgis/postgis:17-master`) | n/a | Reviewed, nothing taken. |
| `timescaledb-postgis` (61 active, `ghcr.io/railwayapp-templates/timescale-postgis-ssl:pg16-ts2.13`) | n/a | Reviewed, nothing taken. |
| `_upstream/postgis__docker-postgis` | MIT | See above. |
| `_upstream/railwayapp-templates__postgres-ssl` | MIT | See above. |
| `railwayapp-templates/postgres-s3-backups` (GitHub) | **no license: all rights reserved** | Not read for code, nothing reused; the backup scripts here were written from scratch. |

No README or description text from other templates was reused.
