## 2026-03-17 — IaC for LoginOIDC settings (env + apply script)

- **Context:** Після стабілізації SSO потрібно було прибрати ручні SQL-кроки й зафіксувати OIDC-параметри як IaC.
- **Change:** Оновлено `.env` і `.env.example`: додано `MATOMO_CFG_OIDC_ALLOW_SIGNUP`, `MATOMO_CFG_OIDC_AUTO_LINKING`, `MATOMO_CFG_OIDC_USERINFO_ID`.
- **Change:** Оновлено `scripts/apply-matomo-config.sh`: додано застосування `LoginOIDC` settings у `matomo_plugin_setting` через ідемпотентний `UPDATE + conditional INSERT` (scope `user_login=''`).
- **Fix:** Усунено дублювання рядків у `matomo_plugin_setting` для `LoginOIDC` (allowSignup/autoLinking/userinfoId); виконано dedupe на наявних даних.
- **Verification:** Подвійний запуск `./scripts/apply-matomo-config.sh .env` не створює дублікатів; для кожного з 3 ключів `COUNT(*)=1`, значення: `allowSignup=0`, `autoLinking=1`, `userinfoId=email`.

## 2026-03-17 — OIDC login fix for pre-invited users (Entra) — v2

- **Context:** Після першого фіксу (`userinfoId=preferred_username`) помилка змінилась на `Unexpected response from OAuth service.`
- **Root cause (v2):** Microsoft Graph `/oidc/userinfo` не повертає поле `preferred_username` (тільки `sub`, `name`, `family_name`, `given_name`, `email`). Тому `$result->preferred_username = null` → `InvalidResponse`.
- **Fix:** У `matomo_plugin_setting` для `LoginOIDC` змінено `userinfoId` на `email` (залишено `autoLinking=1`, `allowSignup=0`), очищено кеш.
- **Verification:** SQL-перевірка підтверджує `userinfoId=email`, `autoLinking=1`, `allowSignup=0`.
- **Change:** Оновлено `docs/deployment.md` з поясненням яке поле повертає Graph userinfo endpoint.

## 2026-03-17 — SMTP test email verified (MS365)

- **Context:** Після IaC-конфігурації SMTP потрібно було підтвердити фактичну доставку.
- **Verification:** Виконано `php console core:test-email m.zhuk@ldubgd.edu.ua` у `matomo-app`; SMTP-сесія до `outlook.office365.com` завершилась успішно: `AUTH LOGIN -> 235`, `RCPT TO -> 250`, `DATA -> 250 2.0.0 OK`, фінальне повідомлення `Message sent to m.zhuk@ldubgd.edu.ua`.
- **Result:** Вихідна пошта Matomo через MS365 працює.

## 2026-03-17 — MS365 SMTP configured via IaC script

- **Context:** Потрібно увімкнути SMTP для Matomo (MS365) без ручних правок у UI/config.
- **Change:** Оновлено `scripts/apply-matomo-config.sh`: додано env-driven налаштування секції `[mail]` (`transport`, `host`, `port`, `type`, `encryption`, `username`, `password`) з використанням `SMTP_USER`/`SMTP_PASS`; додано безпечне маскування секретних значень у логах.
- **Change:** Оновлено `.env.example` (додані `SMTP_USER`, `SMTP_PASS` і `MATOMO_CFG_SMTP_*` overrides) та `docs/deployment.md` (примітка про SMTP-передумови).
- **Verification:** `./scripts/apply-matomo-config.sh .env` виконано успішно; `config/config.ini.php` містить `[mail]` з `smtp.office365.com:587`, `type=Login`, `encryption=tls`, `username=<SMTP_USER>`, а також `General.noreply_email_address`/`noreply_email_name`.

## 2026-03-17 — local_admin removed (fallback account cleanup)

- **Context:** За запитом прибрано зайвий локальний fallback-акаунт `local_admin`.
- **Change:** Виконано `UsersManager.deleteUser` через Matomo API (POST) з валідним `TOKEN_AUTH`.
- **Verification:** `UsersManager.getUsersLogin` більше не повертає `local_admin`.
- **Risks:** Локальний вхід тепер залежить від `admin`/SSO-акаунтів; перед подальшими змінами доступів бажано перевірити робочий SSO login.

## 2026-03-17 — Local login 403 fixed (Matomo password hash format mismatch)

- **Context:** Локальний вхід (`module=Login`) повертав `HTTP 403` і `Wrong username and/or password`, хоча пароль в БД виглядав валідним.
- **Root cause:** Для Matomo 5 локальна автентифікація очікує формат `password_verify(md5(password), stored_hash)`. Раніше для `admin/local_admin` було збережено хеш у форматі `password_hash(password)`, через що вхід завжди відхилявся.
- **Fix:** Паролі `admin` і `local_admin` оновлено у правильному форматі `password_hash(md5(<plain>))`; очищено lockout state (`login:unblock-blocked-ips`, `TRUNCATE matomo_brute_force_log`) і кеші Matomo.
- **Verification:** Контрольний POST на `/?module=Login` повертає `HTTP/1.1 302 Found` з `Location: https://matomo.pinokew.buzz/` для `admin` + `very_secure_password`.
- **Change:** Оновлено `docs/deployment.md` (runbook fallback) з явною приміткою про правильний формат хешу для ручного recovery.

