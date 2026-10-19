# Shared helpers for postgis-backup and postgis-restore (bash).
#
# Connection (set by the template from the PostGIS service):
#   PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE   libpq variables
# Bucket (set by the template from the Railway Bucket):
#   BACKUP_S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_REGION
#   BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY
#   BACKUP_S3_FORCE_PATH_STYLE   false for current Railway Buckets
# Layout:
#   BACKUP_PREFIX                folder in the bucket (default "postgis")
#   <prefix>/<YYYYMMDDTHHMMSSZ>/<database>.dump   pg_dump custom format
#   <prefix>/<YYYYMMDDTHHMMSSZ>/globals.sql       roles (no passwords)
#   <prefix>/<YYYYMMDDTHHMMSSZ>/MANIFEST.txt      written last = complete
#   <prefix>/LATEST                               name of the newest complete backup

PREFIX="${BACKUP_PREFIX:-postgis}"
PREFIX="${PREFIX#/}"
PREFIX="${PREFIX%/}"
REMOTE=""
TS_PATTERN='^[0-9]{8}T[0-9]{6}Z$'

log() { printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LOG_TAG:-postgis-backup}" "$*"; }
die() {
  log "ERROR: $*" >&2
  exit 1
}

is_true() {
  case "${1:-}" in
    1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

require_uint() {
  local name="$1" value="$2" min="$3"
  [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge "$min" ] \
    || die "$name must be a whole number >= $min (got '$value')"
}

require_vars() {
  local var missing=()
  for var in "$@"; do
    [ -n "${!var:-}" ] || missing+=("$var")
  done
  [ "${#missing[@]}" -eq 0 ] || die "missing variables: ${missing[*]}"
}

# Object name for a database: database names may contain any character, keys
# only keep a safe subset (the real name is recorded in MANIFEST.txt).
object_name() {
  local safe
  safe=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s' "${safe:-_}"
}

configure_remote() {
  require_vars BACKUP_S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY
  [[ "$PREFIX" =~ ^[A-Za-z0-9._/-]+$ ]] || die "BACKUP_PREFIX may only contain letters, digits and . _ / -"
  # rclone remote "backup", configured through rclone's own environment
  # variables. Railway Buckets are S3-compatible with virtual-hosted URLs.
  export RCLONE_CONFIG_BACKUP_TYPE=s3
  export RCLONE_CONFIG_BACKUP_PROVIDER=Other
  export RCLONE_CONFIG_BACKUP_ENDPOINT="$BACKUP_S3_ENDPOINT"
  export RCLONE_CONFIG_BACKUP_REGION="${BACKUP_S3_REGION:-auto}"
  export RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY_ID"
  export RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_BACKUP_FORCE_PATH_STYLE="${BACKUP_S3_FORCE_PATH_STYLE:-false}"
  # The bucket exists already; its keys need not be allowed to create buckets.
  export RCLONE_CONFIG_BACKUP_NO_CHECK_BUCKET=true
  # Streams of unknown size are uploaded in parts of this size (max 10,000
  # parts, so about 156 GiB per dump).
  export RCLONE_CONFIG_BACKUP_CHUNK_SIZE=16Mi
  REMOTE="backup:${BACKUP_S3_BUCKET}/${PREFIX}"
}

configure_pg() {
  require_vars PGHOST PGUSER PGPASSWORD
  export PGPORT="${PGPORT:-5432}"
  export PGDATABASE="${PGDATABASE:-postgres}"
  export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
  export PGAPPNAME="${LOG_TAG:-postgis-backup}"
  # The private network is already encrypted; TLS is used when offered.
  export PGSSLMODE="${PGSSLMODE:-prefer}"
}

# Services start in parallel and Postgres may be restarting: wait for it.
wait_for_postgres() {
  local wait_seconds="${BACKUP_DB_WAIT_SECONDS:-300}" waited=0
  require_uint BACKUP_DB_WAIT_SECONDS "$wait_seconds" 0
  until psql -X -q -A -t -c 'SELECT 1' >/dev/null 2>&1; do
    if [ "$waited" -ge "$wait_seconds" ]; then
      psql -X -q -A -t -c 'SELECT 1' >/dev/null || true
      die "PostgreSQL at ${PGHOST}:${PGPORT} not reachable after ${wait_seconds}s"
    fi
    log "waiting for PostgreSQL at ${PGHOST}:${PGPORT}"
    sleep 10
    waited=$((waited + 10))
  done
}
