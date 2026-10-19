# Daily logical backups of the PostGIS service to a Railway Bucket.
#
# Alpine 3.24 ships the PostgreSQL 18 client (pg_dump/pg_restore 18.6, built
# with zstd and lz4) and rclone 1.74 as distribution packages, so nothing is
# downloaded outside the Alpine repositories. pg_dump does not need PostGIS
# installed: it dumps the extension as CREATE EXTENSION plus the data.
FROM alpine:3.24.2

RUN set -eux; \
    apk add --no-cache bash ca-certificates curl rclone 'postgresql18-client~18'; \
    /usr/libexec/postgresql18/pg_dump --version; \
    rclone version | head -n 1; \
    mkdir -p /root/.config/rclone; \
    touch /root/.config/rclone/rclone.conf

# Alpine installs the client under /usr/libexec/postgresql18; put that first so
# the scripts never pick up another major.
ENV PATH=/usr/libexec/postgresql18:$PATH

COPY --chmod=0644 bin/lib.sh /usr/local/lib/postgis-backup/lib.sh
COPY --chmod=0755 bin/postgis-backup bin/postgis-restore /usr/local/bin/

# Railway runs this service on its cron schedule; the job exits when done.
# For a restore, set the service's start command to `postgis-restore`.
CMD ["postgis-backup"]