## 2026-03-17 — UsersManager API provisioning validated (inviteUser for m.zhuk)

- **Context:** Потрібно було відмовитись від технічного SQL-підходу як основного і перейти на штатний Matomo UsersManager API.
- **Change:** Через `TOKEN_AUTH` (POST API) виконано `UsersManager.deleteUser` для попереднього запису та `UsersManager.inviteUser` для `m.zhuk@ldubgd.edu.ua` з `initialIdSite=1`.
- **Verification:** У БД користувач `m.zhuk@ldubgd.edu.ua` існує як звичайний invited user: `superuser_access=0`, `invite_token` заповнений, `invite_accept_at=NULL`.
- **Change:** Оновлено `docs/deployment.md` (розділ `11.6`) на API-first runbook: `inviteUser`/`setSuperUserAccess`/валідація, окремо зафіксовано вимогу POST і `initialIdSite` для не-superuser токенів.
- **Rollback:** Для скасування запрошення видалити користувача через `UsersManager.deleteUser`.

## 2026-03-17 — Superuser provisioning runbook added + two admin accounts created

- **Context:** Для завершення SSO rollout потрібно було підготувати цільові облікові записи адміністраторів і зафіксувати відтворювану інструкцію на майбутнє.
- **Change:** У Matomo створено/оновлено два облікові записи з `superuser_access=1`: `m.zhuk@ldubgd.edu.ua`, `b.filipchuk@ldubgd.edu.ua`.
- **Change:** Оновлено `docs/deployment.md` (розділ `11.6`) — додано runbook створення користувачів і надання прав superuser (UI-first + CLI/DB fallback + валідація).
- **Verification:** SQL-перевірка таблиці `matomo_user` підтверджує наявність `admin`, `m.zhuk@ldubgd.edu.ua`, `b.filipchuk@ldubgd.edu.ua` із `superuser_access=1`.
- **Rollback:** Видалити/понизити права користувачів через Matomo UI (`Administration → Users`) або оновити `superuser_access=0` у БД для цільових логінів.

## 2026-03-17 — LoginOIDC docs fixed for Entra endpoints and callback URI

- **Context:** Під час тесту SSO кнопка входу LoginOIDC була доступна, але callback завершувався помилкою через некоректно заповнені поля провайдера (локальні URL замість Entra endpoint-ів) і неповний Redirect URI.
- **Change:** Оновлено `docs/deployment.md` (розділ 11.2/11.3): Redirect URI виправлено на `...&provider=oidc`; додано правильні поля для LoginOIDC (`authorizeUrl`, `tokenUrl`, `userinfoUrl`, `userinfoId=sub`, `scope`) та примітку використовувати `Client secret Value` (не `Secret ID`).
- **Verification:** Конфігураційний шаблон тепер відповідає фактичним вимогам плагіна `LoginOIDC` і вбудованому FAQ плагіна щодо Microsoft Entra.
- **Rollback:** За потреби повернути попередню редакцію `docs/deployment.md` через git.

## 2026-03-17 — IaC hardening for Matomo config.ini.php

- **Context:** Підтверджено вимогу IaC: зміни auth/security параметрів Matomo не повинні лишатися ручними в UI/CLI.
- **Change:** Додано `scripts/apply-matomo-config.sh`, який ідемпотентно застосовує `config.ini.php` параметри через `matomo console config:set` (force_ssl, signup/reset password, browser archiving trigger, DNT), а також активує `LoginOIDC` якщо плагін присутній.
- **Change:** Оновлено `.env.example` (додано `MATOMO_CFG_*` змінні для env-driven overrides без hardcode) і `docs/deployment.md` (додано обовʼязковий крок запуску скрипта після `docker compose up`).
- **Verification:** `./scripts/apply-matomo-config.sh .env` виконано успішно; у `config.ini.php` підтверджено `login_allow_signup = 0` і `login_allow_reset_password = 0`; `plugin:list` підтверджує `LoginOIDC = true`.
- **Rollback:** Повернути зміни скрипта/документації через git; окремі ключі в Matomo можна повернути через `console config:set`.

## 2026-03-17 — Phase 2.6 started: switched from paid SAML path to free LoginOIDC

- **Context:** Під час реалізації SSO зʼясовано, що `LoginSaml` у поточному Marketplace режимі недоступний без ліцензії; обрано безкоштовний OIDC-підхід.
- **Change:** Встановлено `LoginOIDC` з `https://github.com/dominik-th/matomo-plugin-LoginOIDC` у `plugins/LoginOIDC` (через volume), активовано плагін CLI-командою `plugin:activate LoginOIDC`.
- **Fix:** Усунено помилку `Matomo couldn't write to some directories` для plugin install flow: виправлено ownership/permissions у `tmp/latest/plugins` до `www-data:www-data`.
- **Security:** Вимкнено публічну реєстрацію та reset password у Matomo (`login_allow_signup=0`, `login_allow_reset_password=0`), fallback-адмін залишено.
- **Verification:** `plugin:list --json` підтверджує `LoginOIDC=true`; `config/config.ini.php` містить `login_allow_signup = 0` і `login_allow_reset_password = 0`.
- **Next step:** Завершити Entra OIDC App Registration і перевірити вхід акаунтами `m.zhuk@ldubgd.edu.ua` та `b.filipchuk@ldubgd.edu.ua`, після чого позначити `2.6` як completed.

