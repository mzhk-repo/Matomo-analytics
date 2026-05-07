#!/usr/bin/env bash
# Helper для автономних scripts: SERVER_ENV/--env -> env.<env>.enc -> /dev/shm.

AUTONOMOUS_ENV_TMP=""
AUTONOMOUS_ENVIRONMENT=""

autonomous_env_log() {
  printf '[autonomous-env] %s\n' "$*" >&2
}

autonomous_env_die() {
  autonomous_env_log "ERROR: $*"
  exit 1
}

cleanup_autonomous_env() {
  if [[ -n "${AUTONOMOUS_ENV_TMP:-}" && -f "${AUTONOMOUS_ENV_TMP}" ]]; then
    if command -v shred >/dev/null 2>&1; then
      shred -u "${AUTONOMOUS_ENV_TMP}" 2>/dev/null || rm -f "${AUTONOMOUS_ENV_TMP}"
    else
      rm -f "${AUTONOMOUS_ENV_TMP}"
    fi
  fi
}

resolve_autonomous_environment() {
  local raw="${1:-${SERVER_ENV:-}}"

  case "${raw}" in
    dev|development) printf 'dev' ;;
    prod|production) printf 'prod' ;;
    "") autonomous_env_die "environment is not set. Set SERVER_ENV in /etc/environment or pass --env dev|prod." ;;
    *) autonomous_env_die "unsupported environment: ${raw}. Expected dev|development|prod|production." ;;
  esac
}

decrypt_autonomous_env() {
  local enc_file="$1"

  command -v sops >/dev/null 2>&1 || autonomous_env_die "sops is required"
  [[ -f "${enc_file}" ]] || autonomous_env_die "encrypted env file not found: ${enc_file}"
  [[ -d /dev/shm ]] || autonomous_env_die "/dev/shm is required for decrypted env"

  AUTONOMOUS_ENV_TMP="$(mktemp /dev/shm/env-XXXXXX)"
  chmod 600 "${AUTONOMOUS_ENV_TMP}"
  sops --decrypt --input-type dotenv --output-type dotenv "${enc_file}" > "${AUTONOMOUS_ENV_TMP}"
}

load_autonomous_env() {
  local project_root="$1"
  local environment_arg="${2:-}"
  local enc_file

  AUTONOMOUS_ENVIRONMENT="$(resolve_autonomous_environment "${environment_arg}")"
  enc_file="${project_root}/env.${AUTONOMOUS_ENVIRONMENT}.enc"

  trap cleanup_autonomous_env EXIT
  decrypt_autonomous_env "${enc_file}"

  autonomous_env_log "Loading env.${AUTONOMOUS_ENVIRONMENT}.enc from /dev/shm"
  set -a
  # shellcheck source=/dev/null
  . "${AUTONOMOUS_ENV_TMP}"
  set +a
}
