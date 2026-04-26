#!/usr/bin/env bash
# Helper для запуску команд у сервісах Compose або Swarm.

DOCKER_RUNTIME_MODE="${DOCKER_RUNTIME_MODE:-swarm}"
STACK_NAME="${STACK_NAME:-matomo}"

docker_runtime_log() {
  printf '[docker-runtime] %s\n' "$*" >&2
}

docker_runtime_die() {
  docker_runtime_log "ERROR: $*"
  exit 1
}

docker_runtime_container_id() {
  local service="$1"
  local service_name="${STACK_NAME}_${service}"
  local container_id

  container_id="$(docker ps \
    --filter "label=com.docker.swarm.service.name=${service_name}" \
    --filter "status=running" \
    --format '{{.ID}}' | head -n1)"
  [[ -n "${container_id}" ]] || return 1
  printf '%s\n' "${container_id}"
}

docker_runtime_service_accessible() {
  local service="$1"

  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      docker compose ps "${service}" >/dev/null 2>&1
      ;;
    swarm)
      docker_runtime_container_id "${service}" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

docker_runtime_exec() {
  local service="$1"
  shift

  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      docker compose exec -T "${service}" "$@"
      ;;
    swarm)
      local container_id
      container_id="$(docker_runtime_container_id "${service}")" || docker_runtime_die "running container not found for ${STACK_NAME}_${service}"
      docker exec -i "${container_id}" "$@"
      ;;
    *)
      docker_runtime_die "unsupported DOCKER_RUNTIME_MODE=${DOCKER_RUNTIME_MODE}"
      ;;
  esac
}

docker_runtime_db_dump() {
  local db_name="$1"
  local db_root_pass="${2:-}"

  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      MYSQL_PWD="${db_root_pass}" docker compose exec -T matomo-db \
        mariadb-dump -uroot --single-transaction --quick --lock-tables=false "${db_name}"
      ;;
    swarm)
      # shellcheck disable=SC2016
      docker_runtime_exec matomo-db sh -lc '
        db_name="$1"
        MYSQL_PWD="$(cat /run/secrets/db_root_password)"
        export MYSQL_PWD
        exec mariadb-dump -uroot --single-transaction --quick --lock-tables=false "$db_name"
      ' sh "${db_name}"
      ;;
    *)
      docker_runtime_die "unsupported DOCKER_RUNTIME_MODE=${DOCKER_RUNTIME_MODE}"
      ;;
  esac
}

docker_runtime_db_import() {
  local db_name="$1"
  local db_root_pass="${2:-}"

  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      MYSQL_PWD="${db_root_pass}" docker compose exec -T matomo-db mariadb -uroot "${db_name}"
      ;;
    swarm)
      # shellcheck disable=SC2016
      docker_runtime_exec matomo-db sh -lc '
        db_name="$1"
        MYSQL_PWD="$(cat /run/secrets/db_root_password)"
        export MYSQL_PWD
        exec mariadb -uroot "$db_name"
      ' sh "${db_name}"
      ;;
    *)
      docker_runtime_die "unsupported DOCKER_RUNTIME_MODE=${DOCKER_RUNTIME_MODE}"
      ;;
  esac
}

docker_runtime_db_sanity() {
  local db_name="$1"
  local db_root_pass="${2:-}"

  case "${DOCKER_RUNTIME_MODE}" in
    compose)
      MYSQL_PWD="${db_root_pass}" docker compose exec -T matomo-db mariadb -uroot -e "USE ${db_name}; SHOW TABLES;" >/dev/null
      ;;
    swarm)
      # shellcheck disable=SC2016
      docker_runtime_exec matomo-db sh -lc '
        db_name="$1"
        MYSQL_PWD="$(cat /run/secrets/db_root_password)"
        export MYSQL_PWD
        exec mariadb -uroot -e "USE \`${db_name}\`; SHOW TABLES;"
      ' sh "${db_name}" >/dev/null
      ;;
    *)
      docker_runtime_die "unsupported DOCKER_RUNTIME_MODE=${DOCKER_RUNTIME_MODE}"
      ;;
  esac
}
