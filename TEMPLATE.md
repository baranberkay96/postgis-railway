# PostGIS 3.6 Spatial Database on Postgres 18: Railway template spec

## Listing

| Field | Value |
|---|---|
| Name | **PostGIS 3.6 Spatial Database on Postgres 18** (as given in round4_listings) |
| Description | Drop-in Postgres with PostGIS for maps, geofencing and spatial queries. (71 chars) |
| Category | Storage |
| Tags | postgis, postgres, postgresql, gis, geospatial, spatial, database, maps |
| Icon | `https://postgis.net/brand.svg` (200, image/svg+xml; the PostGIS logo, no dashboard-icons entry exists) |

**Version check (2026-10-20).** Current PostGIS release is **3.6.4** (git tag 3.6.4; pgdg package `3.6.4+dfsg-2.pgdg13+1`; Docker Hub `postgis/postgis:18-3.6` pushed 2026-10-19). 3.7.0 is at rc2, not released. PostgreSQL 18 is at 18.6. The name is correct as given. Note on the naming rule: it asks for the major version for releases ≥ 1.0, which would be "PostGIS 3". The name keeps "3.6" because PostGIS feature releases are minor numbers (3.5, 3.6, 3.7 each change functions and drop features, e.g. 3.7 removes the TIGER geocoder), upstream tags its images by minor (`18-3.6`), and this template pins the minor. Rename to "3.7" when the pin moves.

The description is deliverable: the service exposes the same variables as Railway Postgres (`DATABASE_URL`, `DATABASE_PUBLIC_URL`, `PG*`), PostGIS is enabled in the default database, and spatial indexes and functions (ST_DWithin, ST_Contains, geography distance) cover geofencing and spatial queries.

## Base market template

- **`postgis`** (leader, 721 active projects, 1469 total): image `postgis/postgis:16-master` (a floating development build of PostGIS master on Postgres 16), TCP proxy on 5432, `DATABASE_URL` pointing at the public proxy, `DATABASE_PRIVATE_URL` for private use, SSL through `POSTGRES_INITDB_ARGS` with Debian's snakeoil certificate. Kept: one database service, volume at `/var/lib/postgresql/data` with `PGDATA` in a subfolder, TCP proxy, generated password. Fixed: unpinned `-master` dev build, old Postgres major, TLS with Debian's snakeoil pair (created by the `ssl-cert` package when the image is built, so by packaging logic every container of that tag shares one private key; not inspected in the image), no Railway wrapper (no volume lock, no per-volume certificate, no renewal), `DATABASE_URL` sending private traffic over the public proxy (egress charges, extra latency), no `PGUSER`/`PGPASSWORD`/`PGDATABASE`, no tuning, no backups, no healthy shutdown draining.
- **`postgis-17`** "PG 17 + PostGIS 3.5" (42 active): `postgis/postgis:17-master` (also a master build, so the "3.5" in its name is not what runs), same layout as the leader. Nothing taken.
- **`timescaledb-postgis`** (61 active): Railway's `timescale-postgis-ssl:pg16-ts2.13` (PG 16, PostGIS 3.4.1, last updated 2023), PostGIS installed but not enabled. Nothing taken; it confirmed that Railway's SSL image family is the right base.

## Pinned versions

| Service | Source | Version | Checked |
|---|---|---|---|
| PostGIS | Dockerfile `services/postgis`: `FROM ghcr.io/railwayapp-templates/postgres-ssl:18` (resolved to 18.6, digest `sha256:fcc6686a3f4f1962fe4ed77a15884553b7bd611ae1cea3204687968c5c09d517`, created 2026-10-09) + `postgresql-18-postgis-3=3.6.*` and `-scripts=3.6.*` from apt.postgresql.org (3.6.4+dfsg-2.pgdg13+1 today) | PostgreSQL 18.6, PostGIS 3.6.4 | 2026-10-20 |
| PostGIS Backup | Dockerfile `services/backup`: `FROM alpine:3.24.2` (digest `sha256:294b683c…`, 2026-09-17) + `postgresql18-client~18` (18.6-r0), `rclone` (1.74.1-r3), `bash`, `curl` | pg_dump 18.6 | 2026-10-20 |

