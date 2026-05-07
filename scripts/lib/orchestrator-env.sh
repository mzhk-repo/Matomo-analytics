#!/usr/bin/env bash
# Helper для deploy-adjacent скриптів: читає dotenv без source/eval.

orchestrator_env_log() {
  printf '[orchestrator-env] %s\n' "$*" >&2
}

orchestrator_env_die() {
  orchestrator_env_log "ERROR: $*"
  exit 1
}

resolve_orchestrator_env_file() {
  local project_root="$1"
  local explicit_file="${2:-}"
  local env_file=""

  if [[ -n "${explicit_file}" ]]; then
    env_file="${explicit_file}"
  elif [[ -n "${ORCHESTRATOR_ENV_FILE:-}" ]]; then
    env_file="${ORCHESTRATOR_ENV_FILE}"
  elif [[ -f "${project_root}/.env" ]]; then
    env_file="${project_root}/.env"
    orchestrator_env_log "WARNING: ORCHESTRATOR_ENV_FILE не передано. Fallback на локальний .env — тільки для dev-середовища."
  else
    orchestrator_env_die "env file не знайдено. Передай ORCHESTRATOR_ENV_FILE або --env-file, або поклади .env для локального dev."
  fi

  [[ -f "${env_file}" ]] || orchestrator_env_die "env file не знайдено: ${env_file}"
  printf '%s\n' "${env_file}"
}

read_env_var() {
  local key="$1"
  local file="$2"
  local line value

  [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || orchestrator_env_die "invalid env key: ${key}"
  [[ -f "${file}" ]] || orchestrator_env_die "env file не знайдено: ${file}"

  line="$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "${file}" || true)"
  [[ -n "${line}" ]] || return 0

  line="${line#export }"
  value="${line#*=}"
  value="$(printf '%s' "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s\n' "${value}"
}

require_env_var() {
  local key="$1"
  local file="$2"
  local value

  value="$(read_env_var "${key}" "${file}")"
  [[ -n "${value}" ]] || orchestrator_env_die "missing variable in ${file}: ${key}"
  printf '%s\n' "${value}"
}

normalize_dotenv_stream() {
  awk '
    {
      sub(/\r$/, "")
    }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    {
      sub(/^[[:space:]]*export[[:space:]]+/, "")
      if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
        print
      }
    }
  ' | sort
}

dotenv_checksum_file() {
  local file="$1"

  [[ -f "${file}" ]] || orchestrator_env_die "env file не знайдено: ${file}"
  normalize_dotenv_stream < "${file}" | sha256sum | awk '{print $1}'
}