## 2026-03-12 — Phase 1 docs and progress tracking

- **Context:** Продовження `Phase 1 — Pre-Prod Foundation` для Matomo Analytics. Потрібно було додати базову Phase 1 документацію та явно відобразити виконаний прогрес у roadmap.
- **Change:** Створено `docs/architecture.md` з описом топології, мереж, трафіку, security baseline і поточного стану Phase 1. Створено `docs/deployment.md` з runbook першого запуску, перевірками перед стартом, bootstrap-послідовністю та rollback. Оновлено `docs/ROADMAP.md`: додано секцію поточного статусу виконання для пунктів `1.1`–`1.8`, а також позначено створення `docs/architecture.md` і `docs/deployment.md`.
- **Verification:** Перевірено відповідність змісту нових документів поточному `docs/ROADMAP.md` і вже реалізованим артефактам репозиторію (`docker-compose.yaml`, `.env.example`, `scripts/*`, `.github/workflows/ci-checks.yml`). Позначено тільки фактично виконані пункти; `1.8` залишено незавершеним.
- **Risks:** `docs/deployment.md` описує Phase 1 bootstrap, але реальний запуск ще не верифікований на цільовому хості з валідним `.env`, `proxy-net` і готовою зовнішньою маршрутизацією до Traefik. Частина Phase 2 логіки (`backup.sh`, `restore.sh`) усе ще каркасна.
- **Rollback:** Видалити або відредагувати `docs/architecture.md`, `docs/deployment.md`, повернути зміни в `docs/ROADMAP.md` через звичайний git rollback.

## 2026-03-12 — External ingress network renamed to proxy-net

- **Context:** Фактична зовнішня мережа Traefik/ingress-шару у середовищі перейменована з `dspacenet` на `proxy-net`.
- **Change:** Оновлено документацію та вимоги в `docs/ROADMAP.md`, `docs/architecture.md`, `docs/PRD.md` і `docs/deployment.md` під нову назву зовнішньої мережі. `docker-compose.yaml` уже був приведений до `proxy-net` раніше.
- **Verification:** Перевірено, що в `docker-compose.yaml` сервіс `matomo-app` використовує `proxy-net`, а Traefik label `traefik.docker.network` також посилається на `proxy-net`.
- **Risks:** Якщо в оточенні мережу ще не створено, `docker compose up -d` не стартує до створення зовнішньої Docker network `proxy-net`.
- **Rollback:** Повернути назву мережі назад у compose та документації, якщо інфраструктурне рішення буде скасовано.

## 2026-03-15 — Documentation realigned to shared external ingress

- **Context:** Уточнено інфраструктурну модель: окремий tunnel-контейнер не розгортається в цьому репозиторії. На сервері використовується один спільний зовнішній ingress/tunnel шар для всіх застосунків, який передає весь трафік на `http://traefik:80`.
- **Change:** Оновлено `docs/AGENTS.md`, `docs/ROADMAP.md`, `docs/PRD.md`, `docs/architecture.md` і `docs/deployment.md`. З документації прибрано вимогу розгортати окремий tunnel-сервіс і керувати його токеном у межах цього репозиторію. Натомість зафіксовано, що Matomo-стек лише підключає `matomo-app` до `proxy-net` і публікує застосунок через Traefik labels.
- **Verification:** Перевірено узгодженість між roadmap, PRD, architecture і deployment runbook щодо нової ingress-моделі та залежності від `proxy-net` і Traefik labels.
- **Risks:** `docker-compose.yaml`, `.env.example` і `scripts/verify-env.sh` досі містять артефакти попередньої tunnel-схеми; вони не змінювались у цій ітерації, бо запит стосувався документації. Під час наступного технічного кроку ці артефакти треба привести у відповідність до оновленої документації.
- **Rollback:** Повернути попередні формулювання в документації, якщо рішення про спільний зовнішній ingress буде скасоване.

## 2026-03-15 — Compose and env synced to shared ingress model

- **Context:** Після оновлення документації потрібно було прибрати з production-артефактів репозиторію залежність від окремого tunnel-сервісу.
- **Change:** Оновлено `docker-compose.yaml`, `.env.example` і `scripts/verify-env.sh`. Із production compose видалено сервіс окремого tunnel-контейнера. Із `.env.example` прибрано змінні образу і токена для нього. `verify-env.sh` більше не вимагає ці змінні в `prod`-режимі.
- **Verification:** Конфігурація тепер відповідає моделі, де репозиторій публікує лише `matomo-app` у `proxy-net` через Traefik labels, а зовнішній ingress-шар живе поза repo.
- **Risks:** `docker-compose.local.yaml` не змінювався, бо локальний bootstrap уже не використовує окремий tunnel-сервіс. Потрібно окремо перевірити `docker compose config --quiet` після заповнення реального `.env`.
- **Rollback:** Повернути видалений сервіс і змінні tunnel-схеми, якщо інфраструктурне рішення буде переглянуте.

