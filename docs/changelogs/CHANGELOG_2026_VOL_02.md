## 2026-04-26 — scripts refactoring step 4: autonomous env flow via SOPS

- **Context:** Активний том `VOL_01` досяг soft limit, тому нові записи продовжено у `VOL_02`. Крок 4 охоплює автономні скрипти, які запускаються поза CI/CD.
- **Verification:** `scripts/apply-matomo-config.sh` застосовано до активного Swarm stack `matomo` у `DOCKER_RUNTIME_MODE=swarm`; повторний прогін завершився успішно, `app_env_payload checksum is up to date`, restart не знадобився.
- **Verification:** Перевірено цільові Matomo config values у `config.ini.php`: `force_ssl=1`, `login_allow_signup=0`, `login_allow_reset_password=0`, `enable_browser_archiving_triggering=0`, `ignore_visits_do_not_track=1`, noreply email/name.
- **Verification:** SQL-перевірка `LoginOIDC` підтвердила ідемпотентність plugin settings: `allowSignup=0`, `autoLinking=1`, `userinfoId=email`, для кожного `cnt=1`.
- **Change:** Додано `scripts/lib/autonomous-env.sh`: визначає середовище через `--env dev|prod`, positional `dev|prod` або `SERVER_ENV`, розшифровує `env.<env>.enc` у `/dev/shm`, завантажує його через `source` як локально створений RAM-файл і очищає tmp-файл через `shred`/`rm`.
- **Change:** `scripts/backup.sh`, `scripts/restore.sh`, `scripts/test-restore.sh` переведено з `.env`/`ENV_FILE` на autonomous SOPS flow; бізнес-логіку dump/import/smoke restore не змінено.
- **Verification:** `bash -n` і `shellcheck` для autonomous helper/scripts пройшли успішно; `load_autonomous_env "$PWD" dev` успішно розшифрував `env.dev.enc` у `/dev/shm` без друку секретів; невідоме середовище `staging` у трьох скриптах повернуло очікуваний `exit 1`.
- **Note:** Реальні backup/restore не запускались у цій ітерації, щоб не змінювати production state; поточний активний runtime на сервері — Swarm, тоді як бізнес-логіка цих автономних скриптів залишилась compose-oriented згідно з обмеженням кроку міняти тільки env-блок.

## 2026-04-26 — autonomous scripts switched to Swarm runtime + scripts runbook

- **Context:** Після env-рефакторингу Категорії 2 потрібно було прибрати compose-only бізнес-логіку з автономних backup/restore скриптів і зафіксувати новий контракт у roadmap/runbook.
- **Change:** Додано `scripts/lib/docker-runtime.sh` з runtime abstraction для `DOCKER_RUNTIME_MODE=swarm|compose`; production default — `swarm`, `STACK_NAME=matomo`.
- **Change:** `scripts/backup.sh` тепер виконує MariaDB dump через running Swarm task `matomo_matomo-db` і читає root password з `/run/secrets/db_root_password`; compose fallback залишено тільки для локального dev.
- **Change:** `scripts/restore.sh` тепер виконує import і sanity query через Swarm runtime helper; destructive restore все ще потребує інтерактивного підтвердження або `--force`.
- **Change:** `docs/ROADMAP.md` оновлено: для autonomous scripts зафіксовано Swarm runtime як цільову production-логіку.
- **Change:** Додано `docs/scripts_runbook.md` за Koha-патерном: категорії 1а/1б/2, бізнес-логіка, manual execution, helper-и та out-of-scope файли.
- **Verification:** `bash -n` і `shellcheck` для всіх змінених shell-скриптів пройшли успішно; Swarm DB runtime перевірено read-only sanity query; `backup.sh --env dev --dry-run` і `test-restore.sh --env dev --dry-run` виконались успішно без dump/import/upload.

## 2026-04-26 — Swarm deploy manual secret refresh fixed

- **Root cause:** Ручний запуск `scripts/deploy-orchestrator-swarm.sh` без `INFRA_REPO_PATH` пропускав Ansible secrets refresh. `docker stack deploy` перезапускав сервіси зі старим external secret `app_env_payload`, тому checksum у `apply-matomo-config.sh` лишався відмінним навіть після `service update --force`.
- **Fix:** `scripts/deploy-orchestrator-swarm.sh` тепер сам створює checksum-versioned Docker secrets з розшифрованого env-файлу (`app_env_payload`, `matomo_api_token`, `db_password`, `db_root_password`) і рендерить Swarm manifest через тимчасовий env-файл з актуальними secret names.
- **Verification:** Повторено ручну команду з `docs/scripts_runbook.md`: deploy завершився успішно, `app_env_payload checksum synchronized after restart`, Matomo config застосовано. Повторний прямий `apply-matomo-config.sh` із SOPS temp env показав `app_env_payload checksum is up to date`.

## 2026-05-07 — Swarm versioned secrets renderer extracted

