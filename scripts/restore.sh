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

ENVIRONMENT_ARG=""
FORCE=false
BACKUP_FILE=""

usage() {
  echo "Usage: $0 [--env dev|prod] [--force] <backup-file.sql.gz|backup-file.sql>"
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd"
    exit 1
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=true
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
      if [[ -z "$BACKUP_FILE" ]]; then
        BACKUP_FILE="$1"
      else
        echo "ERROR: unexpected argument: $1"
        usage
        exit 1
      fi
      ;;
  esac
  shift
done

if [[ -z "$BACKUP_FILE" ]]; then
  usage
  exit 1
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "ERROR: backup file not found: $BACKUP_FILE"
  exit 1
fi

load_autonomous_env "${ROOT_DIR}" "${ENVIRONMENT_ARG}"
cd "${ROOT_DIR}"

DB_NAME="${DB_NAME:-}"
DB_ROOT_PASS="${DB_ROOT_PASS:-}"

required_vars=(
  DB_NAME
  DB_ROOT_PASS
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: required variable is empty: $var_name"
    exit 1
  fi
done

require_command docker
require_command gzip

if ! docker_runtime_service_accessible matomo-db; then
  echo "ERROR: could not access service 'matomo-db' (runtime=${DOCKER_RUNTIME_MODE}, stack=${STACK_NAME})"
  exit 1
fi

if [[ "$FORCE" != true ]]; then
  if [[ ! -t 0 ]]; then
    echo "ERROR: non-interactive mode requires --force"
    exit 1
  fi

  echo "WARNING: restore will overwrite data in DB '$DB_NAME'."
  read -r -p "Type YES to continue: " confirm
  if [[ "$confirm" != "YES" ]]; then
    echo "[restore] canceled"
    exit 1
  fi
fi

echo "[restore] ENV loaded from: env.${AUTONOMOUS_ENVIRONMENT}.enc"
echo "[restore] source backup: $BACKUP_FILE"
echo "[restore] target database: $DB_NAME"

echo "[restore] importing dump..."
if [[ "$BACKUP_FILE" == *.sql.gz ]]; then
  gzip -dc "$BACKUP_FILE" | docker_runtime_db_import "$DB_NAME" "${DB_ROOT_PASS:-}"
elif [[ "$BACKUP_FILE" == *.sql ]]; then
  docker_runtime_db_import "$DB_NAME" "${DB_ROOT_PASS:-}" < "$BACKUP_FILE"
else
  echo "ERROR: unsupported backup format. Use .sql or .sql.gz"
  exit 1
fi

echo "[restore] running post-restore sanity query..."
docker_runtime_db_sanity "$DB_NAME" "${DB_ROOT_PASS:-}"

echo "[restore] completed successfully"
