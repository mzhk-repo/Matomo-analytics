# Runbook: scripts (Matomo Analytics)

## Env-контракти

- CI/CD decrypt flow: shared workflow розшифровує `env.dev.enc` або `env.prod.enc` у тимчасовий dotenv-файл і передає шлях через `ORCHESTRATOR_ENV_FILE`.
- Deploy-adjacent flow: скрипти Категорії 1б читають `ORCHESTRATOR_ENV_FILE` або явний `--env-file` через `scripts/lib/orchestrator-env.sh` без `source`/`eval`.
- Autonomous flow: cron/manual скрипти читають `SERVER_ENV` (`dev|prod`) або аргумент `--env dev|prod`, розшифровують `env.<env>.enc` у `/dev/shm` через `scripts/lib/autonomous-env.sh` і очищають tmp-файл після завершення.
- Runtime flow: production default для автономних скриптів — `DOCKER_RUNTIME_MODE=swarm`, `STACK_NAME=matomo`. Compose fallback лишається для локального dev через `DOCKER_RUNTIME_MODE=compose`.
- Локальний fallback на `.env` дозволений тільки для deploy-adjacent скриптів, коли `ORCHESTRATOR_ENV_FILE` не передано.

## Категорія 1а: validation

### `scripts/verify-env.sh`

#### Бізнес-логіка

- Перевіряє наявність і заповненість required env-змінних.
- Валідує числові пороги `BACKUP_RETENTION_DAYS`, `DISK_WARN_THRESHOLD`, `DISK_CRIT_THRESHOLD`.
- Legacy validation-скрипт: `source` тут дозволений scope-правилами.

#### Manual execution

```bash
bash scripts/verify-env.sh .env
```

### `scripts/check-ports-policy.sh`

#### Бізнес-логіка

- Перевіряє compose-файл на заборонені `ports:` секції.
- Використовується як pre-deploy policy check до render/deploy.
- Не читає секрети.

#### Manual execution

```bash
bash scripts/check-ports-policy.sh docker-compose.yml
```

### `scripts/check-disk.sh`

#### Бізнес-логіка

- Перевіряє disk usage для `VOL_DB_PATH`, `VOL_MATOMO_DATA`, `BACKUP_DIR`.
- Не читає env-файл і не виконує `source`; очікує, що змінні вже експортовані caller-ом.
- Підходить для ручного runtime health check або cron/monitoring wrapper.

#### Manual execution

```bash
VOL_DB_PATH=/srv/Matomo/.data/db \
VOL_MATOMO_DATA=/srv/Matomo/.data/matomo \
BACKUP_DIR=/srv/Matomo/.backups \
DISK_WARN_THRESHOLD=80 \
DISK_CRIT_THRESHOLD=90 \
bash scripts/check-disk.sh
```

## Категорія 1б: deploy-adjacent

### `scripts/deploy-orchestrator-swarm.sh`

#### Бізнес-логіка

- Основний Swarm orchestrator для CI/CD.
- Порядок фаз: validation -> optional Ansible secrets refresh -> `init-volumes.sh` -> render merged manifest -> `docker stack deploy` -> `apply-matomo-config.sh`.
- Якщо `INFRA_REPO_PATH` не заданий, orchestrator сам створює checksum-versioned Docker secrets з розшифрованого env-файлу і рендерить manifest з цими secret names. Це потрібно, бо Docker secrets immutable.
- Render виконується через `docker compose --env-file ... config`, після чого прибирається top-level `name:`.
- Post-deploy чекає running containers `matomo-app` і `matomo-db`, потім застосовує Matomo runtime config у Swarm mode.

#### Manual execution

```bash
ENV_TMP="$(mktemp /dev/shm/env-XXXXXX)"
chmod 600 "${ENV_TMP}"
sops --decrypt --input-type dotenv --output-type dotenv env.dev.enc > "${ENV_TMP}"

ORCHESTRATOR_MODE=swarm \
ENVIRONMENT_NAME=development \
STACK_NAME=matomo \
ORCHESTRATOR_ENV_FILE="${ENV_TMP}" \
bash scripts/deploy-orchestrator-swarm.sh

shred -u "${ENV_TMP}" 2>/dev/null || rm -f "${ENV_TMP}"
```

#### No-op smoke

```bash
ORCHESTRATOR_MODE=noop bash scripts/deploy-orchestrator-swarm.sh
```

### `scripts/init-volumes.sh`

#### Бізнес-логіка

- Створює bind-mount директорії для MariaDB data, Matomo data і backup.
- Ініціалізує Matomo writable `tmp/*` каталоги.
- Нормалізує ownership через ephemeral Docker containers.
- Читає env через `ORCHESTRATOR_ENV_FILE` або `--env-file` без `source`.

#### Manual execution

```bash
ENV_TMP="$(mktemp /dev/shm/env-XXXXXX)"
chmod 600 "${ENV_TMP}"
sops --decrypt --input-type dotenv --output-type dotenv env.dev.enc > "${ENV_TMP}"

ORCHESTRATOR_ENV_FILE="${ENV_TMP}" bash scripts/init-volumes.sh --dry-run
ORCHESTRATOR_ENV_FILE="${ENV_TMP}" bash scripts/init-volumes.sh

shred -u "${ENV_TMP}" 2>/dev/null || rm -f "${ENV_TMP}"
```

### `scripts/apply-matomo-config.sh`

