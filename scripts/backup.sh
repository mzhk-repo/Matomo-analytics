#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/autonomous-env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/autonomous-env.sh"
# shellcheck source=scripts/lib/docker-runtime.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/docker-runtime.sh"

DRY_RUN=false
ENVIRONMENT_ARG=""
backup_status="0"
run_timestamp="$(date +%s)"
success_timestamp="0"

usage() {
  echo "Usage: $0 [--env dev|prod] [--dry-run]"
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd"
    exit 1
  fi
}

run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "[backup][dry-run] $*"
    return 0
  fi
  "$@"
}

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
    *)
      echo "ERROR: unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

load_autonomous_env "${ROOT_DIR}" "${ENVIRONMENT_ARG}"
cd "${ROOT_DIR}"

DB_ROOT_PASS="${DB_ROOT_PASS:-}"
DB_NAME="${DB_NAME:-}"
BACKUP_DIR="${BACKUP_DIR:-}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
RCLONE_DEST_PATH="${RCLONE_DEST_PATH:-}"

NODE_EXPORTER_TEXTFILE_DIR="${NODE_EXPORTER_TEXTFILE_DIR:-./.data/node-exporter-textfile}"
BACKUP_METRICS_FILE="${BACKUP_METRICS_FILE:-matomo_backup.prom}"
BACKUP_METRICS_ENV_LABEL="${BACKUP_METRICS_ENV_LABEL:-prod}"
BACKUP_METRICS_SERVICE_LABEL="${BACKUP_METRICS_SERVICE_LABEL:-matomo}"

required_vars=(
  DB_ROOT_PASS
  DB_NAME
  BACKUP_DIR
  BACKUP_RETENTION_DAYS
  RCLONE_REMOTE
  RCLONE_DEST_PATH
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: required variable is empty: $var_name"
    exit 1
  fi
done

if ! [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] || [[ "$BACKUP_RETENTION_DAYS" -lt 1 ]]; then
  echo "ERROR: BACKUP_RETENTION_DAYS must be a positive integer"
  exit 1
fi

require_command docker
require_command gzip
require_command find
require_command rclone

abs_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$PWD" "$path"
  fi
}

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

emit_backup_metrics() {
  ensure_metrics_dir || {
    echo "WARN: failed to prepare metrics dir: $TEXTFILE_DIR_ABS"
    return 0
  }

  local metrics_payload
  metrics_payload="$(cat <<EOF
# HELP matomo_backup_last_run_timestamp Unix timestamp of the last Matomo backup attempt.
# TYPE matomo_backup_last_run_timestamp gauge
matomo_backup_last_run_timestamp{env="$BACKUP_METRICS_ENV_LABEL",service="$BACKUP_METRICS_SERVICE_LABEL"} $run_timestamp
# HELP matomo_backup_last_success_timestamp Unix timestamp of the last successful Matomo backup.
# TYPE matomo_backup_last_success_timestamp gauge
matomo_backup_last_success_timestamp{env="$BACKUP_METRICS_ENV_LABEL",service="$BACKUP_METRICS_SERVICE_LABEL"} $success_timestamp
# HELP matomo_backup_last_status Last Matomo backup status (1=success, 0=failure).
# TYPE matomo_backup_last_status gauge
matomo_backup_last_status{env="$BACKUP_METRICS_ENV_LABEL",service="$BACKUP_METRICS_SERVICE_LABEL"} $backup_status
EOF
)"

  printf '%s\n' "$metrics_payload" | docker run --rm -i \
    -v "$TEXTFILE_DIR_ABS:/metrics" \
    alpine:3.20 \
    sh -c "cat > /metrics/$BACKUP_METRICS_FILE"
}

on_exit() {
  local exit_code=$?
  if [[ "$exit_code" -eq 0 && "$backup_status" -ne 1 ]]; then
    backup_status="1"
    success_timestamp="$(date +%s)"
  fi
  emit_backup_metrics
  exit "$exit_code"
}
trap on_exit EXIT

if ! docker_runtime_service_accessible matomo-db; then
  echo "ERROR: could not access service 'matomo-db' (runtime=${DOCKER_RUNTIME_MODE}, stack=${STACK_NAME})"
  exit 1
fi

timestamp="$(date +%Y%m%d_%H%M%S)"
backup_file="${BACKUP_DIR}/matomo_${DB_NAME}_${timestamp}.sql.gz"

run_cmd mkdir -p "$BACKUP_DIR"

echo "[backup] ENV loaded from: env.${AUTONOMOUS_ENVIRONMENT}.enc"
echo "[backup] target file: $backup_file"
echo "[backup] retention days: $BACKUP_RETENTION_DAYS"
echo "[backup] remote: ${RCLONE_REMOTE}:${RCLONE_DEST_PATH}"
echo "[backup] metrics file: ${TEXTFILE_DIR_ABS}/${BACKUP_METRICS_FILE}"

if [[ "$DRY_RUN" == true ]]; then
  echo "[backup] DRY RUN: no data dump/upload/delete will be executed"
  echo "[backup][dry-run] docker_runtime_db_dump \"$DB_NAME\" | gzip -c > \"$backup_file\""
  echo "[backup][dry-run] rclone copy \"$backup_file\" \"${RCLONE_REMOTE}:${RCLONE_DEST_PATH}/\""
  echo "[backup][dry-run] find \"$BACKUP_DIR\" -maxdepth 1 -type f -name \"matomo_${DB_NAME}_*.sql.gz\" -mtime +$BACKUP_RETENTION_DAYS -delete"
  backup_status="1"
  success_timestamp="$(date +%s)"
  exit 0
fi

echo "[backup] creating database dump..."
if ! docker_runtime_db_dump "$DB_NAME" "${DB_ROOT_PASS:-}" | gzip -c > "$backup_file"; then
  echo "ERROR: database dump failed"
  rm -f "$backup_file"
  exit 1
fi

echo "[backup] uploading to remote..."
rclone copy "$backup_file" "${RCLONE_REMOTE}:${RCLONE_DEST_PATH}/"

echo "[backup] pruning local backups older than ${BACKUP_RETENTION_DAYS} days..."
find "$BACKUP_DIR" -maxdepth 1 -type f -name "matomo_${DB_NAME}_*.sql.gz" -mtime +"$BACKUP_RETENTION_DAYS" -print -delete

backup_status="1"
success_timestamp="$(date +%s)"

echo "[backup] completed: $backup_file"
ls -lh "$backup_file"
