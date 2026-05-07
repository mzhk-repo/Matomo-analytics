#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/orchestrator-env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/orchestrator-env.sh"

ENV_FILE="${ORCHESTRATOR_ENV_FILE:-}"
WRITE_ENV_FILE=""
PRINT_EXPORT=false
PAYLOAD_TMP=""
SECRET_TMP_FILES=()
RENDERED_SECRET_KEYS=()
RENDERED_SECRET_NAMES=()

log() {
  printf '[versioned-env-secret] %s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  scripts/render-versioned-env-secret.sh [--env-file FILE] [--write-env-file FILE] [--print-export]

Створює immutable Docker secrets для Matomo Swarm runtime env payload і
окремих secret values. Назви secrets містять hash payload/значення, тому
зміна env створює новий Docker secret name і новий Swarm service spec.

Options:
  --env-file FILE        Runtime env file (default: ORCHESTRATOR_ENV_FILE, fallback ./.env для dev)
  --write-env-file FILE  Замінити/додати generated *_SECRET_NAME у цьому env-файлі
  --print-export         Надрукувати shell export lines для ручних інтеграцій
  -h, --help             Показати цю довідку
USAGE
}

cleanup() {
  rm -f "${PAYLOAD_TMP:-}"
  if [[ "${#SECRET_TMP_FILES[@]}" -gt 0 ]]; then
    rm -f "${SECRET_TMP_FILES[@]}"
  fi
}

trap cleanup EXIT

validate_secret_base() {
  local secret_base="$1"

  [[ "${secret_base}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid secret base name: ${secret_base}"
}

environment_label() {
  case "${ENVIRONMENT_NAME:-}" in
    development|dev) printf 'dev\n' ;;
    production|prod) printf 'prod\n' ;;
    *) printf 'env\n' ;;
  esac
}

default_secret_base() {
  local logical_name="$1"

  printf '%s_%s_%s\n' "${STACK_NAME:-matomo}" "${logical_name}" "$(environment_label)"
}

create_or_reuse_secret() {
  local secret_name="$1"
  local secret_file="$2"
  local description="$3"

  if docker secret inspect "${secret_name}" >/dev/null 2>&1; then
    log "${description} already exists: ${secret_name}"
  else
    log "Creating ${description}: ${secret_name}"
    docker secret create "${secret_name}" "${secret_file}" >/dev/null
  fi
}

remember_rendered_secret() {
  local secret_key="$1"
  local secret_name="$2"

  RENDERED_SECRET_KEYS+=("${secret_key}")
  RENDERED_SECRET_NAMES+=("${secret_name}")
}

render_value_secret() {
  local value_key="$1"
  local secret_name_key="$2"
  local secret_base="$3"
  local description="$4"
  local secret_value value_tmp secret_hash secret_name

  secret_value="$(require_env_var "${value_key}" "${ENV_FILE}")"
  validate_secret_base "${secret_base}"

  value_tmp="$(mktemp "${TMPDIR:-/tmp}/matomo-secret-value.XXXXXX")"
  SECRET_TMP_FILES+=("${value_tmp}")
  chmod 600 "${value_tmp}"
  printf '%s' "${secret_value}" > "${value_tmp}"

  secret_hash="$(sha256sum "${value_tmp}" | awk '{print substr($1, 1, 12)}')"
  secret_name="${secret_base}_${secret_hash}"

  create_or_reuse_secret "${secret_name}" "${value_tmp}" "${description}"
  remember_rendered_secret "${secret_name_key}" "${secret_name}"
}

