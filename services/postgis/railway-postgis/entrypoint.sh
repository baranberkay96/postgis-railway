#!/bin/sh
# Entrypoint of the PostGIS image (after tini). On every boot it
#   - rewrites conf.d/50-railway-postgis-tuning.conf from the container's
#     memory and CPU limits (existing data directories; on a fresh volume the
#     first-boot init script writes it),
#   - applies PG_REQUIRE_TLS to pg_hba.conf,
#   - starts a background job that finishes the PostGIS setup on volumes that
#     lack it and applies PostGIS patch updates,
# then execs Railway's postgres-ssl wrapper unchanged (certificates, volume
# locks, pg_stat_statements, optional pgBackRest, docker-entrypoint.sh).
# None of these steps can keep Postgres from starting.
set -u

# shellcheck source=common.sh
. "${RAILWAY_POSTGIS_LIB_DIR:-/usr/local/lib/railway-postgis}/common.sh"

PGDATA=${PGDATA:-/var/lib/postgresql/data/pgdata}
# Same normalisation as the wrapper, so both agree on every path.
while [ "${PGDATA%/}" != "$PGDATA" ] && [ -n "${PGDATA%/}" ]; do PGDATA=${PGDATA%/}; done
export PGDATA

rp_log "PostGIS $(cat /usr/local/share/railway-postgis/postgis-version 2>/dev/null || echo unknown), $(postgres --version 2>/dev/null || echo 'postgres version unknown')"

if [ -s "$PGDATA/PG_VERSION" ]; then
  rp_write_tuning || rp_warn "could not write the tuning file; Postgres keeps its previous settings"
  rp_apply_tls_policy || rp_warn "could not apply PG_REQUIRE_TLS to pg_hba.conf"
else
  rp_log "empty data directory: first boot, the init script sets up PostGIS"
fi
rp_fork_post_start

exec /usr/local/bin/wrapper.sh "$@"
