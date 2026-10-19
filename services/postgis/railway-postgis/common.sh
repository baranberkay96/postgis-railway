# railway-postgis helpers (POSIX sh). Sourced by
#   entrypoint.sh       as root, on every boot of an existing data directory
#   initdb-postgis.sh   as postgres, once, on the first boot of an empty volume
#
# Nothing here may stop the database from starting: callers treat every
# failure as a warning.
#
# Service variables read here:
#   PG_TUNE              true (default) | false
#   PG_TUNE_MEMORY_MB    memory budget in MiB for the tuning (default: the
#                        container's cgroup memory limit, capped at 16384)
#   PG_TUNE_CPUS         CPU count for parallel-query settings (default: the
#                        cgroup CPU quota, capped at 8)
#   PG_REQUIRE_TLS       false (default) | true: TLS for every non-local login
#   POSTGIS_AUTO_UPDATE  true (default) | false: apply PostGIS patch updates
#                        (same minor) to existing databases after boot
# Test hooks: RAILWAY_POSTGIS_LIB_DIR, RAILWAY_POSTGIS_CGROUP_ROOT, RAILWAY_POSTGIS_MEMINFO,
#             RAILWAY_POSTGIS_SHM_DIR, RAILWAY_POSTGIS_LOCAL_SOCKET, RAILWAY_POSTGIS_LOCAL_PORT

RP_LIB_DIR=${RAILWAY_POSTGIS_LIB_DIR:-/usr/local/lib/railway-postgis}
RP_TUNING_FILE_NAME=50-railway-postgis-tuning.conf
RP_AUTO_MEMORY_CAP_MB=16384
RP_AUTO_CPU_CAP=8
RP_HBA_MARK='# railway-postgis: PG_REQUIRE_TLS'
# Where the background job reaches the server (the image's CMD fixes -p 5432).
RP_LOCAL_SOCKET=${RAILWAY_POSTGIS_LOCAL_SOCKET:-/var/run/postgresql}
RP_LOCAL_PORT=${RAILWAY_POSTGIS_LOCAL_PORT:-5432}

rp_log() { printf 'railway-postgis: %s\n' "$*"; }
rp_warn() { printf 'railway-postgis: WARNING: %s\n' "$*" >&2; }

rp_is_true() {
  case "${1:-}" in
    1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

rp_is_uint() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# rp_clamp VALUE MIN MAX
rp_clamp() {
  _rp_c=$1
  if [ "$_rp_c" -lt "$2" ]; then _rp_c=$2; fi
  if [ "$_rp_c" -gt "$3" ]; then _rp_c=$3; fi
  echo "$_rp_c"
}

rp_is_root() { [ "$(id -u)" = 0 ]; }

# ---------------------------------------------------------------------------
# Container limits. Railway reports the service's limits in the cgroup;
# /proc/meminfo and nproc describe the whole host (Rule: never size from the
# host). Results: RP_MEM_MB / RP_MEM_SRC and RP_CPUS / RP_CPU_SRC.
# ---------------------------------------------------------------------------
rp_detect_memory() {
  RP_MEM_MB=""
  RP_MEM_SRC=""
  if [ -n "${PG_TUNE_MEMORY_MB:-}" ]; then
    if rp_is_uint "$PG_TUNE_MEMORY_MB" && [ "$PG_TUNE_MEMORY_MB" -ge 256 ]; then
      RP_MEM_MB=$PG_TUNE_MEMORY_MB
      RP_MEM_SRC="PG_TUNE_MEMORY_MB"
      return 0
    fi
    rp_warn "PG_TUNE_MEMORY_MB='${PG_TUNE_MEMORY_MB}' is not a whole number >= 256; detecting the limit instead"
  fi

  _rp_cg=${RAILWAY_POSTGIS_CGROUP_ROOT:-/sys/fs/cgroup}
  _rp_lim=""
  if [ -r "$_rp_cg/memory.max" ]; then
    _rp_raw=$(cat "$_rp_cg/memory.max" 2>/dev/null || true)
    if rp_is_uint "$_rp_raw"; then
      _rp_lim=$((_rp_raw / 1048576))
      RP_MEM_SRC="cgroup memory.max"
    fi
  elif [ -r "$_rp_cg/memory/memory.limit_in_bytes" ]; then
    _rp_raw=$(cat "$_rp_cg/memory/memory.limit_in_bytes" 2>/dev/null || true)
    # cgroup v1 reports "unlimited" as a value near 2^63.
    if rp_is_uint "$_rp_raw" && [ "${#_rp_raw}" -le 18 ]; then
      _rp_lim=$((_rp_raw / 1048576))
      RP_MEM_SRC="cgroup v1 memory.limit_in_bytes"
    fi
  fi

  _rp_host=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024; exit }' \
    "${RAILWAY_POSTGIS_MEMINFO:-/proc/meminfo}" 2>/dev/null || true)
  if ! rp_is_uint "$_rp_host" || [ "$_rp_host" -eq 0 ]; then _rp_host=""; fi

  if [ -z "$_rp_lim" ] || [ "$_rp_lim" -eq 0 ]; then
    if [ -n "$_rp_host" ]; then
      _rp_lim=$_rp_host
      RP_MEM_SRC="host MemTotal (no cgroup limit)"
    else
      _rp_lim=1024
      RP_MEM_SRC="fallback (limit unknown)"
    fi
  elif [ -n "$_rp_host" ] && [ "$_rp_host" -lt "$_rp_lim" ]; then
    _rp_lim=$_rp_host
    RP_MEM_SRC="host MemTotal (below the cgroup limit)"
  fi

  if [ "$_rp_lim" -gt "$RP_AUTO_MEMORY_CAP_MB" ]; then
    RP_MEM_SRC="${RP_MEM_SRC} ${_rp_lim} MiB, capped at ${RP_AUTO_MEMORY_CAP_MB}; set PG_TUNE_MEMORY_MB to use more"
    _rp_lim=$RP_AUTO_MEMORY_CAP_MB
  fi
  if [ "$_rp_lim" -lt 256 ]; then _rp_lim=256; fi
  RP_MEM_MB=$_rp_lim
}

