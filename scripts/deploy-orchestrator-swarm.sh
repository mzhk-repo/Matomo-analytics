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

log() {
  printf '[deploy-orchestrator] %s\n' "$*"
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

secret_exists() {
  local secret_name="$1"
  docker secret inspect "${secret_name}" >/dev/null 2>&1
}

create_secret_from_file_if_missing() {
  local secret_name="$1"
  local source_file="$2"

  if secret_exists "${secret_name}"; then
    log "Swarm secret already exists: ${secret_name}"
    return 0
  fi

  log "Creating Swarm secret: ${secret_name}"
  docker secret create "${secret_name}" "${source_file}" >/dev/null
}

create_secret_from_value_if_missing() {
  local secret_name="$1"
  local value="$2"

  if secret_exists "${secret_name}"; then
    log "Swarm secret already exists: ${secret_name}"
    return 0
  fi

  log "Creating Swarm secret: ${secret_name}"
  printf '%s' "${value}" | docker secret create "${secret_name}" - >/dev/null
}

secret_name_for_checksum() {
  local logical_name="$1"
  local checksum="$2"
  local environment_label

  case "${ENVIRONMENT_NAME:-}" in
    development|dev) environment_label="dev" ;;
    production|prod) environment_label="prod" ;;
    *) environment_label="env" ;;
  esac

  printf '%s_%s_%s_%s\n' "${STACK_NAME}" "${logical_name}" "${environment_label}" "${checksum:0:12}"
}

value_checksum() {
  local value="$1"
  printf '%s' "${value}" | sha256sum | awk '{print $1}'
}

prepare_swarm_secrets() {
  local env_file="$1"
  local render_env_file="$2"
  local app_env_checksum app_env_secret_name
  local api_token db_pass db_root_pass
  local api_token_secret_name db_pass_secret_name db_root_pass_secret_name

  app_env_checksum="$(dotenv_checksum_file "${env_file}")"
  app_env_secret_name="$(secret_name_for_checksum "app_env_payload" "${app_env_checksum}")"
  create_secret_from_file_if_missing "${app_env_secret_name}" "${env_file}"

  api_token="$(require_env_var MATOMO_API_TOKEN "${env_file}")"
  db_pass="$(require_env_var DB_PASS "${env_file}")"
  db_root_pass="$(require_env_var DB_ROOT_PASS "${env_file}")"

  api_token_secret_name="$(secret_name_for_checksum "api_token" "$(value_checksum "${api_token}")")"
  db_pass_secret_name="$(secret_name_for_checksum "db_password" "$(value_checksum "${db_pass}")")"
  db_root_pass_secret_name="$(secret_name_for_checksum "db_root_password" "$(value_checksum "${db_root_pass}")")"

  create_secret_from_value_if_missing "${api_token_secret_name}" "${api_token}"
  create_secret_from_value_if_missing "${db_pass_secret_name}" "${db_pass}"
  create_secret_from_value_if_missing "${db_root_pass_secret_name}" "${db_root_pass}"

  cp "${env_file}" "${render_env_file}"
  {
    printf '\n'
    printf 'MATOMO_APP_ENV_SECRET_NAME=%s\n' "${app_env_secret_name}"
    printf 'MATOMO_API_TOKEN_SECRET_NAME=%s\n' "${api_token_secret_name}"
    printf 'MATOMO_DB_PASSWORD_SECRET_NAME=%s\n' "${db_pass_secret_name}"
    printf 'MATOMO_DB_ROOT_PASSWORD_SECRET_NAME=%s\n' "${db_root_pass_secret_name}"
  } >> "${render_env_file}"

  log "Swarm secrets prepared from env checksum (${app_env_checksum:0:12})"
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

run_post_deploy_hooks() {
  local env_file="$1"

  wait_for_swarm_container matomo-app
  wait_for_swarm_container matomo-db

  log "Applying Matomo runtime config"
  ORCHESTRATOR_ENV_FILE="${env_file}" \
    DOCKER_RUNTIME_MODE=swarm \
    STACK_NAME="${STACK_NAME}" \
    bash "${SCRIPT_DIR}/apply-matomo-config.sh"
}

deploy_swarm() {
  local compose_file swarm_file raw_manifest deploy_manifest render_env_file

  compose_file="$(detect_compose_file)"
  swarm_file="docker-compose.swarm.yml"
  raw_manifest="$(mktemp "${PROJECT_ROOT}/.${STACK_NAME}.stack.raw.XXXXXX.yml")"
  deploy_manifest="$(mktemp "${PROJECT_ROOT}/.${STACK_NAME}.stack.deploy.XXXXXX.yml")"
  render_env_file="$(mktemp /dev/shm/matomo-render-env-XXXXXX)"
  chmod 600 "${render_env_file}"
  trap 'rm -f "${raw_manifest:-}" "${deploy_manifest:-}" "${render_env_file:-}"' RETURN

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
  prepare_swarm_secrets "${ENV_FILE}" "${render_env_file}"

  log "Rendering Swarm manifest (stack=${STACK_NAME}, env_file=${render_env_file})"
  docker compose --env-file "${render_env_file}" \
    -f "${compose_file}" \
    -f "${swarm_file}" \
    config > "${raw_manifest}"

  awk 'NR==1 && $1=="name:" {next} {print}' "${raw_manifest}" > "${deploy_manifest}"

  log "Deploying stack ${STACK_NAME}"
  docker stack deploy -c "${deploy_manifest}" "${STACK_NAME}"
  run_post_deploy_hooks "${ENV_FILE}"

  log "Swarm deploy completed"
}

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