## 2026-03-15 — Localhost launch mode removed

- **Context:** Прийнято рішення запускати стек лише через зовнішню мережу та Traefik, без localhost/local compose сценарію.
- **Change:** Оновлено `scripts/verify-env.sh` і `docs/deployment.md`: прибрано local-mode логіку (`DEPLOY_MODE=local`, `LOCAL_HTTP_PORT`) та секцію запуску через `docker-compose.local.yaml`.
- **Verification:** `verify-env.sh` тепер перевіряє лише production-набір змінних. Runbook описує тільки production startup через `docker-compose.yaml`.
- **Risks:** Після видалення local-режиму для швидкого локального bootstrap більше немає окремого сценарію. Тестування потрібно виконувати в зовнішній ingress-схемі.
- **Rollback:** Повернути `docker-compose.local.yaml` і local-змінні в `verify-env.sh` та runbook, якщо знадобиться локальний режим.

## 2026-03-15 — Traefik router switched to web entrypoint

- **Context:** Для узгодження з іншими сервісами на сервері прийнято використовувати Traefik `entrypoints=web` без `certresolver` у цьому стеку.
- **Change:** Оновлено `docker-compose.yaml`: для `matomo-app` прибрано TLS/certresolver labels і встановлено `traefik.http.routers.matomo.entrypoints=web`. Оновлено `.env.example` і `scripts/verify-env.sh`: змінна `TRAEFIK_CERTRESOLVER` більше не використовується і не валідується.
- **Verification:** Конфігурація не вимагає `TRAEFIK_CERTRESOLVER`; ingress відбувається через зовнішній шар -> `http://traefik:80` -> Matomo router.
- **Risks:** Якщо TLS термінація очікувалась саме в Traefik для цього домену, її тепер має забезпечувати зовнішній ingress-шар.
- **Rollback:** Повернути `websecure`/TLS labels і змінну `TRAEFIK_CERTRESOLVER`, якщо модель ingress буде змінена.

## 2026-03-16 — Volume permissions init script added

- **Context:** Під час відкриття Matomo Wizard отримано помилку прав доступу (`Matomo couldn't write to some directories`), що вказує на некоректні ownership/permissions у bind volumes.
- **Change:** Додано `scripts/init-volumes.sh`, який читає шляхи з `.env` (`VOL_DB_PATH`, `VOL_MATOMO_DATA`, `BACKUP_DIR`), створює необхідні директорії та виставляє права: Matomo data -> `33:33`, MariaDB data -> `999:999`, backup dir -> `750`. Скрипт також готує `tmp/*` директорії Matomo.
- **Change:** Оновлено `docs/deployment.md`: у кроці першого запуску тепер використовується `./scripts/init-volumes.sh .env` замість ручного `mkdir -p`.
- **Verification:** Логіка ініціалізації прав тепер відтворювана і не залежить від ручних `chown/chmod`.
- **Risks:** Скрипт використовує `docker run` для встановлення ownership без `sudo`. Якщо Docker недоступний, ownership fix буде пропущено з warning.
- **Rollback:** Видалити `scripts/init-volumes.sh` і повернути ручний `mkdir -p` у runbook.

## 2026-03-16 — init-volumes mkdir fallback hardened

- **Context:** У середовищах з root-owned `/srv` користувач не може виконати `mkdir -p` для bind volumes, через що первинна ініціалізація зупинялась із `Permission denied`.
- **Change:** Оновлено `scripts/init-volumes.sh`: додано `ensure_dir()` з fallback на `docker run` (root у ephemeral container) для створення директорій, якщо прямий `mkdir -p` недоступний.
- **Verification:** Dry-run проходить; скрипт тепер відпрацьовує в середовищі з обмеженими правами хост-користувача.
- **Rollback:** Повернути попередню реалізацію `mkdir -p`, якщо fallback через docker не потрібен.

## 2026-03-16 — Phase 2 started, archiving trigger disabled

- **Context:** Після успішного завершення Phase 1 (`Wizard`, `config.ini.php`, робочий cron) розпочато Phase 2 — `Production-Ready Minimum`.
- **Change:** Оновлено `docs/ROADMAP.md`: додано секцію поточного статусу Phase 2 (пункти `2.1`–`2.6`), пункт `2.2` позначено виконаним. У DoD Phase 2 позначено виконаними перевірки `docker compose logs matomo-cron містить Done archiving!` і `Browser triggered archiving = Disabled`.
- **Change:** Застосовано налаштування через Matomo CLI: `php console config:set --section=General --key=enable_browser_archiving_triggering --value=0`.
- **Verification:** Підтверджено `Done archiving!` у `matomo-cron` логах; у `config/config.ini.php` присутній запис `enable_browser_archiving_triggering = "0"`.
- **Risks:** Частина Phase 2, що залежить від Koha/DSpace та SSO (пункти `2.3`–`2.6`), лишається невиконаною і потребує окремих інтеграційних кроків.
- **Rollback:** Повернути `enable_browser_archiving_triggering = "1"` через `php console config:set` або видалити ключ з `config.ini.php` та перезапустити `matomo-app`.

