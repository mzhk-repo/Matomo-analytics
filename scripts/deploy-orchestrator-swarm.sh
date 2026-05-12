#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/orchestrator-env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/orchestrator-env.sh"

MODE="${ORCHESTRATOR_MODE:-noop}"
STACK_NAME="${STACK_NAME:-matomo}"
ENV_FILE="${ORCHESTRATOR_ENV_FILE:-/tmp/env.decrypted}"
RAW_MANIFEST=""
DEPLOY_MANIFEST=""
RENDER_ENV_FILE=""

log() {
  printf '[deploy-orchestrator] %s\n' "$*"
}

cleanup() {
  rm -f \
    "${RAW_MANIFEST:-}" \
    "${DEPLOY_MANIFEST:-}" \
    "${RENDER_ENV_FILE:-}"

  find "${PROJECT_ROOT}" -maxdepth 1 -type f \
    \( -name ".${STACK_NAME}.stack.raw.*.yml" \
      -o -name ".${STACK_NAME}.stack.deploy.*.yml" \) \
    -delete
}

detect_compose_file() {
  if [[ -f "docker-compose.yaml" ]]; then
    echo "docker-compose.yaml"
  elif [[ -f "docker-compose.yml" ]]; then
    echo "docker-compose.yml"
  else
    echo ""
  fi
}

run_ansible_secrets_if_configured() {
  local infra_repo_path environment inventory_env inventory_path playbook_path

  infra_repo_path="${INFRA_REPO_PATH:-}"
  environment="${ENVIRONMENT_NAME:-}"

  if [[ -z "${infra_repo_path}" ]]; then
    log "INFRA_REPO_PATH is not set; skip ansible secrets refresh"
    return 0
  fi

  if [[ ! -d "${infra_repo_path}" ]]; then
    log "ERROR: INFRA_REPO_PATH does not exist: ${infra_repo_path}"
    exit 1
  fi

  if ! command -v ansible-playbook >/dev/null 2>&1; then
    log "ERROR: ansible-playbook not found on host"
    exit 1
  fi

  case "${environment}" in
    development|dev)
      inventory_env="dev"
      ;;
    production|prod)
      inventory_env="prod"
      ;;
    *)
      log "ERROR: unsupported ENVIRONMENT_NAME=${environment} (expected: development|production)"
      exit 1
      ;;
  esac

  inventory_path="${infra_repo_path}/ansible/inventories/${inventory_env}/hosts.yml"
  playbook_path="${infra_repo_path}/ansible/playbooks/swarm.yml"

  if [[ ! -f "${inventory_path}" ]]; then
    log "ERROR: inventory file not found: ${inventory_path}"
    exit 1
  fi
  if [[ ! -f "${playbook_path}" ]]; then
    log "ERROR: playbook file not found: ${playbook_path}"
    exit 1
  fi

  log "Refreshing Swarm secrets via Ansible (inventory=${inventory_env})"
  ANSIBLE_CONFIG="${infra_repo_path}/ansible/ansible.cfg" \
    ansible-playbook \
    -i "${inventory_path}" \
    "${playbook_path}" \
    --tags secrets
}

run_validation_checks() {
  local compose_file="$1"
  local env_file="$2"

  log "Running validation checks"
  bash "${SCRIPT_DIR}/check-ports-policy.sh" "${compose_file}"
  bash "${SCRIPT_DIR}/verify-env.sh" "${env_file}"
}

run_deploy_adjacent_hooks() {
  local env_file="$1"

  log "Running deploy-adjacent hooks"
  ORCHESTRATOR_ENV_FILE="${env_file}" bash "${SCRIPT_DIR}/init-volumes.sh"
}

prepare_swarm_secrets() {
  local env_file="$1"
  local render_env_file="$2"

  cp "${env_file}" "${render_env_file}"
  STACK_NAME="${STACK_NAME}" \
    ORCHESTRATOR_ENV_FILE="${env_file}" \
    bash "${SCRIPT_DIR}/render-versioned-env-secret.sh" \
      --env-file "${env_file}" \
      --write-env-file "${render_env_file}" >/dev/null

  log "Swarm secrets prepared with versioned secret names"
}

wait_for_swarm_container() {
  local service="$1"
  local timeout="${2:-90}"
  local service_name="${STACK_NAME}_${service}"
  local elapsed=0

  while (( elapsed < timeout )); do
    if docker ps \
      --filter "label=com.docker.swarm.service.name=${service_name}" \
      --filter "status=running" \
      --format '{{.ID}}' | grep -q .; then
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done

  log "ERROR: timeout waiting for Swarm service ${service_name}"
  exit 1
}