write_rendered_secrets_to_env_file() {
  local env_file="$1"
  local secret_key secret_name index update_tmp

  [[ -n "${env_file}" ]] || return 0

  for index in "${!RENDERED_SECRET_KEYS[@]}"; do
    secret_key="${RENDERED_SECRET_KEYS[${index}]}"
    secret_name="${RENDERED_SECRET_NAMES[${index}]}"
    update_tmp="$(mktemp "$(dirname "${env_file}")/.versioned-secret-name.XXXXXX")"
    chmod 600 "${update_tmp}"
    awk -v secret_key="${secret_key}" -v secret_name="${secret_name}" '
      function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
      }
      BEGIN { replaced = 0 }
      {
        line = $0
        sub(/\r$/, "", line)
        candidate = line
        sub(/^[[:space:]]*export[[:space:]]+/, "", candidate)
        if (candidate ~ /^[[:space:]]*#/ || candidate !~ /=/) {
          print line
          next
        }
        key = trim(substr(candidate, 1, index(candidate, "=") - 1))
        if (key == secret_key) {
          print secret_key "=" secret_name
          replaced = 1
          next
        }
        print line
      }
      END {
        if (replaced == 0) {
          print secret_key "=" secret_name
        }
      }
    ' "${env_file}" > "${update_tmp}"
    mv "${update_tmp}" "${env_file}"
  done

  chmod 600 "${env_file}"
  log "Updated generated secret names in ${env_file}"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:-}"
      [[ -n "${ENV_FILE}" ]] || die "--env-file requires a value"
      shift 2
      ;;
    --write-env-file)
      WRITE_ENV_FILE="${2:-}"
      [[ -n "${WRITE_ENV_FILE}" ]] || die "--write-env-file requires a value"
      shift 2
      ;;
    --print-export)
      PRINT_EXPORT=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

ENV_FILE="$(resolve_orchestrator_env_file "${PROJECT_ROOT}" "${ENV_FILE}")"
[[ -s "${ENV_FILE}" ]] || die "env file is missing or empty: ${ENV_FILE}"

if [[ -n "${WRITE_ENV_FILE}" && "${WRITE_ENV_FILE}" != "${ENV_FILE}" ]]; then
  [[ -f "${WRITE_ENV_FILE}" ]] || die "--write-env-file target not found: ${WRITE_ENV_FILE}"
fi

command -v docker >/dev/null 2>&1 || die "docker not found"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found"
command -v awk >/dev/null 2>&1 || die "awk not found"

PAYLOAD_TMP="$(mktemp "${TMPDIR:-/tmp}/matomo-env-payload.XXXXXX")"
chmod 600 "${PAYLOAD_TMP}"
cp "${ENV_FILE}" "${PAYLOAD_TMP}"

payload_hash="$(dotenv_checksum_file "${PAYLOAD_TMP}" | awk '{print substr($1, 1, 12)}')"
payload_secret_base="${MATOMO_APP_ENV_SECRET_BASE:-$(default_secret_base app_env_payload)}"
validate_secret_base "${payload_secret_base}"
payload_secret_name="${payload_secret_base}_${payload_hash}"

create_or_reuse_secret "${payload_secret_name}" "${PAYLOAD_TMP}" "runtime env payload secret"
remember_rendered_secret "MATOMO_APP_ENV_SECRET_NAME" "${payload_secret_name}"

render_value_secret \
  MATOMO_API_TOKEN \
  MATOMO_API_TOKEN_SECRET_NAME \
  "${MATOMO_API_TOKEN_SECRET_BASE:-$(default_secret_base api_token)}" \
  "Matomo API token secret"

render_value_secret \
  DB_PASS \
  MATOMO_DB_PASSWORD_SECRET_NAME \
  "${MATOMO_DB_PASSWORD_SECRET_BASE:-$(default_secret_base db_password)}" \
  "MariaDB password secret"

render_value_secret \
  DB_ROOT_PASS \
  MATOMO_DB_ROOT_PASSWORD_SECRET_NAME \
  "${MATOMO_DB_ROOT_PASSWORD_SECRET_BASE:-$(default_secret_base db_root_password)}" \
  "MariaDB root password secret"

if [[ -n "${WRITE_ENV_FILE}" ]]; then
  write_rendered_secrets_to_env_file "${WRITE_ENV_FILE}"
fi

for index in "${!RENDERED_SECRET_KEYS[@]}"; do
  log "Using ${RENDERED_SECRET_KEYS[${index}]}: ${RENDERED_SECRET_NAMES[${index}]}"
  printf '%s=%s\n' "${RENDERED_SECRET_KEYS[${index}]}" "${RENDERED_SECRET_NAMES[${index}]}"
done

if [[ "${PRINT_EXPORT}" == "true" ]]; then
  for index in "${!RENDERED_SECRET_KEYS[@]}"; do
    printf 'export %s=%q\n' "${RENDERED_SECRET_KEYS[${index}]}" "${RENDERED_SECRET_NAMES[${index}]}"
  done
fi
