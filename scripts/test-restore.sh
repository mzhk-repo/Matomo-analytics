#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${ROOT_DIR}/scripts"

# shellcheck source=scripts/lib/autonomous-env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/autonomous-env.sh"

DRY_RUN=false
ENVIRONMENT_ARG=""

usage() {
  cat <<'EOF'
Usage: scripts/test-restore.sh [--env dev|prod] [--dry-run] [backup-file.sql.gz|backup-file.sql]

Smoke test restore в тимчасовий MariaDB контейнер + експорт метрик у textfile collector.
EOF
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd"
    exit 1
  fi
}

read_env_or_default() {
  local key="$1"
  local default_value="$2"
  local env_value="${!key:-}"

  if [[ -n "$env_value" ]]; then
    printf '%s\n' "$env_value"
    return 0
  fi

  printf '%s\n' "$default_value"
}

abs_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$ROOT_DIR" "$path"
  fi
}

BACKUP_PATH=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --env)
      shift
      [[ "$#" -gt 0 ]] || {
        echo "ERROR: --env requires value"
        usage
        exit 1
      }
      ENVIRONMENT_ARG="$1"
      ;;
    --env=*)
      ENVIRONMENT_ARG="${1#--env=}"
      ;;
    dev|development|prod|production)
      ENVIRONMENT_ARG="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$BACKUP_PATH" ]]; then
        BACKUP_PATH="$1"
      else
        echo "ERROR: unexpected argument: $1"
        usage
        exit 1
      fi
      ;;
  esac
  shift
done

load_autonomous_env "${ROOT_DIR}" "${ENVIRONMENT_ARG}"
cd "${ROOT_DIR}"

require_command docker
require_command mktemp
require_command date

DB_NAME="$(read_env_or_default DB_NAME matomo)"
BACKUP_DIR="$(read_env_or_default BACKUP_DIR ./.backups)"
MARIADB_IMAGE="$(read_env_or_default MARIADB_IMAGE mariadb:11)"
NODE_EXPORTER_TEXTFILE_DIR="$(read_env_or_default NODE_EXPORTER_TEXTFILE_DIR ./.data/node-exporter-textfile)"
RESTORE_SMOKE_METRICS_FILE="$(read_env_or_default RESTORE_SMOKE_METRICS_FILE matomo_restore_smoke.prom)"
RESTORE_SMOKE_ENV_LABEL="$(read_env_or_default RESTORE_SMOKE_ENV_LABEL prod)"
RESTORE_SMOKE_SERVICE_LABEL="$(read_env_or_default RESTORE_SMOKE_SERVICE_LABEL matomo)"
RESTORE_SMOKE_TIMEOUT_SECONDS="$(read_env_or_default RESTORE_SMOKE_TIMEOUT_SECONDS 90)"

if ! [[ "$RESTORE_SMOKE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$RESTORE_SMOKE_TIMEOUT_SECONDS" -lt 10 ]]; then
  echo "ERROR: RESTORE_SMOKE_TIMEOUT_SECONDS must be an integer >= 10"
  exit 1
fi

