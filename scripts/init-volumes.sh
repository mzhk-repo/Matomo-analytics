#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/orchestrator-env.sh
. "${SCRIPT_DIR}/lib/orchestrator-env.sh"

ENV_FILE=""
DRY_RUN=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --env-file)
      shift
      [[ "$#" -gt 0 ]] || orchestrator_env_die "--env-file requires value"
      ENV_FILE="$1"
      ;;
    --env-file=*)
      ENV_FILE="${1#--env-file=}"
      ;;
    --dry-run)
      DRY_RUN="--dry-run"
      ;;
    *)
      if [[ -z "${ENV_FILE}" ]]; then
        ENV_FILE="$1"
      else
        orchestrator_env_die "unexpected argument: $1"
      fi
      ;;
  esac
  shift
done

ENV_FILE="$(resolve_orchestrator_env_file "${PROJECT_ROOT}" "${ENV_FILE}")"

required_vars=(
  VOL_DB_PATH
  VOL_MATOMO_DATA
  BACKUP_DIR
)

for var_name in "${required_vars[@]}"; do
  declare "${var_name}=$(require_env_var "${var_name}" "${ENV_FILE}")"
done

guard_path() {
  local path="$1"
  if [[ "$path" == "/" || "$path" == "." || "$path" == ".." ]]; then
    echo "ERROR: unsafe path: $path"
    exit 1
  fi
}

run_cmd() {
  if [[ "$DRY_RUN" == "--dry-run" ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

ensure_dir() {
  local dir_path="$1"
  if [[ "$DRY_RUN" == "--dry-run" ]]; then
    echo "[dry-run] mkdir -p \"$dir_path\""
    return
  fi

  if mkdir -p "$dir_path" 2>/dev/null; then
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    local parent_dir
    local base_name
    parent_dir="$(dirname "$dir_path")"
    base_name="$(basename "$dir_path")"
    docker run --rm -v "$parent_dir":/host alpine:3.20 sh -c "mkdir -p /host/$base_name"
    return
  fi

  echo "ERROR: cannot create directory: $dir_path"
  exit 1
}

guard_path "$VOL_DB_PATH"
guard_path "$VOL_MATOMO_DATA"
guard_path "$BACKUP_DIR"

echo "Preparing directories from $ENV_FILE"
ensure_dir "$VOL_DB_PATH"
ensure_dir "$VOL_MATOMO_DATA"
ensure_dir "$BACKUP_DIR"

echo "Initializing Matomo writable directories"
ensure_dir "$VOL_MATOMO_DATA/tmp/assets"
ensure_dir "$VOL_MATOMO_DATA/tmp/cache"
ensure_dir "$VOL_MATOMO_DATA/tmp/logs"
ensure_dir "$VOL_MATOMO_DATA/tmp/tcpdf"
ensure_dir "$VOL_MATOMO_DATA/tmp/templates_c"

if command -v docker >/dev/null 2>&1; then
  echo "Applying ownership via ephemeral containers (no sudo required)"
  run_cmd docker run --rm -v "${VOL_MATOMO_DATA}:/target" alpine:3.20 sh -c 'chown -R 33:33 /target && chmod -R u=rwX,go=rX /target/tmp'
  run_cmd docker run --rm -v "${VOL_DB_PATH}:/target" alpine:3.20 sh -c 'chown -R 999:999 /target && chmod -R u=rwX,g=rX,o= /target'
else
  echo "WARNING: docker is not available, skipping ownership fix"
fi

run_cmd chmod 750 "$BACKUP_DIR"

echo "Volume initialization completed"