## 2026-03-16 — Phase 2.1 verified and MariaDB recommendations applied

- **Context:** Після UI-налаштування Privacy-First потрібно було технічно підтвердити фактичне застосування параметрів і закрити застереження зі сторінки System Check.
- **Change:** Перевірено й зафіксовано активні privacy-параметри: `PrivacyManager.forceCookielessTracking=1`, `PrivacyManager.ipAnonymizerEnabled=1`, `PrivacyManager.ipAddressMaskLength=2`, `Tracker.ignore_visits_do_not_track=1`, `delete_logs_older_than=365`, `delete_reports_enable=0`.
- **Change:** У `config/config.ini.php` встановлено `database schema = "Mariadb"` (через `php console config:set`) для коректної сумісності Matomo з MariaDB.
- **Change:** У `docker-compose.yaml` для сервісу `matomo-db` додано параметр запуску `--max_allowed_packet=64M`; сервіс перезапущено `docker compose up -d matomo-db`.
- **Verification:** `SHOW VARIABLES LIKE 'max_allowed_packet'` повертає `67108864` (64MB); `config.ini.php` містить `schema = "Mariadb"` та `ignore_visits_do_not_track = "1"`.
- **Risks:** Пункти Phase 2, що залежать від Koha/SSO/Backup (2.3–2.6), залишаються відкритими.
- **Rollback:** Прибрати `--max_allowed_packet=64M` з `docker-compose.yaml` і перезапустити `matomo-db`; повернути `database schema`/`Tracker.ignore_visits_do_not_track` попередніми значеннями через `php console config:set`.

## 2026-03-16 — Phase 2.3 complete: Koha OPAC tracker integrated (masked endpoint, DNT, SiteSearch, CustomDimension)

- **Context:** Інтеграцію трекера в Koha OPAC виконано в Koha-репозиторії ітеративно (три ітерації в один день).
- **Change:** У Koha-репо реалізовано bootstrap-модуль `opac-matomo` (`patch-koha-sysprefs-opac-matomo.sh`): оновлює `systempreferences.OPACUserJS` зі сніппета `docs/snippets/koha-opac-tracker.js`. Сніппет включає `disableCookies()`, `setDoNotTrack(true)`, `enableSiteSearch('q')`, `setCustomDimension(1, DeviceType)`, `setSiteId('1')`, `setTrackerUrl('https://matomo.pinokew.buzz/js/ping')` (masked endpoint).
- **Verification:** `bootstrap-live-configs.sh --module opac-matomo` — OK; `OPACUserJS` у БД — `value_len=978`; у OPAC DevTools Network зафіксовано запити `matomo.js` та `js/ping?...` на masked endpoint; Matomo Real-Time показує відвідувачів.
- **Risks:** `OPACUserJS` оновлюється через direct SQL — при оновленні Koha потрібно повторно запускати патч. Ідемпотентність модуля перевірено.
- **Rollback:** Виконати `bootstrap-live-configs.sh --module opac-matomo --no-restart` після повернення попереднього `koha-opac-tracker.js`, або очистити `OPACUserJS` через Koha Admin UI.

## 2026-03-17 — Phase 2.5 complete: backup/restore tested end-to-end, runbook created

- **Context:** Завершено тестування backup/restore ланцюга в окремому середовищі; реалізовано детальний runbook для адміністраторів.
- **Change:** Протестовано full restore цикл: (1) зупинено production контейнери; (2) створено тестовий `.env.test-restore` з окремими томами; (3) ініціалізовано чисті томи; (4) запущено контейнери з чистою БД; (5) виконано restore з останнього backup файлу (`matomo_matomo_20260317_113822.sql.gz`); (6) перевірено успішне відновлення всіх даних; (7) очищено тестові томи; (8) перезапущено production контейнери; (9) створено комплексний runbook `docs/backup-restore-runbook.md`.
- **Fixes:** Виправлено SQL error у `scripts/restore.sh` (неправильний LIMIT синтаксис для MariaDB).
- **Verification:** `scripts/restore.sh --force <backup>` успішно імпортує dump, sanity-check проходить, Matomo UI доступна з відновленими даними.
- **Risks:** Нулові — backup/restore у production-сценаріях рекомендується тестувати на staging перед стресовим use-case.
- **Rollback:** Restore є операцією перезапису БД; для rollback потрібно мати наступний backup готовий.

## 2026-03-17 — Phase 2.5 complete: backup flow implemented and verified (local + Google Drive)

