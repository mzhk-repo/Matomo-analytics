#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/orchestrator-env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/orchestrator-env.sh"

ENV_FILE=""
DRY_RUN=""
MATOMO_ONLY=false
DOCKER_IMAGE="${INIT_VOLUMES_HELPER_IMAGE:-alpine:3.20}"
BACKUP_UID="${BACKUP_UID:-$(id -u)}"
BACKUP_GID="${BACKUP_GID:-$(id -g)}"
VOL_DB_PATH=""
VOL_MATOMO_DATA=""
BACKUP_DIR=""

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
    --matomo-only)
      MATOMO_ONLY=true
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
    docker run --rm -v "$parent_dir":/host "$DOCKER_IMAGE" sh -c "mkdir -p \"/host/$base_name\""
    return
  fi

  echo "ERROR: cannot create directory: $dir_path"
  exit 1
}

run_on_volume() {
  local volume_path="$1"
  local script="$2"

  run_cmd docker run --rm -v "${volume_path}:/target" "$DOCKER_IMAGE" sh -c "$script"
}

apply_backup_dir_permissions() {
  if [[ "$DRY_RUN" == "--dry-run" ]]; then
    if command -v docker >/dev/null 2>&1; then
      echo "[dry-run] docker run --rm -v \"${BACKUP_DIR}:/target\" \"$DOCKER_IMAGE\" sh -c \"chown -R ${BACKUP_UID}:${BACKUP_GID} /target && chmod 750 /target\""
    else
      echo "[dry-run] chmod 750 \"$BACKUP_DIR\""
    fi
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    if docker run --rm -v "${BACKUP_DIR}:/target" "$DOCKER_IMAGE" sh -c "chown -R ${BACKUP_UID}:${BACKUP_GID} /target && chmod 750 /target"; then
      return
    fi
    echo "WARNING: cannot normalize BACKUP_DIR ownership/mode via docker; continuing deploy because directory exists: $BACKUP_DIR"
    return
  fi

  if chmod 750 "$BACKUP_DIR"; then
    return
  fi
  echo "WARNING: cannot chmod BACKUP_DIR; continuing deploy because directory exists: $BACKUP_DIR"
}

init_backup_dir() {
  [[ "$BACKUP_UID" =~ ^[0-9]+$ ]] || orchestrator_env_die "BACKUP_UID must be numeric"
  [[ "$BACKUP_GID" =~ ^[0-9]+$ ]] || orchestrator_env_die "BACKUP_GID must be numeric"

  echo "Initializing backup directory"
  ensure_dir "$BACKUP_DIR"
  apply_backup_dir_permissions
}

init_matomo_dirs() {
  echo "Initializing Matomo writable directories"
  ensure_dir "$VOL_MATOMO_DATA"
  ensure_dir "$VOL_MATOMO_DATA/tmp/assets"
  ensure_dir "$VOL_MATOMO_DATA/tmp/cache"
  ensure_dir "$VOL_MATOMO_DATA/tmp/logs"
  ensure_dir "$VOL_MATOMO_DATA/tmp/tcpdf"
  ensure_dir "$VOL_MATOMO_DATA/tmp/templates_c"
}

normalize_matomo_permissions() {
  if command -v docker >/dev/null 2>&1; then
    echo "Applying Matomo ownership via ephemeral container (www-data:www-data)"
    run_on_volume "$VOL_MATOMO_DATA" '
      set -eu
      chown -R 33:33 /target
      chmod u=rwX,go=rX /target
      if [ -d /target/tmp ]; then
        find /target/tmp -type d -exec chmod 755 {} +
        find /target/tmp -type f -exec chmod 644 {} +
      fi
    '
  else
    echo "WARNING: docker is not available, skipping Matomo ownership fix"
  fi
}

normalize_database_permissions() {
  if command -v docker >/dev/null 2>&1; then
    echo "Applying MariaDB ownership via ephemeral container"
    run_on_volume "$VOL_DB_PATH" 'chown -R 999:999 /target && chmod -R u=rwX,g=rX,o= /target'
  else
    echo "WARNING: docker is not available, skipping MariaDB ownership fix"
  fi
}

guard_path "$VOL_DB_PATH"
guard_path "$VOL_MATOMO_DATA"
guard_path "$BACKUP_DIR"

echo "Preparing directories from $ENV_FILE"
init_matomo_dirs
normalize_matomo_permissions

if [[ "$MATOMO_ONLY" != "true" ]]; then
  ensure_dir "$VOL_DB_PATH"
  init_backup_dir
  normalize_database_permissions
fi

echo "Volume initialization completed"