Why `postgres-ssl:18` and not `:18.6`: it is the tag Railway's own Postgres template uses; Railway rebuilds it with security fixes, PostgreSQL minors are binary-compatible, and Railway documents that its PITR tooling expects a major tag. PostGIS stays on 3.6.x through the apt pin, and the Dockerfile holds the `postgresql-18` packages while installing PostGIS so the bundled server minor never moves as a side effect. An exact digest pin is possible (`FROM ghcr.io/railwayapp-templates/postgres-ssl:18@sha256:fcc6686a…`) if reproducible builds matter more than patch updates.

## Architecture

```
 apps in the project ── private network (postgis.railway.internal:5432, TLS offered) ──┐
 QGIS / psql / apps outside ── TCP proxy {host}:{port} (TLS offered, PG_REQUIRE_TLS) ──┤
                                                                                         ▼
                         PostGIS (postgres-ssl:18 + PostGIS 3.6)    volume /var/lib/postgresql/data
                         tini → railway-postgis-entrypoint.sh → Railway wrapper.sh → postgres
                           boot: conf.d tuning from cgroup limits, pg_hba TLS policy
                           first boot: template_postgis + extensions (initdb-postgis.sh)
                           after start: setup self-heal, PostGIS 3.6.x patch update
                                                                                         ▲
 PostGIS Backup (cron 15 3 * * * UTC) ── pg_dump / pg_dumpall over the private network ──┘
        │  rclone rcat (streamed, multipart)
        ▼
 Bucket (Railway Bucket, S3, virtual-hosted)  postgis/{YYYYMMDDTHHMMSSZ}/{db}.dump, globals.sql, MANIFEST.txt; postgis/LATEST
```

## Services

### PostGIS

