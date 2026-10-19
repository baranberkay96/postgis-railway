# PostGIS 3.6 on Railway's SSL-enabled PostgreSQL 18 image.
#
# Base: ghcr.io/railwayapp-templates/postgres-ssl:18, the image behind Railway's
# own Postgres template (self-signed TLS certificates with renewal, tini as
# PID 1, volume locks against overlapping deploys, pg_stat_statements,
# opt-in pgBackRest). It is Debian trixie with PGDG's PostgreSQL 18 packages,
# the same base and apt repository the official postgis/postgis:18-3.6 image
# installs PostGIS from.
FROM ghcr.io/railwayapp-templates/postgres-ssl:18

# PostGIS is pinned at the minor release (3.6.x); patch releases arrive when
# the image is rebuilt. Moving to 3.7 is a deliberate edit of this line, see
# "Upgrades" in TEMPLATE.md.
ARG POSTGIS_MAJOR=3
ARG POSTGIS_PKG_VERSION=3.6.*

# The server packages are held so installing PostGIS can never move the
# bundled PostgreSQL minor (same approach as the base image's pgvector step).
RUN set -eux; \
    apt-mark hold "postgresql-${PG_MAJOR}" "postgresql-client-${PG_MAJOR}"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "postgresql-${PG_MAJOR}-postgis-${POSTGIS_MAJOR}=${POSTGIS_PKG_VERSION}" \
        "postgresql-${PG_MAJOR}-postgis-${POSTGIS_MAJOR}-scripts=${POSTGIS_PKG_VERSION}"; \
    apt-mark unhold "postgresql-${PG_MAJOR}" "postgresql-client-${PG_MAJOR}"; \
    rm -rf /var/lib/apt/lists/*; \
    for ext in postgis postgis_topology postgis_tiger_geocoder fuzzystrmatch pg_stat_statements; do \
        test -f "/usr/share/postgresql/${PG_MAJOR}/extension/${ext}.control"; \
    done; \
    mkdir -p /usr/local/share/railway-postgis; \
    dpkg-query -W -f='${Version}\n' "postgresql-${PG_MAJOR}-postgis-${POSTGIS_MAJOR}" \
        > /usr/local/share/railway-postgis/postgis-version; \
    cat /usr/local/share/railway-postgis/postgis-version

COPY --chmod=0644 railway-postgis/common.sh railway-postgis/postgis-update.sql /usr/local/lib/railway-postgis/
COPY --chmod=0755 railway-postgis/entrypoint.sh /usr/local/bin/railway-postgis-entrypoint.sh
# Runs once, on the first boot of an empty volume, before the base image's
# init-ssl.sh and pgBackRest init scripts.
COPY --chmod=0755 railway-postgis/initdb-postgis.sh /docker-entrypoint-initdb.d/20-postgis.sh

LABEL org.opencontainers.image.title="PostGIS 3.6 on Railway postgres-ssl 18" \
      org.opencontainers.image.description="PostgreSQL 18 with PostGIS 3.6 (PGDG packages), TLS, boot-time tuning from container limits"

# Same process model as the base image: tini delivers the stop signal to the
# wrapper's process group; the entrypoint execs Railway's wrapper.sh.
STOPSIGNAL SIGINT
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/railway-postgis-entrypoint.sh"]
CMD ["postgres", "-p", "5432", "-c", "listen_addresses=*"]