rp_detect_cpus() {
  RP_CPUS=""
  RP_CPU_SRC=""
  if [ -n "${PG_TUNE_CPUS:-}" ]; then
    if rp_is_uint "$PG_TUNE_CPUS" && [ "$PG_TUNE_CPUS" -ge 1 ] && [ "$PG_TUNE_CPUS" -le 64 ]; then
      RP_CPUS=$PG_TUNE_CPUS
      RP_CPU_SRC="PG_TUNE_CPUS"
      return 0
    fi
    rp_warn "PG_TUNE_CPUS='${PG_TUNE_CPUS}' is not a whole number from 1 to 64; detecting the quota instead"
  fi

  _rp_cg=${RAILWAY_POSTGIS_CGROUP_ROOT:-/sys/fs/cgroup}
  _rp_n=""
  if [ -r "$_rp_cg/cpu.max" ]; then
    read -r _rp_quota _rp_period < "$_rp_cg/cpu.max" || true
    if rp_is_uint "${_rp_quota:-}" && rp_is_uint "${_rp_period:-}" && [ "$_rp_period" -gt 0 ]; then
      _rp_n=$(((_rp_quota + _rp_period - 1) / _rp_period))
      RP_CPU_SRC="cgroup cpu.max"
    fi
  elif [ -r "$_rp_cg/cpu/cpu.cfs_quota_us" ] && [ -r "$_rp_cg/cpu/cpu.cfs_period_us" ]; then
    _rp_quota=$(cat "$_rp_cg/cpu/cpu.cfs_quota_us" 2>/dev/null || true)
    _rp_period=$(cat "$_rp_cg/cpu/cpu.cfs_period_us" 2>/dev/null || true)
    if rp_is_uint "$_rp_quota" && rp_is_uint "$_rp_period" && [ "$_rp_period" -gt 0 ]; then
      _rp_n=$(((_rp_quota + _rp_period - 1) / _rp_period))
      RP_CPU_SRC="cgroup v1 cfs quota"
    fi
  fi
  if [ -z "$_rp_n" ] || [ "$_rp_n" -lt 1 ]; then
    _rp_n=$(nproc 2>/dev/null || echo 1)
    rp_is_uint "$_rp_n" || _rp_n=1
    RP_CPU_SRC="nproc (no cgroup quota)"
  fi
  if [ "$_rp_n" -gt "$RP_AUTO_CPU_CAP" ]; then
    RP_CPU_SRC="${RP_CPU_SRC} ${_rp_n}, capped at ${RP_AUTO_CPU_CAP}"
    _rp_n=$RP_AUTO_CPU_CAP
  fi
  RP_CPUS=$_rp_n
}

