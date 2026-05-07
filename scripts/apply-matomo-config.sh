#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/orchestrator-env.sh
. "${SCRIPT_DIR}/lib/orchestrator-env.sh"

ENV_FILE=""
DOCKER_RUNTIME_MODE="${DOCKER_RUNTIME_MODE:-compose}"
STACK_NAME="${STACK_NAME:-matomo}"
CHECKSUM_RESTART_DONE=0

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

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd"
    exit 1
  fi
}

require_command docker
require_command sha256sum

DB_USER="$(require_env_var DB_USER "${ENV_FILE}")"
DB_PASS="$(require_env_var DB_PASS "${ENV_FILE}")"
DB_NAME="$(require_env_var DB_NAME "${ENV_FILE}")"
DB_PREFIX="$(require_env_var DB_PREFIX "${ENV_FILE}")"
SMTP_USER="$(read_env_var SMTP_USER "${ENV_FILE}")"
SMTP_PASS="$(read_env_var SMTP_PASS "${ENV_FILE}")"

MATOMO_CFG_FORCE_SSL="$(read_env_var MATOMO_CFG_FORCE_SSL "${ENV_FILE}")"
MATOMO_CFG_LOGIN_ALLOW_SIGNUP="$(read_env_var MATOMO_CFG_LOGIN_ALLOW_SIGNUP "${ENV_FILE}")"
MATOMO_CFG_LOGIN_ALLOW_RESET_PASSWORD="$(read_env_var MATOMO_CFG_LOGIN_ALLOW_RESET_PASSWORD "${ENV_FILE}")"
MATOMO_CFG_ENABLE_BROWSER_ARCHIVING_TRIGGERING="$(read_env_var MATOMO_CFG_ENABLE_BROWSER_ARCHIVING_TRIGGERING "${ENV_FILE}")"
MATOMO_CFG_IGNORE_VISITS_DO_NOT_TRACK="$(read_env_var MATOMO_CFG_IGNORE_VISITS_DO_NOT_TRACK "${ENV_FILE}")"
MATOMO_CFG_ENABLE_LOGIN_OIDC="$(read_env_var MATOMO_CFG_ENABLE_LOGIN_OIDC "${ENV_FILE}")"
MATOMO_CFG_OIDC_ALLOW_SIGNUP="$(read_env_var MATOMO_CFG_OIDC_ALLOW_SIGNUP "${ENV_FILE}")"
MATOMO_CFG_OIDC_AUTO_LINKING="$(read_env_var MATOMO_CFG_OIDC_AUTO_LINKING "${ENV_FILE}")"
MATOMO_CFG_OIDC_USERINFO_ID="$(read_env_var MATOMO_CFG_OIDC_USERINFO_ID "${ENV_FILE}")"
MATOMO_CFG_SMTP_HOST="$(read_env_var MATOMO_CFG_SMTP_HOST "${ENV_FILE}")"
MATOMO_CFG_SMTP_PORT="$(read_env_var MATOMO_CFG_SMTP_PORT "${ENV_FILE}")"
MATOMO_CFG_SMTP_TRANSPORT="$(read_env_var MATOMO_CFG_SMTP_TRANSPORT "${ENV_FILE}")"
MATOMO_CFG_SMTP_TYPE="$(read_env_var MATOMO_CFG_SMTP_TYPE "${ENV_FILE}")"
MATOMO_CFG_SMTP_ENCRYPTION="$(read_env_var MATOMO_CFG_SMTP_ENCRYPTION "${ENV_FILE}")"
MATOMO_CFG_SMTP_FROM_NAME="$(read_env_var MATOMO_CFG_SMTP_FROM_NAME "${ENV_FILE}")"
MATOMO_CFG_SMTP_FROM_ADDRESS="$(read_env_var MATOMO_CFG_SMTP_FROM_ADDRESS "${ENV_FILE}")"