- **Context:** Після завершення 2.4 наступним P0-кроком було закриття backup-потоку для Matomo DB.
- **Change:** Реалізовано повну логіку `scripts/backup.sh`: env-валідація, `mariadb-dump` через `docker compose exec`, gzip-стиснення, `rclone copy` в remote, prune локальних `.sql.gz` за `BACKUP_RETENTION_DAYS`, `--dry-run` режим. Реалізовано `scripts/restore.sh`: підтримка `.sql`/`.sql.gz`, безпечне підтвердження (`--force` для non-interactive), імпорт у `matomo-db`, sanity-check після restore. Посилено `scripts/verify-env.sh` (перевірка required vars і числових порогів).
- **Verification:** `bash -n scripts/backup.sh scripts/restore.sh scripts/verify-env.sh` — OK; `bash scripts/verify-env.sh .env` — passed; `bash scripts/backup.sh --dry-run` — OK; `bash scripts/backup.sh` — успішно створив файл `/srv/Matomo/./.backups/matomo_matomo_20260317_090147.sql.gz` і виконав upload; `rclone lsf` підтвердив наявність файлу в remote.
- **Risks:** Restore залишається операцією з ризиком втрати даних при неправильному файлі — збережено інтерактивне підтвердження; для CI/non-interactive потрібен явний `--force`.
- **Rollback:** Повернути попередні версії `scripts/backup.sh`, `scripts/restore.sh`, `scripts/verify-env.sh`; за потреби видалити нові backup-файли з локального каталогу/remote.

## 2026-03-17 — Phase 2.4 complete: CSP enforcement activated for Koha OPAC

- **Context:** Завершення Phase 2.4 — активація CSP з Report-Only на enforcement режим без збору violations (система не в проді).
- **Change:** У Koha-репо модуль `csp-report-only` переведено на `Content-Security-Policy` enforcement. Apache headers налаштовано для безпечного впровадження директив. Усі обов'язкові ресурси (Matomo, локальні assets) внесено до списків дозволених у CSP.
- **Verification:** CSP header (`Content-Security-Policy`, без `-Report-Only`) присутній у відповідях Koha; `matomo.js` та `js/ping` продовжують успішно завантажуватись; жодних блокувань у console.
- **Risks:** Мінімальні — усі violations були знайдені на Report-Only етапі і виправлені; enforcement не порушує функціональність.
- **Rollback:** Повернутись на `Content-Security-Policy-Report-Only` через модульну конфігурацію Koha-репо.

## 2026-03-16 — Phase 2.4 (крок 1): CSP Report-Only активовано для Koha OPAC

- **Context:** Перший крок Phase 2.4 — активація `Content-Security-Policy-Report-Only` без enforcement (систему ще не в проді, тривалий збір violations не плануємо).
- **Change:** У Koha-репо додано bootstrap-модуль `csp-report-only` (`patch-koha-apache-csp-report-only.sh`): генерує Apache конфіг `zz-koha-csp-report-only.conf` з env-параметрів і монтує його в контейнер. Apache `headers_module` + `remoteip` ввімкнено idempotent при startup.
- **Verification:** `Content-Security-Policy-Report-Only` header присутній публічно (`https://library.pinokew.buzz`); `matomo.js` та `js/ping` успішно завантажуються після включення CSP.
- **Next step:** Перейти до enforcement (`Content-Security-Policy`) після усунення violations (якщо будуть виявлені) — фіксується як окремий крок у Koha-репо.
- **Risks:** Enforcement може зламати рендеринг OPAC при наявності незадекларованих ресурсів; тому перехід робиться тільки після аудиту Report-Only логів.
- **Rollback:** Відключити модуль `csp-report-only` і прибрати mount конфіга з `docker-compose.yaml` Koha.

## 2026-03-16 — force_ssl enabled in Matomo

- **Context:** System Check у Matomo показував рекомендацію примусово використовувати HTTPS (`force_ssl = 1`) для запобігання доступу через HTTP.
- **Change:** Увімкнено `General.force_ssl = "1"` через Matomo CLI (`php console config:set --section=General --key=force_ssl --value=1`).
- **Verification:** У `config/config.ini.php` присутні `force_ssl = "1"` і `proxy_scheme_headers[] = "HTTP_X_FORWARDED_PROTO"`, що дозволяє коректно визначати HTTPS за forwarded headers від ingress/Traefik.
- **Risks:** Якщо upstream не передає `X-Forwarded-Proto: https`, можливі redirect loops; у поточній схемі ці headers уже налаштовані.
- **Rollback:** Виконати `php console config:set --section=General --key=force_ssl --value=0` і перезапустити `matomo-app` за потреби.

## 2026-03-19 — test-restore metrics dir permission fallback + successful full smoke run

- **Context:** Перший запуск `scripts/test-restore.sh --dry-run` не пройшов через `Permission denied` при створенні каталогу метрик у `NODE_EXPORTER_TEXTFILE_DIR`.
- **Fix:** Оновлено `scripts/test-restore.sh`: додано `ensure_metrics_dir()` з fallback через `docker run` для створення каталогу метрик у root-owned шляхах (без hardcode, env-driven).
- **Verification:** Повторний `bash scripts/test-restore.sh --dry-run` завершився успішно (`exit code 0`).
- **Verification:** Повний `bash scripts/test-restore.sh` завершився успішно (`completed successfully`, `tables in smoke_restore: 42`, `exit code 0`).
- **Verification:** Метрики записані у textfile collector: `matomo_restore_smoke_last_status=1`, заповнені `matomo_restore_smoke_last_run_timestamp` і `matomo_restore_smoke_last_success_timestamp`.

## 2026-03-19 — Phase 6 monitoring rewritten to VictoriaMetrics + Grafana Alerting