rp_detect_shm_mb() {
  RP_SHM_MB=$(df -Pk "${RAILWAY_POSTGIS_SHM_DIR:-/dev/shm}" 2>/dev/null \
    | awk 'NR == 2 { printf "%d", $2 / 1024 }' || true)
  rp_is_uint "$RP_SHM_MB" || RP_SHM_MB="unknown"
}

# ---------------------------------------------------------------------------
# Tuning file: $PGDATA/conf.d/50-railway-postgis-tuning.conf, rewritten on
# every boot from the limits above. postgresql.auto.conf (ALTER SYSTEM) is
# read after include files, so ALTER SYSTEM still overrides any value here.
# ---------------------------------------------------------------------------
rp_render_tuning() {
  rp_detect_memory
  rp_detect_cpus
  rp_detect_shm_mb

  _rp_sb=$((RP_MEM_MB / 4))
  if [ "$_rp_sb" -lt 128 ]; then _rp_sb=128; fi
  _rp_ecs=$((RP_MEM_MB * 3 / 4))
  _rp_mwm=$(rp_clamp $((RP_MEM_MB / 16)) 64 1024)
  _rp_wm=$(rp_clamp $((RP_MEM_MB / 256)) 4 64)
  # Parallel queries take shared memory from this region first, so they do
  # not depend on the container's /dev/shm (64 MB in many runtimes).
  _rp_dsm=$(rp_clamp $((RP_MEM_MB / 32)) 32 512)
  _rp_gather=$(rp_clamp $((RP_CPUS / 2)) 0 4)
  _rp_pw=$(rp_clamp "$RP_CPUS" 1 8)
  _rp_pmw=$(rp_clamp $((RP_CPUS / 2)) 1 4)
  _rp_mwp=$((_rp_pw + 4))
  if [ "$_rp_mwp" -lt 8 ]; then _rp_mwp=8; fi

  cat <<EOF
# Written by railway-postgis at container start and rewritten on every boot.
# Do not edit: use ALTER SYSTEM SET <name> = <value> (postgresql.auto.conf
# wins over this file), or set PG_TUNE_MEMORY_MB / PG_TUNE_CPUS on the
# service and redeploy. PG_TUNE=false removes this file.
#
# Memory budget: ${RP_MEM_MB} MiB (${RP_MEM_SRC})
# CPUs: ${RP_CPUS} (${RP_CPU_SRC})
# /dev/shm: ${RP_SHM_MB} MiB
shared_buffers = '${_rp_sb}MB'
effective_cache_size = '${_rp_ecs}MB'
maintenance_work_mem = '${_rp_mwm}MB'
work_mem = '${_rp_wm}MB'
min_dynamic_shared_memory = '${_rp_dsm}MB'
max_worker_processes = ${_rp_mwp}
max_parallel_workers = ${_rp_pw}
max_parallel_workers_per_gather = ${_rp_gather}
max_parallel_maintenance_workers = ${_rp_pmw}
# SSD-backed volumes
random_page_cost = 1.1
effective_io_concurrency = 200
maintenance_io_concurrency = 200
# PostGIS functions declare high planner costs (up to 5000 per call), so
# ordinary spatial queries often pass jit_above_cost and spend time compiling.
# Re-enable with ALTER SYSTEM SET jit = on for long analytical queries.
jit = off
# Timing data for pg_stat_statements and EXPLAIN (ANALYZE, BUFFERS)
track_io_timing = on
EOF
}

# Adds the include line Railway's wrapper also recognises, so neither side
# appends a duplicate.
rp_ensure_include_dir() {
  _rp_conf="$PGDATA/postgresql.conf"
  [ -f "$_rp_conf" ] || return 0
  if grep -qE "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*['\"]?conf\.d['\"]?[[:space:]]*$" "$_rp_conf"; then
    return 0
  fi
  printf "\n# Added by railway-postgis: boot-time tuning lives in conf.d/\ninclude_dir = 'conf.d'\n" >> "$_rp_conf" || return 1
  sync "$_rp_conf" 2>/dev/null || true
}