| Setting | Value |
|---|---|
| Source | repo `baranberkay96/postgis-railway`, root `/services/postgis` (Dockerfile) |
| Start | image ENTRYPOINT/CMD: `tini -g -- railway-postgis-entrypoint.sh postgres -p 5432 -c listen_addresses=*` (dual-stack) |
| Healthcheck | none (TCP service; Railway's Postgres template has none either) |
| Public networking | TCP proxy → 5432 (optional, see below); no HTTP domain |
| Volume | `/var/lib/postgresql/data` (`PGDATA=/var/lib/postgresql/data/pgdata`, the path Railway's wrapper enforces) |
| Restart | ALWAYS |
| Draining | `RAILWAY_DEPLOYMENT_DRAINING_SECONDS=60` |

Files in `services/postgis/`:

- `Dockerfile`: installs `postgresql-18-postgis-3` and `-scripts` pinned to `3.6.*` with the server packages held, checks that the `postgis`, `postgis_topology`, `postgis_tiger_geocoder`, `fuzzystrmatch` and `pg_stat_statements` control files exist, records the PostGIS package version, copies the scripts and keeps the base image's process model (`tini -g`, `STOPSIGNAL SIGINT`, same CMD).
- `railway-postgis/entrypoint.sh` (every boot, root): on an existing data directory rewrites the tuning file and applies `PG_REQUIRE_TLS`, starts the background job, then `exec`s Railway's `wrapper.sh` unchanged. Every step only warns on failure.
- `railway-postgis/initdb-postgis.sh` (first boot of an empty volume, as `postgres`, from `/docker-entrypoint-initdb.d/20-postgis.sh`, before the base image's `99-pgbackrest-init.sh` and `init-ssl.sh`): tuning file, TLS policy, database setup. A failure is logged and does not abort the init.
- `railway-postgis/common.sh`: shared functions.
  - **Tuning** (`$PGDATA/conf.d/50-railway-postgis-tuning.conf`, `include_dir = 'conf.d'` appended to `postgresql.conf` in the form Railway's wrapper also recognises): memory from cgroup v2 `memory.max` (v1 fallback, then `/proc/meminfo`), the lower of cgroup and host, capped at 16384 MiB unless `PG_TUNE_MEMORY_MB` is set; CPUs from `cpu.max`, capped at 8 unless `PG_TUNE_CPUS` is set (Rule 8.15). Settings: `shared_buffers` 25 %, `effective_cache_size` 75 %, `maintenance_work_mem` RAM/16 (64 MB–1 GB), `work_mem` RAM/256 (4–64 MB), `min_dynamic_shared_memory` RAM/32 (32–512 MB, so parallel queries do not depend on a small `/dev/shm`), `max_parallel_workers_per_gather` CPUs/2 (0–4), `max_parallel_workers` CPUs (1–8), `max_parallel_maintenance_workers` CPUs/2 (1–4), `max_worker_processes` max(8, workers + 4), `random_page_cost` 1.1, `effective_io_concurrency`/`maintenance_io_concurrency` 200, `jit = off`, `track_io_timing = on`. `ALTER SYSTEM` (postgresql.auto.conf) still wins. Examples: 1 GB/1 vCPU → 256 MB shared_buffers, 4 MB work_mem, no parallel gather; 8 GB/8 vCPU → 2 GB, 32 MB, 4 workers per gather.
  - **TLS policy**: `PG_REQUIRE_TLS=true` turns the image's catch-all `host all all all scram-sha-256` rule into `hostssl … # railway-postgis: PG_REQUIRE_TLS`; `false` reverts exactly that line. Other rules are not touched.
  - **Database setup** (once per volume, marker `$PGDATA/railway-postgis.setup-done`): `template_postgis` (IS_TEMPLATE) and, in it and in `POSTGRES_DB`, `postgis`, `postgis_topology`, `fuzzystrmatch` (+ `postgis_tiger_geocoder` with `POSTGIS_TIGER_GEOCODER=true`); `pg_stat_statements` in `POSTGRES_DB`. All statements use `IF NOT EXISTS`.
  - **Background job** (forked before the wrapper; ignores the stop signal like the base image's helpers): waits until the real server accepts TCP on 127.0.0.1 (the socket-only init server never does, so first-boot init is not disturbed), skips standbys, runs the database setup if the marker is missing (volumes from other images, interrupted init), then runs `postgis-update.sql` in every database.
- `railway-postgis/postgis-update.sql`: if the installed PostGIS differs from the packaged version **within the same minor**, runs `postgis_extensions_upgrade()` (with `lock_timeout=10s`); different minors are only reported in the log.

Inherited from the base image (unchanged): self-signed CA + server certificate with `DNS:localhost` and the private domain as SAN, renewed 30 days before expiry; exclusive volume lock against overlapping deploys; refusal to start on a data directory of another major; `pg_hba` repair; `pg_stat_statements` preloaded; `max_connections = 500` in `postgresql.auto.conf`; dormant pgBackRest (see Advanced); `LOG_TO_STDOUT` switch.

### PostGIS Backup (cron)

| Setting | Value |
|---|---|
| Source | repo `baranberkay96/postgis-railway`, root `/services/backup` (Dockerfile) |
| Start | image CMD `postgis-backup` |
| Cron | `15 3 * * *` (UTC; Railway runs may start a few minutes late) |
| Restart | NEVER (the job waits up to `BACKUP_DB_WAIT_SECONDS`=300 for Postgres itself) |
| Volume / networking | none / private network only |

`bin/postgis-backup`: lists every database that accepts connections and is not a template (or `BACKUP_DATABASES`), streams `pg_dump --format=custom --compress=zstd:6` of each into the bucket with `rclone rcat` (16 MiB multipart chunks, ≈156 GiB per dump; no temporary disk use), stores roles with `pg_dumpall --globals-only --no-role-passwords`, and on full success writes `MANIFEST.txt` (server and client versions, sizes, PostGIS version per database) and `LATEST`. Failed or partial uploads are deleted and the run exits non-zero (shown as a failed cron run). Retention (`BACKUP_RETENTION_DAYS`=14, `rclone delete --min-age`, only `{YYYYMMDDTHHMMSSZ}/` folders under the prefix) runs only after a fully successful run, so a broken job never deletes the last good backups. `BACKUP_PING_URL` is requested after a successful run (dead-man's switch, e.g. healthchecks.io).

`bin/postgis-restore`: restore into a **new** database. Set the service's start command to `postgis-restore` and the variables `RESTORE_FROM` (`latest` or a folder name), `RESTORE_DATABASE` (default `PGDATABASE`), `RESTORE_TARGET` (default `{database}_restored`, letters/digits/_ only), `RESTORE_OPTIONS` (default `--no-owner`); deploy, trigger a run from the Cron Runs tab or `railway cron run --service "PostGIS Backup"`, then clear the start command. It refuses if the target database exists, creates it from `template0` and streams the dump into `pg_restore`.

### Bucket

Railway Bucket named `Bucket`; the backup service references `${{Bucket.ENDPOINT}}`, `BUCKET`, `REGION`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`. Buckets are public-network only, so uploads count as service egress ($0.05/GB). Railway Buckets have no lifecycle rules, which is why retention is done by the job.

## Variables

PostGIS: `POSTGRES_USER=postgres`, `POSTGRES_PASSWORD=${{ secret(32, "a–zA–Z") }}`, `POSTGRES_DB=railway`, `PGDATA`, `PGHOST=${{RAILWAY_PRIVATE_DOMAIN}}`, `PGPORT=5432`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `DATABASE_URL` (private), `DATABASE_PUBLIC_URL` (TCP proxy), `SSL_CERT_DAYS=820`, `RAILWAY_DEPLOYMENT_DRAINING_SECONDS=60`, `PG_TUNE=true`, `PG_TUNE_MEMORY_MB`, `PG_TUNE_CPUS`, `PG_REQUIRE_TLS=false`, `POSTGIS_AUTO_UPDATE=true`, `POSTGIS_TIGER_GEOCODER=false`. The `DATABASE_URL`, `DATABASE_PUBLIC_URL` and `PG*` definitions match `_railway-base/postgres.json` and Railway's Postgres template, so apps switch by changing `Postgres.` to `PostGIS.` in their references.

PostGIS Backup: `PG*` referencing the PostGIS service, `BACKUP_S3_*` referencing the Bucket, `BACKUP_S3_FORCE_PATH_STYLE=false`, `BACKUP_PREFIX=postgis`, `BACKUP_RETENTION_DAYS=14`, `BACKUP_DATABASES`, `BACKUP_COMPRESSION=zstd:6`, `BACKUP_PING_URL`. Every variable has a description in `template.json`.

## Required input

None. Every credential is generated (`POSTGRES_PASSWORD`) or referenced (Bucket keys).

## Security

- Postgres requires a password (scram-sha-256) for every network login; the password is 32 random letters from `secret()`. Local socket trust exists only inside the container (base image default).
- TLS is on for every connection that asks for it (base image certificates). `PG_REQUIRE_TLS=true` makes it mandatory for all non-local logins.
- The TCP proxy is the only public entry point; there is no HTTP UI. Remove the proxy for a private-only database.
- Backups contain all data (roles without password hashes). The bucket is private and encrypted at rest; anyone with the Bucket credentials can read it.

## First connection

1. Wait for the PostGIS deploy log line `railway-postgis: PostGIS setup done: POSTGIS="3.6.4 …"`.
2. From another service: set `DATABASE_URL=${{PostGIS.DATABASE_URL}}`.
3. From outside: `psql "$DATABASE_PUBLIC_URL?sslmode=require"` (copy the URL from the Variables tab), then `SELECT postgis_full_version();` and `SELECT ST_AsText(ST_Buffer('POINT(0 0)'::geometry, 1, 2));`.
4. QGIS: Layer → Add PostGIS layer → host/port from the TCP proxy, database `railway`, user `postgres`, SSL mode `require`.

## Improvements over market templates

1. **Pinned, released PostGIS 3.6.x on PostgreSQL 18** instead of `-master` development builds on Postgres 16/17; minor pinned in the Dockerfile, patch updates applied safely after boot.
2. **Railway's own Postgres image as the base**: TLS with SAN and automatic renewal, volume lock against overlapping deploys, wrong-major refusal, pg_hba repair, `pg_stat_statements`, clean shutdown via tini, all maintained by Railway.
3. **Drop-in variables** identical to Railway Postgres (`DATABASE_URL` private, `DATABASE_PUBLIC_URL` via proxy, `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`), so private traffic no longer goes through the public proxy.
4. **Extensions ready on first boot** (postgis, postgis_topology, fuzzystrmatch, pg_stat_statements) plus `template_postgis`, with a self-healing setup for volumes initialised elsewhere. The deprecated TIGER geocoder is opt-in.
5. **Tuning from the container's limits** at every boot (memory, CPU quota, small `/dev/shm`), JIT off for PostGIS workloads, `ALTER SYSTEM` still respected.
6. **Automated daily backups** to a Railway Bucket with retention that never deletes the last good backup, a manifest, an optional heartbeat URL and an in-Railway restore command that only ever creates a new database.
7. **Optional TLS enforcement** for all remote logins (`PG_REQUIRE_TLS`).

## Resource estimate

Railway prices: RAM $10/GB-month, vCPU $20/vCPU-month, volume $0.15/GB-month, bucket $0.015/GB-month, service egress $0.05/GB.

| Service | Idle RAM / CPU | Typical RAM / CPU | Notes |
|---|---|---|---|
| PostGIS | 0.1 GB / 0.01 | 0.75 GB / 0.2 | Not measured (no Docker this round). Basis: idle Railway Postgres measured at ~71 MB in the mem0 package; PostGIS adds GEOS/PROJ/GDAL libraries per backend that uses them. `shared_buffers` is only resident as data is read, so the tuned size does not raise idle RAM. |
| PostGIS Backup | 0 (runs ~1–5 min/day) | 0.1–0.2 GB while running | rclone multipart buffers (4 × 16 MiB) + pg_dump |
| Volume | 0.2 GB | 5 GB | empty PG18 cluster with PostGIS ≈ 100–200 MB |
| Bucket | ~0 | ~14 × dump size (e.g. 14 GB for 1 GB dumps) | |
| Egress | 0 | dump size × 30 per month | uploads to the bucket |

Estimated monthly cost: **idle ≈ $1.2** (0.1 GB × $10 + 0.01 × $20 + 0.2 GB × $0.15), **typical ≈ $14** (0.75 GB × $10 + 0.2 × $20 + 5 GB × $0.15 + 14 GB × $0.015 + 30 GB × $0.05).

Minimum plan: **Hobby** recommended (5 GB volume, always-on). The Trial plan fits the RAM (the tuning adapts to 0.5–1 GB) and includes bucket storage; the Limited Trial has no buckets, so the backup service would fail there.

## Upgrades

- **PostGIS patch (3.6.x)**: rebuild the PostGIS service (redeploy from source); the background job applies `postgis_extensions_upgrade()` per database. Disable with `POSTGIS_AUTO_UPDATE=false`.
- **PostGIS minor (3.7)**: back up; if `postgis_tiger_geocoder` was enabled, `DROP EXTENSION postgis_tiger_geocoder;` first; change `POSTGIS_PKG_VERSION` to `3.7.*` in `services/postgis/Dockerfile`, redeploy, then run `SELECT postgis_extensions_upgrade();` in every database (including `template_postgis`). Rename the listing to 3.7.
- **PostgreSQL major (19)**: not in place. Create a new service from an updated image and restore the latest dump into it (`pg_restore` 19), or use `pg_dump | pg_restore` directly; the wrapper refuses to start an 18 data directory with a 19 binary.
- **Base image**: `postgres-ssl:18` minors arrive on rebuild.

## Advanced (not tested)

The base image's pgBackRest integration (continuous WAL archiving and point-in-time recovery) is dormant and can be switched on by setting `WAL_ARCHIVE_BUCKET`, `WAL_ARCHIVE_ENDPOINT`, `WAL_ARCHIVE_REGION`, `WAL_ARCHIVE_KEY`, `WAL_ARCHIVE_SECRET` on the PostGIS service, pointing at a **separate** bucket (Railway: one archive bucket per service). Railway's dashboard PITR flow may not recognise a service built from this Dockerfile; this path was not tested.

## Verification checklist

Static checks done (2026-10-20, no Docker): `sh -n`, `dash -n`, `bash -n` on all scripts; template.json parsed and converted with `_tools/to_serialized.py` (2 services, TCP proxy 5432, volume, cron, bucket); registry API: `postgres-ssl:18` (= 18.6), `alpine:3.24.2`, `postgis/postgis:18-3.6` exist; pgdg Packages/Contents confirm `postgresql-18-postgis-3` 3.6.4 and its extension files; Alpine APKINDEX confirms `postgresql18-client` 18.6 and `rclone` 1.74.1. Local functional tests without Docker (PostgreSQL 15.18 from Homebrew, scratch cluster): tuning renderer for 9 limit scenarios; generated tuning file loaded by Postgres from `conf.d` (all settings accepted, source = the include file; `effective_io_concurrency` checked by range only, macOS requires 0), `ALTER SYSTEM` overrides it; `include_dir` added once; `PG_REQUIRE_TLS` on/off round-trip restores `pg_hba.conf` byte for byte and Postgres parses the marked `hostssl` line; database setup flow (template DB via `\gexec`, missing database skipped, marker, idempotent re-run, failure returns non-zero) with contrib stand-ins for PostGIS; background job against a live server; `postgis-update.sql` parses and is a no-op without PostGIS; backup job with an rclone stub (all databases incl. a name with space and `=`, manifest, LATEST, retention deletes a 20-day-old folder and keeps unrelated objects, failed dump / failed upload → partial object removed, no MANIFEST, no retention, exit 1); restore job (latest and explicit folder, refuses existing target and bad names).

On the first Railway deploy:

- [ ] Both Dockerfiles build on Railway (apt pin `3.6.*` resolves; the control-file check passes; `apk add` resolves `postgresql18-client~18`).
- [ ] PostGIS log: `railway-postgis: tuning for … MiB (cgroup memory.max)` with the service's real limit, `ensuring PostGIS extensions in database 'railway'`, `PostGIS setup done: POSTGIS="3.6.4 …"`, then `database system is ready to accept connections`.
- [ ] `psql "$DATABASE_PUBLIC_URL?sslmode=require"`: `SELECT postgis_full_version();`, `SHOW shared_buffers; SHOW jit;`, `SELECT * FROM pg_stat_statements LIMIT 1;`, `CREATE DATABASE t TEMPLATE template_postgis;`, `SELECT extname FROM pg_extension` in `t`.
- [ ] A second service with `DATABASE_URL=${{PostGIS.DATABASE_URL}}` connects over the private network.
- [ ] Redeploy PostGIS: data persists, log shows the tuning line again and no setup run (marker present), no `postgis updated` line.
- [ ] Trigger PostGIS Backup (`railway cron run --service "PostGIS Backup"`): exit 0, Bucket Files tab shows `postgis/{timestamp}/railway.dump`, `postgres.dump`, `globals.sql`, `MANIFEST.txt` and `postgis/LATEST`.
- [ ] Restore test: start command `postgis-restore`, run, check `railway_restored` has the PostGIS tables; clear the start command.
- [ ] `PG_REQUIRE_TLS=true` + redeploy: `psql "…?sslmode=disable"` is refused, `sslmode=require` works; Railway's Data tab still opens (record the result).
- [ ] Check `/dev/shm` size and memory reported in the tuning log line (feeds the cost estimate).

## Open questions

- **cgroup values on Railway** are not verified: if `memory.max` reports the plan ceiling (e.g. 24 GB on Pro) the tuning uses the 16 GB cap; if it reports `max`, the host's RAM is used, also capped. The log line shows what was detected.
- **Railway Data tab** for a repo-built service: the `PG*` variables it reads are set, but whether the tab appears for a non-image service was not checked.
- **`postgres-ssl:18` rebuilds**: a future base image could ship a newer PostgreSQL minor than the PostGIS package was built against; PostGIS packages depend on `postgresql-18` without a minor constraint, so this is expected to keep working, and the held packages make a conflict fail the build instead of the runtime.
- **First backup timing**: the cron job first runs at the next 03:15 UTC; trigger it manually after deploy to confirm the bucket wiring.
- **Restore via start command** depends on `railway cron run` / the Cron Runs tab for an off-schedule run (documented by Railway, not exercised here).
- pgRouting and h3 are not included: the upstream `postgis/postgis` image does not ship them. Both exist as pgdg packages (`postgresql-18-pgrouting` 4.0.1, `postgresql-18-h3` 4.2.3) and could be added with one apt line.