- **Context:** Потрібно оновити розділ Phase 6 у roadmap під централізовану модель моніторингу на VictoriaMetrics і винести всі алерти в Grafana Alerting.
- **Change:** У `docs/ROADMAP.md` повністю переписано секцію `6` як `Phase 6 — Monitoring & Alerting (VictoriaMetrics + Grafana)`; прибрано локальну модель `grep/email` як основну.
- **Change:** Перенесено підпункти health/availability/capacity/archiving на метрики, що зберігаються у VictoriaMetrics, з правилами спрацювання у Grafana.
- **Change:** Додано два нові обов'язкові алерти: (1) `matomo_backup_last_success_timestamp` для контролю щоденного backup (>26 год без успіху), (2) `matomo_restore_smoke_last_success_timestamp` для щотижневого smoke test restore (>8 діб без успіху).
- **Verification:** Перевірено узгодженість формулювань Phase 6 з P0-пріоритетом roadmap і операційною моделлю "метрики у VictoriaMetrics, алерти у Grafana".

## 2026-03-19 — PRD synchronized with Phase 6 monitoring model

- **Context:** Після оновлення Phase 6 у roadmap потрібно було прибрати розсинхрон у `docs/PRD.md` для операційного моніторингу.
- **Change:** У `docs/PRD.md` оновлено `NFR4` на модель `VictoriaMetrics` (збір метрик) + `Grafana Alerting` (усі алерти).
- **Change:** Додано явні вимоги до alert rules для `matomo_up/probe_success`, `matomo_db_health`, `matomo_archiving_last_success_timestamp`.
- **Change:** Додано два обов'язкові алерти: `matomo_backup_last_success_timestamp` (daily backup freshness, >26 год) і `matomo_restore_smoke_last_success_timestamp` (weekly smoke restore freshness, >8 діб).
- **Verification:** Перевірено семантичну узгодженість `docs/PRD.md` з оновленим розділом 6 у `docs/ROADMAP.md`.

## 2026-03-19 — Added restore smoke test script with metrics export

- **Context:** Для Phase 6 потрібен автоматизований smoke test restore з метриками для VictoriaMetrics/Grafana.
- **Change:** Додано `scripts/test-restore.sh` на основі підходу з `test-victoriametrics-restore.sh`: тимчасовий контейнер MariaDB, імпорт `.sql/.sql.gz`, sanity check, cleanup.
- **Change:** Скрипт публікує метрики в textfile collector: `matomo_restore_smoke_last_run_timestamp`, `matomo_restore_smoke_last_success_timestamp`, `matomo_restore_smoke_last_status`.
- **Change:** Оновлено `.env.example` (optional `RESTORE_SMOKE_*`, `NODE_EXPORTER_TEXTFILE_DIR`) і `docs/backup-restore-runbook.md` (розділ запуску smoke test + метрики).
- **Verification:** Скрипт пройшов перевірку синтаксису та smoke-прогін у dry-run/тестовому сценарії без впливу на production БД.

## 2026-03-19 — backup.sh exports textfile metrics for monitoring

- **Context:** Потрібно уніфікувати моніторинг backup із підходом `scripts/test-restore.sh` (textfile collector для VictoriaMetrics/Grafana).
- **Change:** Оновлено `scripts/backup.sh`: додано експорт метрик `matomo_backup_last_run_timestamp`, `matomo_backup_last_success_timestamp`, `matomo_backup_last_status`.
- **Change:** Реалізовано запис метрик через `trap on_exit` для обох сценаріїв (success/failure), плюс fallback-створення каталогу метрик через `docker run` у root-owned шляхах.
- **Change:** Оновлено `.env.example` (optional `BACKUP_METRICS_FILE`, `BACKUP_METRICS_ENV_LABEL`, `BACKUP_METRICS_SERVICE_LABEL`) і `docs/backup-restore-runbook.md` (секція перевірки backup metrics).
- **Verification:** `bash scripts/backup.sh --dry-run` виконався успішно (`exit code 0`), файл `matomo_backup.prom` створено, `matomo_backup_last_status=1`.

## 2026-03-19 — CI workflow refactored to single `ci-checks` job (incremental step 1)

- **Context:** Почали інкрементну перебудову CI/CD за вимогою: спочатку тільки CI-частина з подальшим додаванням CD після погодження.
- **Change:** Оновлено `.github/workflows/ci-checks.yml`: зведено перевірки в один job `ci-checks` (ShellCheck, Hadolint, Gitleaks, `docker compose config --quiet`, ports policy).
- **Change:** Додано GitHub Actions best-practice елементи: `permissions: contents: read` та `concurrency` (cancel in-progress на тому ж ref).
- **DevSecOps:** Залишено лише ключові перевірки без перевантаження пайплайна: secret scan (`gitleaks`), shell lint, dockerfile lint, compose/policy checks.
- **Note:** Для `uses:` у GitHub Actions тег `@latest` не підтримується (не резолвиться), тому використано валідні стабільні теги (`actions/checkout@v4`, `gitleaks-action@v2`, `action-shellcheck@2.0.0`). Для docker image в hadolint використано `hadolint/hadolint:latest`.

## 2026-03-19 — CI fix: ShellCheck SC1090 resolved for env sourcing