rp_write_tuning() {
  [ -n "${PGDATA:-}" ] && [ -s "$PGDATA/PG_VERSION" ] || return 0
  _rp_dir="$PGDATA/conf.d"
  _rp_file="$_rp_dir/$RP_TUNING_FILE_NAME"

  if ! rp_is_true "${PG_TUNE:-true}"; then
    if [ -f "$_rp_file" ]; then
      rm -f "$_rp_file" || return 1
      rp_log "PG_TUNE=false: removed conf.d/$RP_TUNING_FILE_NAME; Postgres uses postgresql.conf defaults"
    fi
    return 0
  fi

  mkdir -p "$_rp_dir" || return 1
  _rp_tmp="$_rp_file.tmp.$$"
  if ! rp_render_tuning > "$_rp_tmp"; then
    rm -f "$_rp_tmp"
    return 1
  fi
  chmod 0600 "$_rp_tmp" || true
  if rp_is_root; then
    chown postgres:postgres "$_rp_dir" "$_rp_tmp" || return 1
    chmod 0750 "$_rp_dir" || true
  fi
  mv -f "$_rp_tmp" "$_rp_file" || return 1
  sync "$_rp_file" 2>/dev/null || true
  rp_ensure_include_dir || return 1
  rp_log "tuning for ${RP_MEM_MB} MiB (${RP_MEM_SRC}) and ${RP_CPUS} CPU(s) (${RP_CPU_SRC}): $(grep -E '^(shared_buffers|effective_cache_size|work_mem|maintenance_work_mem|max_parallel_workers_per_gather) ' "$_rp_file" | sed 's/ = /=/' | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------
# PG_REQUIRE_TLS: switch the image's catch-all "host all all all <method>"
# rule to hostssl (and back). Only that rule, marked with RP_HBA_MARK, is
# touched; hand-written rules are left alone.
# ---------------------------------------------------------------------------
rp_apply_tls_policy() {
  [ -n "${PGDATA:-}" ] || return 0
  _rp_hba="$PGDATA/pg_hba.conf"
  [ -f "$_rp_hba" ] || return 0
  _rp_tmp=$(mktemp) || return 1

  if rp_is_true "${PG_REQUIRE_TLS:-false}"; then
    sed -E "s/^host([[:space:]]+all[[:space:]]+all[[:space:]]+all[[:space:]]+)([^[:space:]#]+)[[:space:]]*\$/hostssl\\1\\2 ${RP_HBA_MARK}/" \
      "$_rp_hba" > "$_rp_tmp" || { rm -f "$_rp_tmp"; return 1; }
  else
    sed -E "s/^hostssl([[:space:]]+all[[:space:]]+all[[:space:]]+all[[:space:]]+)([^[:space:]#]+)[[:space:]]+${RP_HBA_MARK}\$/host\\1\\2/" \
      "$_rp_hba" > "$_rp_tmp" || { rm -f "$_rp_tmp"; return 1; }
  fi

  if ! cmp -s "$_rp_tmp" "$_rp_hba"; then
    # Rewrite in place so owner and mode of pg_hba.conf stay as they are.
    cat "$_rp_tmp" > "$_rp_hba" || { rm -f "$_rp_tmp"; return 1; }
    sync "$_rp_hba" 2>/dev/null || true
    if rp_is_true "${PG_REQUIRE_TLS:-false}"; then
      rp_log "PG_REQUIRE_TLS=true: non-local logins now require TLS (pg_hba.conf: hostssl)"
    else
      rp_log "PG_REQUIRE_TLS=false: plain TCP logins allowed again (pg_hba.conf: host)"
    fi
  elif rp_is_true "${PG_REQUIRE_TLS:-false}" && ! grep -qF "$RP_HBA_MARK" "$_rp_hba"; then
    rp_warn "PG_REQUIRE_TLS=true but pg_hba.conf has no 'host all all all <method>' rule to switch; left unchanged"
  fi
  rm -f "$_rp_tmp"
}

# ---------------------------------------------------------------------------
# Database setup: template_postgis plus the default extensions. Runs once per
# volume (marker file in PGDATA): during first-boot init, or after the first
# start of a volume that was initialised elsewhere or whose init was cut short.
# Every statement is idempotent; databases the user dropped are not re-created
# on later boots because the marker is then present.
#
# rp_setup_databases RUNNER   (RUNNER DB [psql args...] runs psql against DB)
# ---------------------------------------------------------------------------
rp_setup_marker() { printf '%s/railway-postgis.setup-done' "$PGDATA"; }

rp_setup_databases() {
  _rp_run=$1
  _rp_main=${POSTGRES_DB:-${POSTGRES_USER:-postgres}}

  "$_rp_run" postgres -v ON_ERROR_STOP=1 <<'SQL' || return 1
SELECT 'CREATE DATABASE template_postgis IS_TEMPLATE true'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'template_postgis')\gexec
SQL

  for _rp_db in template_postgis "$_rp_main"; do
    if [ "$_rp_db" = template_postgis ] && [ "$_rp_main" = template_postgis ]; then
      continue
    fi
    _rp_exists=$("$_rp_run" postgres -X -q -A -t -v ON_ERROR_STOP=1 -v db="$_rp_db" <<'SQL'
SELECT 1 FROM pg_database WHERE datname = :'db';
SQL
) || return 1
    if [ "$_rp_exists" != 1 ]; then
      rp_warn "database '$_rp_db' does not exist; skipped PostGIS setup there"
      continue
    fi
    rp_log "ensuring PostGIS extensions in database '$_rp_db'"
    "$_rp_run" "$_rp_db" -v ON_ERROR_STOP=1 <<'SQL' || return 1
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
SQL
    if rp_is_true "${POSTGIS_TIGER_GEOCODER:-false}"; then
      # Legacy US Census geocoder. PostGIS 3.7 no longer ships it, so it is
      # opt-in; drop it before moving to 3.7.
      "$_rp_run" "$_rp_db" -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder;' || return 1
    fi
  done

  # Query statistics; the base image already preloads the library.
  "$_rp_run" "$_rp_main" -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;' \
    || rp_warn "could not create pg_stat_statements in '$_rp_main'"

  _rp_marker=$(rp_setup_marker)
  date -u +%Y-%m-%dT%H:%M:%SZ > "$_rp_marker" || return 1
  if rp_is_root; then chown postgres:postgres "$_rp_marker" || true; fi
  rp_log "PostGIS setup done: $("$_rp_run" "$_rp_main" -X -q -A -t -c 'SELECT postgis_full_version();' 2>/dev/null || echo 'version query failed')"
}