if [[ -n "$BACKUP_PATH" ]]; then
  if [[ "$BACKUP_PATH" != /* ]]; then
    BACKUP_PATH="$(abs_path "$BACKUP_PATH")"
  fi
else
  BACKUP_DIR_ABS="$(abs_path "$BACKUP_DIR")"
  BACKUP_PATH="$(find "$BACKUP_DIR_ABS" -maxdepth 1 -type f \( -name "matomo_${DB_NAME}_*.sql.gz" -o -name "matomo_${DB_NAME}_*.sql" \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | awk '{print $2}' || true)"
fi

if [[ -z "$BACKUP_PATH" ]]; then
  echo "ERROR: backup file not found. Pass backup path explicitly or ensure backups exist in BACKUP_DIR"
  exit 1
fi

if [[ ! -f "$BACKUP_PATH" ]]; then
  echo "ERROR: backup file not found: $BACKUP_PATH"
  exit 1
fi

if [[ "$BACKUP_PATH" != *.sql.gz && "$BACKUP_PATH" != *.sql ]]; then
  echo "ERROR: unsupported backup format. Use .sql.gz or .sql"
  exit 1
fi

run_timestamp="$(date +%s)"
success_timestamp="0"
restore_status="0"

TEXTFILE_DIR_ABS="$(abs_path "$NODE_EXPORTER_TEXTFILE_DIR")"

ensure_metrics_dir() {
  if mkdir -p "$TEXTFILE_DIR_ABS" >/dev/null 2>&1; then
    return 0
  fi

  local parent_dir
  parent_dir="$(dirname "$TEXTFILE_DIR_ABS")"
  local base_name
  base_name="$(basename "$TEXTFILE_DIR_ABS")"

  if [[ ! -d "$parent_dir" ]]; then
    echo "ERROR: metrics parent directory does not exist: $parent_dir"
    return 1
  fi

  docker run --rm \
    -v "$parent_dir:/parent" \
    alpine:3.20 \
    sh -c "mkdir -p '/parent/$base_name'" >/dev/null
}

emit_restore_metrics() {
  ensure_metrics_dir

  local metrics_payload
  metrics_payload="$(cat <<EOF
# HELP matomo_restore_smoke_last_run_timestamp Unix timestamp of the last Matomo restore smoke test attempt.
# TYPE matomo_restore_smoke_last_run_timestamp gauge
matomo_restore_smoke_last_run_timestamp{env="$RESTORE_SMOKE_ENV_LABEL",service="$RESTORE_SMOKE_SERVICE_LABEL"} $run_timestamp
# HELP matomo_restore_smoke_last_success_timestamp Unix timestamp of the last successful Matomo restore smoke test.
# TYPE matomo_restore_smoke_last_success_timestamp gauge
matomo_restore_smoke_last_success_timestamp{env="$RESTORE_SMOKE_ENV_LABEL",service="$RESTORE_SMOKE_SERVICE_LABEL"} $success_timestamp
# HELP matomo_restore_smoke_last_status Last Matomo restore smoke test status (1=success, 0=failure).
# TYPE matomo_restore_smoke_last_status gauge
matomo_restore_smoke_last_status{env="$RESTORE_SMOKE_ENV_LABEL",service="$RESTORE_SMOKE_SERVICE_LABEL"} $restore_status
EOF
)"

  printf '%s\n' "$metrics_payload" | docker run --rm -i \
    -v "$TEXTFILE_DIR_ABS:/metrics" \
    alpine:3.20 \
    sh -c "cat > /metrics/$RESTORE_SMOKE_METRICS_FILE"
}

tmp_dir="$(mktemp -d)"
container_name="matomo-restore-smoke-$(date +%s)"
smoke_db_name="smoke_restore"
smoke_root_password="smoke_restore_pass"

cleanup() {
  local exit_code=$?
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  if [[ -d "$tmp_dir" ]]; then
    rm -rf "$tmp_dir" 2>/dev/null || true
  fi
  emit_restore_metrics
  exit "$exit_code"
}
trap cleanup EXIT

echo "[restore-smoke] backup file: $BACKUP_PATH"
echo "[restore-smoke] metrics file: $TEXTFILE_DIR_ABS/$RESTORE_SMOKE_METRICS_FILE"

if [[ "$DRY_RUN" == true ]]; then
  echo "[restore-smoke] DRY RUN: restore is skipped"
  restore_status="1"
  success_timestamp="$(date +%s)"
  exit 0
fi

echo "[restore-smoke] starting temporary MariaDB container: $container_name"
docker run -d --name "$container_name" \
  -e MYSQL_ROOT_PASSWORD="$smoke_root_password" \
  -e MYSQL_DATABASE="$smoke_db_name" \
  -v "$tmp_dir:/var/lib/mysql" \
  "$MARIADB_IMAGE" >/dev/null

max_attempts=$((RESTORE_SMOKE_TIMEOUT_SECONDS / 2))
for attempt in $(seq 1 "$max_attempts"); do
  if docker exec "$container_name" mariadb-admin ping -h127.0.0.1 -uroot -p"$smoke_root_password" --silent >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq "$max_attempts" ]]; then
    echo "ERROR: temporary MariaDB did not become ready within ${RESTORE_SMOKE_TIMEOUT_SECONDS}s"
    docker logs "$container_name" --tail 100 || true
    exit 1
  fi
  sleep 2
done

echo "[restore-smoke] importing dump into temporary database"
if [[ "$BACKUP_PATH" == *.sql.gz ]]; then
  require_command gzip
  gzip -dc "$BACKUP_PATH" | docker exec -i "$container_name" mariadb -uroot -p"$smoke_root_password" "$smoke_db_name"
else
  docker exec -i "$container_name" mariadb -uroot -p"$smoke_root_password" "$smoke_db_name" < "$BACKUP_PATH"
fi

table_count="$(docker exec "$container_name" mariadb -N -uroot -p"$smoke_root_password" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${smoke_db_name}';")"

if ! [[ "$table_count" =~ ^[0-9]+$ ]] || [[ "$table_count" -lt 1 ]]; then
  echo "ERROR: restore smoke test sanity check failed (table count: ${table_count:-n/a})"
  exit 1
fi

restore_status="1"
success_timestamp="$(date +%s)"
echo "[restore-smoke] completed successfully (tables in ${smoke_db_name}: $table_count)"