MATOMO_CFG_FORCE_SSL="${MATOMO_CFG_FORCE_SSL:-1}"
MATOMO_CFG_LOGIN_ALLOW_SIGNUP="${MATOMO_CFG_LOGIN_ALLOW_SIGNUP:-0}"
MATOMO_CFG_LOGIN_ALLOW_RESET_PASSWORD="${MATOMO_CFG_LOGIN_ALLOW_RESET_PASSWORD:-0}"
MATOMO_CFG_ENABLE_BROWSER_ARCHIVING_TRIGGERING="${MATOMO_CFG_ENABLE_BROWSER_ARCHIVING_TRIGGERING:-0}"
MATOMO_CFG_IGNORE_VISITS_DO_NOT_TRACK="${MATOMO_CFG_IGNORE_VISITS_DO_NOT_TRACK:-1}"
MATOMO_CFG_ENABLE_LOGIN_OIDC="${MATOMO_CFG_ENABLE_LOGIN_OIDC:-1}"
MATOMO_CFG_OIDC_ALLOW_SIGNUP="${MATOMO_CFG_OIDC_ALLOW_SIGNUP:-0}"
MATOMO_CFG_OIDC_AUTO_LINKING="${MATOMO_CFG_OIDC_AUTO_LINKING:-1}"
MATOMO_CFG_OIDC_USERINFO_ID="${MATOMO_CFG_OIDC_USERINFO_ID:-email}"
MATOMO_CFG_SMTP_HOST="${MATOMO_CFG_SMTP_HOST:-smtp.office365.com}"
MATOMO_CFG_SMTP_PORT="${MATOMO_CFG_SMTP_PORT:-587}"
MATOMO_CFG_SMTP_TRANSPORT="${MATOMO_CFG_SMTP_TRANSPORT:-smtp}"
MATOMO_CFG_SMTP_TYPE="${MATOMO_CFG_SMTP_TYPE:-Login}"
MATOMO_CFG_SMTP_ENCRYPTION="${MATOMO_CFG_SMTP_ENCRYPTION:-tls}"
MATOMO_CFG_SMTP_FROM_NAME="${MATOMO_CFG_SMTP_FROM_NAME:-Matomo Analytics}"
MATOMO_CFG_SMTP_FROM_ADDRESS="${MATOMO_CFG_SMTP_FROM_ADDRESS:-${SMTP_USER:-}}"

swarm_container_id() {
  local service="$1"
  local service_name="${STACK_NAME}_${service}"
  local container_id

  container_id="$(docker ps \
    --filter "label=com.docker.swarm.service.name=${service_name}" \
    --filter "status=running" \
    --format '{{.ID}}' | head -n1)"
  [[ -n "${container_id}" ]] || {
    echo "ERROR: running container not found for Swarm service: ${service_name}" >&2
    return 1
  }
  printf '%s\n' "${container_id}"
}

runtime_exec() {
  local service="$1"
  shift

  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      docker compose exec -T "${service}" "$@"
      ;;
    swarm)
      local container_id
      container_id="$(swarm_container_id "${service}")"
      docker exec -i "${container_id}" "$@"
      ;;
    *)
      echo "ERROR: unsupported DOCKER_RUNTIME_MODE=${DOCKER_RUNTIME_MODE}" >&2
      exit 1
      ;;
  esac
}

runtime_service_accessible() {
  local service="$1"

  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      docker compose ps "${service}" >/dev/null 2>&1
      ;;
    swarm)
      swarm_container_id "${service}" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

restart_swarm_config_consumers() {
  local service

  [[ "${DOCKER_RUNTIME_MODE}" == "swarm" ]] || return 0
  for service in matomo-app matomo-cron; do
    echo "[matomo-config] forcing Swarm service update: ${STACK_NAME}_${service}"
    docker service update --force "${STACK_NAME}_${service}" >/dev/null
  done
}

implemented_env_checksum() {
  runtime_exec matomo-app sh -ec 'test -f /run/secrets/app_env_payload && cat /run/secrets/app_env_payload' \
    | normalize_dotenv_stream \
    | sha256sum \
    | awk '{print $1}'
}

wait_for_swarm_container() {
  local service="$1"
  local timeout="${2:-90}"
  local previous_container_id="${3:-}"
  local elapsed=0
  local container_id

  while (( elapsed < timeout )); do
    container_id="$(swarm_container_id "${service}" 2>/dev/null || true)"
    if [[ -n "${container_id}" && "${container_id}" != "${previous_container_id}" ]]; then
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done

  echo "ERROR: timeout waiting for Swarm service: ${STACK_NAME}_${service}" >&2
  return 1
}

ensure_env_payload_checksum() {
  [[ "${DOCKER_RUNTIME_MODE}" == "swarm" ]] || return 0

  local input_checksum implemented_checksum previous_container_id
  input_checksum="$(dotenv_checksum_file "${ENV_FILE}")"

  wait_for_swarm_container matomo-app
  implemented_checksum="$(implemented_env_checksum)"

  if [[ "${input_checksum}" == "${implemented_checksum}" ]]; then
    echo "[matomo-config] app_env_payload checksum is up to date"
    return 0
  fi

  echo "[matomo-config] app_env_payload checksum mismatch; restarting Swarm config consumers"
  previous_container_id="$(swarm_container_id matomo-app)"
  restart_swarm_config_consumers
  CHECKSUM_RESTART_DONE=1

  wait_for_swarm_container matomo-app 120 "${previous_container_id}"
  implemented_checksum="$(implemented_env_checksum)"

  if [[ "${input_checksum}" != "${implemented_checksum}" ]]; then
    echo "[matomo-config] ERROR: app_env_payload checksum still differs after restart" >&2
    echo "[matomo-config] Hint: refresh external Docker secrets from the decrypted env before running this script." >&2
    exit 1
  fi

  echo "[matomo-config] app_env_payload checksum synchronized after restart"
}

if ! runtime_service_accessible matomo-app; then
  echo "ERROR: could not access service 'matomo-app' (runtime=${DOCKER_RUNTIME_MODE})"
  exit 1
