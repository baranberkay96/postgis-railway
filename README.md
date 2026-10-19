# Deploy and Host PostGIS with Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/postgis-36-spatial-database-on-postgres-?referralCode=20H68q)

PostGIS adds geometry and geography types, spatial indexes and hundreds of spatial functions to PostgreSQL. This template deploys PostgreSQL 18 with PostGIS 3.6 on Railway's own SSL-enabled Postgres image, with the same connection variables as Railway Postgres, automatic tuning, daily backups to a Railway Bucket and an optional public TCP proxy.

## About Hosting PostGIS

PostGIS runs inside Postgres, so hosting it means a well-run Postgres server with the PostGIS packages installed and the extensions enabled. This community template builds on `ghcr.io/railwayapp-templates/postgres-ssl:18`, the image behind Railway's Postgres template, and adds PostGIS 3.6 from the PostgreSQL apt repository, the same packages the official `postgis/postgis` image uses. First boot enables PostGIS, topology, fuzzy string matching and query statistics and creates `template_postgis`. Every boot sizes memory and parallel-query settings from the service's limits. A nightly cron job writes compressed `pg_dump` backups of every database to a Railway Bucket and prunes old ones only after a successful run.

## Common Use Cases

- Store places, routes and service areas, and answer "what is near me" or "what is inside this zone" queries with spatial indexes
- Geofencing: check whether vehicles, devices or users entered or left a polygon
- Backend database for GeoDjango, Rails, Laravel, Prisma or Supabase-style apps that need geometry columns
- Serve map data to QGIS, GeoServer or a vector tile server such as Martin or pg_tileserv
- Load and analyse shapefiles, GeoJSON or OpenStreetMap extracts with SQL

## Dependencies for PostGIS Hosting

- PostgreSQL 18 with PostGIS 3.6 (included, one service with a volume)
- A Railway Bucket for backups (included)
- No API keys or other inputs are required

### Deployment Dependencies

- PostGIS documentation: https://postgis.net/documentation/
- PostGIS 3.6 manual: https://postgis.net/docs/manual-3.6/
- Official PostGIS Docker images (reference for packages and init steps): https://github.com/postgis/docker-postgis
- Railway SSL Postgres image: https://github.com/railwayapp-templates/postgres-ssl
- PostgreSQL 18 documentation: https://www.postgresql.org/docs/18/
- Railway Buckets: https://docs.railway.com/storage-buckets

### Implementation Details

| Service | Source | Purpose |
|---|---|---|
| PostGIS | Dockerfile: Railway `postgres-ssl:18` + `postgresql-18-postgis-3` 3.6.x | PostgreSQL 18.6 with PostGIS 3.6.4, volume `/var/lib/postgresql/data`, port 5432 on the private network and through a TCP proxy |
| PostGIS Backup | Dockerfile: Alpine 3.24 with `pg_dump` 18 and rclone | Cron `15 3 * * *` (UTC): dumps every database to the Bucket, keeps 14 days |
| Bucket | Railway Bucket | Backup storage (`postgis/{timestamp}/{database}.dump`) |

**Connect an app**: add a variable such as `DATABASE_URL=${{PostGIS.DATABASE_URL}}` to your service. `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` and `PGDATABASE` are set the same way as on Railway Postgres. Spatial queries work right away, for example `SELECT ST_Distance('SRID=4326;POINT(28.97 41.01)'::geography, 'SRID=4326;POINT(-0.12 51.50)'::geography);`.

**Connect from outside Railway** (QGIS, psql, DBeaver): use `DATABASE_PUBLIC_URL`. The server offers TLS with a self-signed certificate; libpq-based clients use it by default, and `?sslmode=require` makes it mandatory. Set `PG_REQUIRE_TLS=true` to refuse unencrypted logins entirely (private-network apps must then use TLS too). If you do not need outside access, delete the TCP proxy under PostGIS → Settings → Networking.

**Extensions**: `postgis`, `postgis_topology`, `fuzzystrmatch` and `pg_stat_statements` are created in the `railway` database. `postgis_raster`, `postgis_sfcgal`, `address_standardizer` and PostgreSQL's contrib extensions are installed and can be enabled with `CREATE EXTENSION`. New databases created with `CREATE DATABASE mydb TEMPLATE template_postgis` start with PostGIS enabled. The legacy US TIGER geocoder is only created when `POSTGIS_TIGER_GEOCODER=true` on first boot, because PostGIS 3.7 drops it.

**Tuning**: at every boot the service writes `shared_buffers`, `work_mem`, `effective_cache_size`, parallel workers and SSD settings from its memory and CPU limits, and turns JIT off (PostGIS functions declare planner costs of up to 5000 per call, so ordinary spatial queries often exceed the JIT threshold and spend time compiling). Override single values with `ALTER SYSTEM`, or set `PG_TUNE_MEMORY_MB` / `PG_TUNE_CPUS`. Auto-detection is capped at 16 GB and 8 CPUs.

**Backups and restore**: each night the backup job writes `{database}.dump` files (pg_dump custom format, zstd), `globals.sql` (roles without passwords) and `MANIFEST.txt` to the Bucket. Old backups are only deleted after a run in which every dump succeeded. Set `BACKUP_PING_URL` to get alerted when backups stop. To restore, download a dump from the Bucket's Files tab, create an empty database and run `pg_restore --no-owner -d "postgresql://postgres:{password}@{tcp-proxy-host}:{port}/{new-database}" railway.dump` with pg_restore 18 or newer. Or set the PostGIS Backup start command to `postgis-restore` and trigger a run (`railway cron run --service "PostGIS Backup"`); it restores into a new database (`railway_restored` by default) and never overwrites an existing one. Railway's volume backups (PostGIS → Backups) can be used in addition.

**Scaling**: Postgres scales vertically; raise the service's resource limits and redeploy so the tuning follows. Read replicas are not part of this template.

**Pinning and upgrades**: the PostGIS packages are pinned to 3.6.x in `services/postgis/Dockerfile`. Patch releases (3.6.x) arrive when the image is rebuilt and are applied to existing databases automatically after boot (`POSTGIS_AUTO_UPDATE`). For PostGIS 3.7, change `POSTGIS_PKG_VERSION` to `3.7.*`, redeploy and run `SELECT postgis_extensions_upgrade();` in each database. A PostgreSQL major upgrade (18 to 19) needs a dump and restore into a new service.

### Why Deploy PostGIS on Railway?

Railway runs the database, its backup job and the bucket in one project with private networking, persistent volumes and usage-based billing. Your apps on Railway reach PostGIS over the private network with one variable reference, and you pay for the memory and CPU the database actually uses.