sync_database_user_credentials() {
  local db_container_id

  db_container_id="$(docker ps \
    --filter "label=com.docker.swarm.service.name=${STACK_NAME}_matomo-db" \
    --filter "status=running" \
    --format '{{.ID}}' | head -n1)"
  [[ -n "${db_container_id}" ]] || {
    log "ERROR: running container not found for Swarm service ${STACK_NAME}_matomo-db"
    exit 1
  }

  log "Synchronizing MariaDB application user credentials"
  docker exec -i "${db_container_id}" sh -se <<'SYNC_DB_USER'
db_name="${MARIADB_DATABASE:?MARIADB_DATABASE is required}"
db_user="${MARIADB_USER:?MARIADB_USER is required}"
db_pass="$(cat /run/secrets/db_password)"
root_pass="$(cat /run/secrets/db_root_password)"

sql_string() {
  printf "%s" "$1" | sed "s/'/''/g"
}

sql_ident() {
  printf "%s" "$1" | sed 's/`/``/g'
}

db_name_escaped="$(sql_ident "$db_name")"
db_user_escaped="$(sql_string "$db_user")"
db_pass_escaped="$(sql_string "$db_pass")"

MYSQL_PWD="$root_pass" mariadb -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name_escaped}\`;
CREATE USER IF NOT EXISTS '${db_user_escaped}'@'%' IDENTIFIED BY '${db_pass_escaped}';
ALTER USER '${db_user_escaped}'@'%' IDENTIFIED BY '${db_pass_escaped}';
GRANT ALL PRIVILEGES ON \`${db_name_escaped}\`.* TO '${db_user_escaped}'@'%';
FLUSH PRIVILEGES;
SQL
SYNC_DB_USER
}

run_post_deploy_hooks() {
  local env_file="$1"

  wait_for_swarm_container matomo-app
  wait_for_swarm_container matomo-db

  sync_database_user_credentials

  log "Re-applying Matomo writable directory permissions"
  ORCHESTRATOR_ENV_FILE="${env_file}" bash "${SCRIPT_DIR}/init-volumes.sh" --matomo-only

  log "Applying Matomo runtime config"
  ORCHESTRATOR_ENV_FILE="${env_file}" \
    DOCKER_RUNTIME_MODE=swarm \
    STACK_NAME="${STACK_NAME}" \
    bash "${SCRIPT_DIR}/apply-matomo-config.sh"
}

deploy_swarm() {
  local compose_file swarm_file

  compose_file="$(detect_compose_file)"
  swarm_file="docker-compose.swarm.yml"
  RAW_MANIFEST="$(mktemp "${PROJECT_ROOT}/.${STACK_NAME}.stack.raw.XXXXXX.yml")"
  DEPLOY_MANIFEST="$(mktemp "${PROJECT_ROOT}/.${STACK_NAME}.stack.deploy.XXXXXX.yml")"
  RENDER_ENV_FILE="$(mktemp /dev/shm/matomo-render-env-XXXXXX)"
  chmod 600 "${RENDER_ENV_FILE}"

  if [[ -z "${compose_file}" ]]; then
    log "ERROR: compose file not found (expected docker-compose.yaml|yml)"
    exit 1
  fi
  if [[ ! -f "${swarm_file}" ]]; then
    log "ERROR: ${swarm_file} not found"
    exit 1
  fi

  if [[ ! -f "${ENV_FILE}" ]]; then
    if [[ -f ".env" ]]; then
      ENV_FILE=".env"
      log "WARNING: env.*.enc не знайдено або ORCHESTRATOR_ENV_FILE не передано. Fallback на локальний .env — тільки для dev-середовища."
    else
      log "ERROR: env file not found (${ORCHESTRATOR_ENV_FILE:-/tmp/env.decrypted}) and .env missing"
      exit 1
    fi
  fi

  run_validation_checks "${compose_file}" "${ENV_FILE}"

  run_ansible_secrets_if_configured
  run_deploy_adjacent_hooks "${ENV_FILE}"
  prepare_swarm_secrets "${ENV_FILE}" "${RENDER_ENV_FILE}"

  log "Rendering Swarm manifest (stack=${STACK_NAME}, env_file=${RENDER_ENV_FILE})"
  docker compose --env-file "${RENDER_ENV_FILE}" \
    -f "${compose_file}" \
    -f "${swarm_file}" \
    config > "${RAW_MANIFEST}"

  awk 'NR==1 && $1=="name:" {next} {print}' "${RAW_MANIFEST}" > "${DEPLOY_MANIFEST}"

  log "Deploying stack ${STACK_NAME}"
  docker stack deploy -c "${DEPLOY_MANIFEST}" "${STACK_NAME}"
  run_post_deploy_hooks "${ENV_FILE}"

  log "Swarm deploy completed"
}

trap cleanup EXIT

cd "${PROJECT_ROOT}"

case "${MODE}" in
  noop)
    log "No-op mode. Set ORCHESTRATOR_MODE=swarm to enable Phase 8 Swarm deploy path."
    ;;
  swarm)
    deploy_swarm
    ;;
  *)
    log "ERROR: unknown ORCHESTRATOR_MODE=${MODE}. Supported: noop, swarm"
    exit 1
    ;;
esac