# ---------------------------------------------------------------------------
# Background job after the real server is up (it listens on TCP; the
# socket-only init server does not, so first-boot init is never disturbed):
#   1. finish the database setup if this volume has no marker yet,
#   2. PostGIS patch update (3.6.x -> 3.6.y) when the image was rebuilt with
#      a newer package (POSTGIS_AUTO_UPDATE). Different minors are only
#      reported, never updated automatically.
# ---------------------------------------------------------------------------
rp_psql_local() {
  _rp_dbname=$1
  shift
  if rp_is_root; then
    env PGDATABASE="$_rp_dbname" gosu postgres psql -h "$RP_LOCAL_SOCKET" -p "$RP_LOCAL_PORT" "$@"
  else
    env PGDATABASE="$_rp_dbname" psql -h "$RP_LOCAL_SOCKET" -p "$RP_LOCAL_PORT" "$@"
  fi
}

rp_post_start() {
  unset PGHOST PGHOSTADDR PGPORT PGSSLMODE
  export PGOPTIONS='-c lock_timeout=10s -c statement_timeout=15min'
  _rp_i=0
  until pg_isready -q -h 127.0.0.1 -p "$RP_LOCAL_PORT" >/dev/null 2>&1; do
    _rp_i=$((_rp_i + 1))
    if [ "$_rp_i" -ge 180 ]; then return 0; fi
    sleep 5
  done
  if [ "$(rp_psql_local postgres -X -q -A -t -c 'SELECT pg_is_in_recovery()' 2>/dev/null)" != "f" ]; then
    return 0
  fi

  if [ ! -f "$(rp_setup_marker)" ]; then
    rp_log "no PostGIS setup marker on this volume; running the database setup"
    rp_setup_databases rp_psql_local || rp_warn "database setup failed; it is retried on the next boot"
  fi

  if rp_is_true "${POSTGIS_AUTO_UPDATE:-true}"; then
    rp_psql_local postgres -X -q -A -t -c 'SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1' 2>/dev/null \
      | while IFS= read -r _rp_name; do
          [ -n "$_rp_name" ] || continue
          rp_psql_local "$_rp_name" -X -q -A -t -v ON_ERROR_STOP=0 -f "$RP_LIB_DIR/postgis-update.sql" 2>&1 \
            | while IFS= read -r _rp_line; do
                if [ -n "$_rp_line" ]; then printf 'railway-postgis: [%s] %s\n' "$_rp_name" "$_rp_line"; fi
              done
        done
  fi
}

rp_fork_post_start() {
  (
    # Same contract as the base image's background helpers: ignore the stop
    # signal that tini forwards to the process group.
    trap '' INT TERM
    rp_post_start
    exit 0
  ) &
}