#### Бізнес-логіка

- Ідемпотентно застосовує Matomo config через `php console config:set`.
- Налаштовує privacy/security keys, browser archiving, SMTP і LoginOIDC plugin settings.
- У Swarm mode порівнює normalized checksum вхідного env з `/run/secrets/app_env_payload` у `matomo-app`.
- Якщо checksum відрізняється, виконує `docker service update --force` для `matomo-app` і `matomo-cron`, чекає новий container id і повторно звіряє checksum.
- Не друкує секретні значення SMTP password.

#### Manual execution

```bash
ENV_TMP="$(mktemp /dev/shm/env-XXXXXX)"
chmod 600 "${ENV_TMP}"
sops --decrypt --input-type dotenv --output-type dotenv env.dev.enc > "${ENV_TMP}"

ORCHESTRATOR_ENV_FILE="${ENV_TMP}" \
DOCKER_RUNTIME_MODE=swarm \
STACK_NAME=matomo \
bash scripts/apply-matomo-config.sh

shred -u "${ENV_TMP}" 2>/dev/null || rm -f "${ENV_TMP}"
```

#### Local compose fallback

```bash
DOCKER_RUNTIME_MODE=compose bash scripts/apply-matomo-config.sh --env-file .env
```

## Категорія 2: autonomous

### `scripts/backup.sh`

#### Бізнес-логіка

- Створює MariaDB dump через Swarm runtime (`matomo_matomo-db` running task), стискає у `.sql.gz`.
- Завантажує backup у `RCLONE_REMOTE:RCLONE_DEST_PATH`.
- Видаляє локальні backup-файли старші за `BACKUP_RETENTION_DAYS`.
- Публікує textfile metrics для VictoriaMetrics/Grafana.
- Env завантажується через `SERVER_ENV`/`--env` + SOPS `/dev/shm`.

#### Manual execution

```bash
SERVER_ENV=dev bash scripts/backup.sh --dry-run
SERVER_ENV=prod bash scripts/backup.sh

bash scripts/backup.sh --env dev --dry-run
bash scripts/backup.sh --env prod
```

#### Runtime override

```bash
DOCKER_RUNTIME_MODE=compose bash scripts/backup.sh --env dev --dry-run
```

### `scripts/restore.sh`

#### Бізнес-логіка

- Відновлює `.sql` або `.sql.gz` dump у Matomo DB через Swarm runtime.
- Має інтерактивне підтвердження; non-interactive запуск потребує `--force`.
- Після імпорту виконує sanity query `SHOW TABLES`.
- Env завантажується через `SERVER_ENV`/`--env` + SOPS `/dev/shm`.

#### Manual execution

```bash
bash scripts/restore.sh --help

SERVER_ENV=prod bash scripts/restore.sh /srv/Matomo/.backups/matomo_matomo_<timestamp>.sql.gz
bash scripts/restore.sh --env prod --force /srv/Matomo/.backups/matomo_matomo_<timestamp>.sql.gz
```

### `scripts/test-restore.sh`

#### Бізнес-логіка

- Виконує smoke restore в ізольований тимчасовий MariaDB контейнер, не в production DB.
- Якщо backup path не передано, бере найновіший `.sql`/`.sql.gz` з `BACKUP_DIR`.
- Публікує textfile metrics `matomo_restore_smoke_*`.
- Env завантажується через `SERVER_ENV`/`--env` + SOPS `/dev/shm`.

#### Manual execution

```bash
SERVER_ENV=dev bash scripts/test-restore.sh --dry-run
SERVER_ENV=prod bash scripts/test-restore.sh

bash scripts/test-restore.sh --env prod /srv/Matomo/.backups/matomo_matomo_<timestamp>.sql.gz
```

## Helpers

### `scripts/lib/orchestrator-env.sh`

#### Бізнес-логіка

- Спільний helper для Категорії 1б.
- Надає `resolve_orchestrator_env_file`, `read_env_var`, `require_env_var`, `dotenv_checksum_file`.
- Не виконує env-файл як shell-код.

#### Manual execution

```bash
bash -lc 'source scripts/lib/orchestrator-env.sh; dotenv_checksum_file .env.example >/dev/null; echo ok'
```

### `scripts/lib/autonomous-env.sh`

#### Бізнес-логіка

- Спільний helper для Категорії 2.
- Визначає середовище через `--env`/positional env/`SERVER_ENV`.
- Розшифровує `env.<env>.enc` у `/dev/shm` і очищає tmp-файл при exit.

#### Manual execution

```bash
bash -lc 'source scripts/lib/autonomous-env.sh; load_autonomous_env "$PWD" dev; echo "$AUTONOMOUS_ENVIRONMENT"'
```

### `scripts/lib/docker-runtime.sh`

#### Бізнес-логіка

- Спільний helper для запуску команд у `compose` або `swarm`.
- За замовчуванням використовує `DOCKER_RUNTIME_MODE=swarm` і `STACK_NAME=matomo`.
- Надає runtime exec і MariaDB dump/import/sanity wrappers.

#### Manual execution

```bash
bash -lc 'source scripts/lib/docker-runtime.sh; docker_runtime_service_accessible matomo-db; echo ok'
```

## Out of scope

### `scripts/deploy-orchestrator.sh`

Legacy orchestrator. Залишається без змін.

### `scripts/validate_sops_encrypted.py`

SOPS validation helper. Залишається без змін.
