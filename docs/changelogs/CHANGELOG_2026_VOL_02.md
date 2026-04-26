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
