#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SWARM_MODE=0
RENDER_ONLY=0
STACK_NAME="${STACK_NAME:-matomo}"
KEEP_RENDERED_MANIFEST="${KEEP_RENDERED_MANIFEST:-0}"
RENDERED_RAW_FILE=""
RENDERED_DEPLOY_FILE=""

log() {
  printf '[deploy-orchestrator] %s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy-orchestrator.sh [--swarm [STACK_NAME]] [--render-only]

Modes:
  default                Local compose bootstrap workflow (backward compatible).
  --swarm [STACK_NAME]   Render merged compose for Swarm and deploy via docker stack.
  --render-only          Only render Swarm deploy manifest (implies --swarm), no deploy.

Env:
  STACK_NAME               Optional default stack name (default: matomo)
  KEEP_RENDERED_MANIFEST   1 -> keep /tmp/<stack>.stack.{raw,deploy}.yml after run
EOF
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

cleanup_rendered_files() {
  if [[ "${KEEP_RENDERED_MANIFEST}" != "1" ]]; then
    [[ -n "${RENDERED_RAW_FILE}" ]] && rm -f "${RENDERED_RAW_FILE}" || true
    [[ -n "${RENDERED_DEPLOY_FILE}" ]] && rm -f "${RENDERED_DEPLOY_FILE}" || true
  fi
}

render_swarm_manifest() {
  local compose_file="$1"
  local swarm_file="$2"
  local stack_name="$3"

  RENDERED_RAW_FILE="/tmp/${stack_name}.stack.raw.yml"
  RENDERED_DEPLOY_FILE="/tmp/${stack_name}.stack.deploy.yml"

  log "Rendering merged compose for Swarm"
  docker compose -f "${compose_file}" -f "${swarm_file}" config > "${RENDERED_RAW_FILE}"

  # docker stack deploy may reject top-level `name` from compose v2.
  awk 'NR==1 && $1=="name:" {next} {print}' "${RENDERED_RAW_FILE}" > "${RENDERED_DEPLOY_FILE}"

  # Swarm expects integer `published` ports and does not accept `host_ip`.
  sed -i -E 's/(published: )"([0-9]+)"/\1\2/g' "${RENDERED_DEPLOY_FILE}"
  sed -i '/host_ip:/d' "${RENDERED_DEPLOY_FILE}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --swarm)
      SWARM_MODE=1
      if [[ $# -gt 1 && "${2}" != --* ]]; then
        STACK_NAME="$2"
        shift
      fi
      ;;
    --render-only)
      SWARM_MODE=1
      RENDER_ONLY=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

trap cleanup_rendered_files EXIT

cd "${PROJECT_ROOT}"

if [[ -x "./scripts/verify-env.sh" ]]; then
  log "Running verify-env.sh"
  bash ./scripts/verify-env.sh .env
else
  log "verify-env.sh not found, skipping"
fi

if [[ -x "./scripts/init-volumes.sh" ]]; then
  log "Running init-volumes.sh"
  bash ./scripts/init-volumes.sh .env
else
  log "init-volumes.sh not found, skipping"
fi

compose_file="$(detect_compose_file)"
if [[ -z "${compose_file}" ]]; then
  log "No compose file found"
  exit 1
fi

if [[ "${SWARM_MODE}" == "1" ]]; then
  swarm_file="docker-compose.swarm.yml"
  if [[ ! -f "${swarm_file}" ]]; then
    log "Missing ${swarm_file} for Swarm deployment"
    exit 1
  fi

  render_swarm_manifest "${compose_file}" "${swarm_file}" "${STACK_NAME}"
  log "Rendered manifest: ${RENDERED_DEPLOY_FILE}"

  if [[ "${RENDER_ONLY}" == "1" ]]; then
    log "Render-only mode enabled, skipping docker stack deploy"
  else
    log "Deploying stack '${STACK_NAME}' via rendered Swarm manifest"
    docker stack deploy -c "${RENDERED_DEPLOY_FILE}" "${STACK_NAME}"
  fi

  log "Swarm mode: apply-matomo-config.sh skipped (compose-only script)"
  log "Orchestration script completed"
  exit 0
fi

if [[ -x "./scripts/apply-matomo-config.sh" ]]; then
  if ! docker compose -f "${compose_file}" ps matomo-app >/dev/null 2>&1; then
    log "matomo-app is not running yet; starting stack once for config bootstrap"
    docker compose -f "${compose_file}" up -d --remove-orphans
  fi
  log "Running apply-matomo-config.sh"
  bash ./scripts/apply-matomo-config.sh .env
else
  log "apply-matomo-config.sh not found, skipping"
fi

log "Orchestration script completed"