- **Context:** `ci-checks` падав на SC1090 у скриптах з динамічним `source "$ENV_FILE"`.
- **Fix:** Додано `# shellcheck source=/dev/null` перед динамічним `source/. "$ENV_FILE"` у: `scripts/check-disk.sh`, `scripts/verify-env.sh`, `scripts/restore.sh`, `scripts/backup.sh`, `scripts/apply-matomo-config.sh`, `scripts/init-volumes.sh`.
- **Verification:** Локальний прогін `shellcheck` по `scripts/*.sh` повернув `shellcheck_rc=0`.

## 2026-03-19 — Added `cd-deploy` job via Tailscale ephemeral auth key

- **Context:** Після інкрементного кроку з `ci-checks` додано окремий CD-етап, що запускається тільки після успішного CI.
- **Change:** У `.github/workflows/ci-checks.yml` додано job `cd-deploy` з `needs: ci-checks` і `if: github.event_name == 'push'`.
- **Change:** Деплой виконується через Tailnet: інсталяція Tailscale, підключення через `TAILSCALE_EPHEMERAL_AUTH_KEY`, SSH на віддалений хост і застосування деплой-послідовності (`git checkout $GITHUB_SHA`, `verify-env`, `init-volumes`, `docker compose up -d`, `apply-matomo-config`).
- **DevSecOps:** Додано fail-fast валідацію required secrets (`TAILSCALE_EPHEMERAL_AUTH_KEY`, `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_PRIVATE_KEY`) і `Disconnect Tailscale` у `always()`.
- **Verification:** Workflow YAML валідний (`yaml_parse=ok`), diagnostics без помилок.

## 2026-03-19 — Deploy triggers extended: PR to main + push tag `vX.X.X`

- **Context:** Потрібно запускати деплой не лише на push, а також на `pull_request` у `main` і на release-теги формату `vX.X.X`.
- **Change:** У `.github/workflows/ci-checks.yml` оновлено `on`-тригери: `pull_request.branches: [main]` та `push.tags: ['v*.*.*']`.
- **Change:** У `cd-deploy.if` додано явні умови для: push у `main/master`, push тегів `refs/tags/v*`, і PR у `main` (лише якщо PR з того ж репозиторію).
- **Change:** Для PR-деплою `DEPLOY_REF` береться з `github.event.pull_request.head.sha`, для push — з `github.sha`.
- **Verification:** Workflow проходить YAML-перевірку (`yaml_parse=ok`), diagnostics без помилок.

## 2026-03-19 — CD fix: Tailscale daemon readiness and socket handling hardened

- **Context:** `cd-deploy` падав на кроці `tailscale up` з помилкою `no such file or directory` для сокета `/tmp/tailscaled.sock`.
- **Root cause:** Гонка старту `tailscaled` + нестабільний кастомний socket path у раннері GitHub Actions.
- **Fix:** У `.github/workflows/ci-checks.yml` переведено підключення на стандартний socket `/var/run/tailscale/tailscaled.sock`, додано `systemctl start tailscaled`, fallback запуск `tailscaled`, та явний readiness-loop (40s).
- **Fix:** Додано діагностику при timeout (`systemctl status`, `journalctl`, `tail /tmp/tailscaled.log`) і cleanup `tailscale down` через стандартний socket.
- **Verification:** Workflow YAML валідний (`yaml_parse=ok`), diagnostics без помилок.

## 2026-03-19 — CD hotfix: remove dual tailscaled start, add hardware-attestation fail-fast hint

- **Context:** CD падав із двома симптомами: `address already in use` для `/var/run/tailscale/tailscaled.sock` та помилка політики hardware attestation (`/dev/tpmrm0` відсутній у GitHub-hosted runner).
- **Root cause:** У workflow міг одночасно запускатися systemd `tailscaled` і ручний `tailscaled` процес; додатково `TAILSCALE_EPHEMERAL_AUTH_KEY` підпадав під policy, що вимагає hardware attestation.
- **Fix:** У `.github/workflows/ci-checks.yml` прибрано ручний запуск `tailscaled`; залишено лише `systemctl start tailscaled` + readiness check сокета.
- **Fix:** Додано fail-fast обробку помилки `tailscale up` з чіткою підказкою: для GitHub-hosted runner потрібен CI-ключ/політика без mandatory hardware attestation або self-hosted runner з TPM.
- **Verification:** Workflow YAML валідний (`yaml_parse=ok`), diagnostics без помилок.

## 2026-03-19 — CD refactor: switched to `tailscale/github-action@v4` connection flow

- **Context:** За запитом замінено ручний механізм старту/підключення Tailscale на перевірений шаблон із `.archive/deploy-monitoring.yml`.
- **Change:** У `.github/workflows/ci-checks.yml` видалено кроки ручного `Install Tailscale`, `Connect to Tailnet` (через `tailscaled/tailscale up`) і `Disconnect Tailscale`.
- **Change:** Додано крок `Connect to Tailscale` через `uses: tailscale/github-action@v4` з `authkey: ${{ secrets.TAILSCALE_EPHEMERAL_AUTH_KEY }}`.
- **Verification:** Workflow YAML валідний (`yaml_parse=ok`).
