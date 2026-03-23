#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

if [[ -x "./scripts/apply-matomo-config.sh" ]]; then
  compose_file="$(detect_compose_file)"
  if [[ -z "${compose_file}" ]]; then
    log "No compose file found, skipping apply-matomo-config.sh"
  else
    if ! docker compose -f "${compose_file}" ps matomo-app >/dev/null 2>&1; then
      log "matomo-app is not running yet; starting stack once for config bootstrap"
      docker compose -f "${compose_file}" up -d --remove-orphans
    fi
    log "Running apply-matomo-config.sh"
    bash ./scripts/apply-matomo-config.sh .env
  fi
else
  log "apply-matomo-config.sh not found, skipping"
fi

log "Orchestration script completed"