- **Change:** Додано `scripts/render-versioned-env-secret.sh` за DSpace-патерном: скрипт створює або перевикористовує immutable Docker secrets для `app_env_payload`, `matomo_api_token`, `db_password`, `db_root_password` і записує generated `MATOMO_*_SECRET_NAME` у render env-файл.
- **Change:** `scripts/deploy-orchestrator-swarm.sh` більше не містить inline-логіку створення versioned secrets; Swarm deploy викликає renderer перед `docker compose config`.
- **Verification:** `bash -n` і `shellcheck` для змінених shell-скриптів пройшли успішно. Ізольований прогін renderer з тимчасовим `docker` stub на `.env.example` підтвердив 12-символьні SHA256 hash suffix для всіх чотирьох secrets і запис generated names у render env-файл; `docker compose config` підтвердив підстановку versioned external secret names у Swarm manifest.

## 2026-05-07 — Swarm deploy temp manifests cleanup

- **Change:** `scripts/deploy-orchestrator-swarm.sh` отримав глобальний `cleanup` з `trap cleanup EXIT`, який прибирає активні тимчасові raw/deploy manifests і runtime render env-файл незалежно від коду виходу.
- **Change:** Cleanup додатково видаляє stale manifests у корені проєкту за шаблонами поточного `STACK_NAME`: `.${STACK_NAME}.stack.raw.*.yml` і `.${STACK_NAME}.stack.deploy.*.yml`.
- **Verification:** `bash -n`, `shellcheck` і `ORCHESTRATOR_MODE=noop scripts/deploy-orchestrator-swarm.sh` пройшли успішно; smoke-перевірка з тестовими `.matomo.stack.*.yml` підтвердила видалення stale manifests через `trap cleanup EXIT`.

## 2026-05-07 — init-volumes backup directory permissions fixed

- **Fix:** `scripts/init-volumes.sh` тепер ініціалізує `BACKUP_DIR` окремим кроком і намагається застосувати `chown/chmod 750` через ephemeral Docker container з `BACKUP_UID/BACKUP_GID` fallback на поточного користувача.
- **Fix:** Нормалізація прав `BACKUP_DIR` стала fail-soft: якщо host або helper container повертає `Operation not permitted`, скрипт друкує warning і продовжує deploy, бо директорія вже існує.
- **Context:** Swarm deploy падав на host-side `chmod 750 "$BACKUP_DIR"` для `/data/backup/matomo` з `Operation not permitted`; тепер deploy-adjacent hook не блокує деплой через неможливість змінити mode backup-директорії.
- **Verification:** `bash -n` і `shellcheck` для `scripts/init-volumes.sh`/`scripts/deploy-orchestrator-swarm.sh` пройшли успішно; smoke-test з docker-stub, який повертає `Operation not permitted` для `BACKUP_DIR`, завершився `exit 0` і створив backup-директорію.

## 2026-05-07 — Matomo writable volume permissions normalized after deploy

- **Fix:** `scripts/init-volumes.sh` отримав режим `--matomo-only`, який створює `tmp/assets`, `tmp/cache`, `tmp/logs`, `tmp/tcpdf`, `tmp/templates_c`, виставляє `www-data:www-data` для всього `VOL_MATOMO_DATA` і нормалізує `tmp` directories/files до `755/644`.
- **Fix:** `scripts/deploy-orchestrator-swarm.sh` після старту `matomo-app`/`matomo-db` повторно запускає `init-volumes.sh --matomo-only`, щоб виправити файли, які офіційний Matomo image створив у `/var/www/html` уже після pre-deploy bootstrap.
- **Context:** Після успішного deploy вебсторінка падала з `Matomo couldn't write to some directories (running as user 'www-data')`.
- **Verification:** `bash -n` і `shellcheck` для `scripts/init-volumes.sh`/`scripts/deploy-orchestrator-swarm.sh` пройшли успішно; `scripts/init-volumes.sh --env-file .env.example --matomo-only --dry-run` показав тільки Matomo writable directory bootstrap без DB/backup змін.

## 2026-05-07 — Swarm Matomo database env mapping fixed

- **Fix:** `docker-compose.swarm.yml` тепер після читання `app_env_payload` мапить `DB_*` у змінні офіційного Matomo image: `MATOMO_DATABASE_HOST=matomo-db`, `MATOMO_DATABASE_ADAPTER=mysql`, `MATOMO_DATABASE_TABLES_PREFIX`, `MATOMO_DATABASE_USERNAME`, `MATOMO_DATABASE_PASSWORD`, `MATOMO_DATABASE_DBNAME`.
- **Context:** У Swarm override `environment` скидається, тому Matomo UI bootstrap не бачив DB connection env і ручне введення `127.0.0.1` завершувалось `SQLSTATE[HY000] [2002] Connection refused`.
- **Verification:** `docker compose --env-file .env.example -f docker-compose.yml -f docker-compose.swarm.yml config` підтвердив runtime `MATOMO_DATABASE_*` exports без підстановки `DB_PASS` у manifest; `bash -n` і `shellcheck` для deploy/init scripts пройшли успішно.
