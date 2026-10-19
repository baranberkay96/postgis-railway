#!/bin/bash
# First boot only. docker-entrypoint.sh runs this (as the postgres user, while
# its socket-only init server is up) from /docker-entrypoint-initdb.d when the
# volume is empty. It
#   - writes the tuning file and TLS policy for the first real start,
#   - creates template_postgis, and PostGIS, postgis_topology and
#     fuzzystrmatch (plus postgis_tiger_geocoder when
#     POSTGIS_TIGER_GEOCODER=true) in POSTGRES_DB and template_postgis,
#   - creates pg_stat_statements in POSTGRES_DB (the base image preloads it).
# A failure here is logged but does not stop the database: without the setup
# marker, entrypoint.sh's background job repeats the setup once the server is
# up. Later boots are handled by entrypoint.sh.
set -Eeuo pipefail

# shellcheck source=common.sh
. "${RAILWAY_POSTGIS_LIB_DIR:-/usr/local/lib/railway-postgis}/common.sh"

# Always talk to the local init server over its Unix socket.
unset PGHOST PGHOSTADDR

init_sql() {
  local db="$1"
  shift
  PGDATABASE="$db" psql --username "$POSTGRES_USER" --no-password --no-psqlrc \
    --port "${PGPORT:-5432}" "$@"
}

rp_write_tuning || rp_warn "could not write the tuning file; the first start uses Postgres defaults"
rp_apply_tls_policy || rp_warn "could not apply PG_REQUIRE_TLS to pg_hba.conf"
rp_setup_databases init_sql || rp_warn "PostGIS setup failed during init; it is retried after the server starts"