fi

if ! runtime_service_accessible matomo-db; then
  echo "ERROR: could not access service 'matomo-db' (runtime=${DOCKER_RUNTIME_MODE})"
  exit 1
fi

ensure_env_payload_checksum

sql_escape() {
  local value="$1"
  value="${value//\'/\'\'}"
  echo "$value"
}

set_plugin_setting() {
  local plugin_name="$1"
  local setting_name="$2"
  local setting_value="$3"

  local plugin_escaped
  local setting_escaped
  local value_escaped
  plugin_escaped="$(sql_escape "$plugin_name")"
  setting_escaped="$(sql_escape "$setting_name")"
  value_escaped="$(sql_escape "$setting_value")"

  echo "[matomo-config] setting plugin ${plugin_name}.${setting_name}=${setting_value}"
  runtime_exec matomo-db mariadb -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e "
UPDATE ${DB_PREFIX}plugin_setting
SET setting_value = '${value_escaped}'
WHERE plugin_name = '${plugin_escaped}'
  AND setting_name = '${setting_escaped}'
  AND user_login = '';

INSERT INTO ${DB_PREFIX}plugin_setting (plugin_name, setting_name, setting_value, json_encoded, user_login)
SELECT '${plugin_escaped}', '${setting_escaped}', '${value_escaped}', 0, ''
FROM DUAL
WHERE NOT EXISTS (
  SELECT 1
  FROM ${DB_PREFIX}plugin_setting
  WHERE plugin_name = '${plugin_escaped}'
    AND setting_name = '${setting_escaped}'
    AND user_login = ''
);
" >/dev/null
}

set_config() {
  local section="$1"
  local key="$2"
  local value="$3"
  local secret="${4:-0}"

  if [[ "$secret" == "1" ]]; then
    echo "[matomo-config] setting [${section}] ${key}=***"
  else
    echo "[matomo-config] setting [${section}] ${key}=${value}"
  fi
  runtime_exec matomo-app php /var/www/html/console config:set \
    --section="$section" \
    --key="$key" \
    --value="$value" >/dev/null
}

set_config "General" "force_ssl" "$MATOMO_CFG_FORCE_SSL"
set_config "General" "login_allow_signup" "$MATOMO_CFG_LOGIN_ALLOW_SIGNUP"
set_config "General" "login_allow_reset_password" "$MATOMO_CFG_LOGIN_ALLOW_RESET_PASSWORD"
set_config "General" "enable_browser_archiving_triggering" "$MATOMO_CFG_ENABLE_BROWSER_ARCHIVING_TRIGGERING"
set_config "Tracker" "ignore_visits_do_not_track" "$MATOMO_CFG_IGNORE_VISITS_DO_NOT_TRACK"

if [[ -n "${SMTP_USER}" && -n "${SMTP_PASS}" ]]; then
  set_config "mail" "transport" "$MATOMO_CFG_SMTP_TRANSPORT"
  set_config "mail" "host" "$MATOMO_CFG_SMTP_HOST"
  set_config "mail" "port" "$MATOMO_CFG_SMTP_PORT"
  set_config "mail" "type" "$MATOMO_CFG_SMTP_TYPE"
  set_config "mail" "encryption" "$MATOMO_CFG_SMTP_ENCRYPTION"
  set_config "mail" "username" "$SMTP_USER"
  set_config "mail" "password" "$SMTP_PASS" "1"

  if [[ -n "$MATOMO_CFG_SMTP_FROM_ADDRESS" ]]; then
    set_config "General" "noreply_email_address" "$MATOMO_CFG_SMTP_FROM_ADDRESS"
  fi
  set_config "General" "noreply_email_name" "$MATOMO_CFG_SMTP_FROM_NAME"
else
  echo "[matomo-config] SMTP_USER/SMTP_PASS not set, skipping SMTP mail configuration"
fi

if [[ "$MATOMO_CFG_ENABLE_LOGIN_OIDC" == "1" ]]; then
  if runtime_exec matomo-app sh -lc '[ -d /var/www/html/plugins/LoginOIDC ]'; then
    echo "[matomo-config] activating LoginOIDC plugin"
    runtime_exec matomo-app php /var/www/html/console plugin:activate LoginOIDC >/dev/null || true

    set_plugin_setting "LoginOIDC" "allowSignup" "$MATOMO_CFG_OIDC_ALLOW_SIGNUP"
    set_plugin_setting "LoginOIDC" "autoLinking" "$MATOMO_CFG_OIDC_AUTO_LINKING"
    set_plugin_setting "LoginOIDC" "userinfoId" "$MATOMO_CFG_OIDC_USERINFO_ID"
  else
    echo "[matomo-config] LoginOIDC plugin directory not found, skipping activation"
  fi
fi

if [[ "${CHECKSUM_RESTART_DONE}" == "1" ]]; then
  echo "[matomo-config] done after Swarm checksum-driven restart"
else
  echo "[matomo-config] done"
fi
