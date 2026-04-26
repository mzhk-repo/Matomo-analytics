# **📊 Roadmap: Production-Ready Matomo Analytics**

**Статус:** Draft → На виконанні **Версія:** 1.3 — Березень 2026 **Owner:** DevOps / System Admin Team **Репозиторій:** matomo-deploy **Екосистема:** Koha LMS · DSpace 9 · Web-портали установи

## **1\. Executive Summary**

Matomo розгортається як **окремий Docker Compose стек** (matomo-deploy), ізольований від стеку Koha. Зовнішній ingress/tunnel шар працює **поза межами цього репозиторію** і передає весь трафік на існуючий **Traefik** у мережі proxy-net з адресою `http://traefik:80`. У межах цього репозиторію Matomo-стек лише приєднує контейнер застосунку до `proxy-net` і публікує його через Traefik labels; MariaDB залишається у внутрішній мережі matomonet.  
**Ключові принципи (успадковані з Koha-стеку):**

* env-SSOT — єдине джерело правди для всіх конфігурацій  
* Immutable Deployments — конфігурація через env/volumes, без ручних правок у контейнерах  
* Soft Least Privilege — no-new-privileges:true \+ вибіркові cap\_drop там, де перевірено що не ламають стек  
* No public ports — весь зовнішній трафік йде через зовнішній ingress-шар → Traefik  
* Security-First \+ Privacy-First (GDPR, Cookieless, IP anonymization)

**Цільова схема (T+3 тижні):** Matomo обслуговує Koha OPAC (Site ID 1\) та DSpace 9 (Site ID 3\) через єдину панель на analytics.mylibrary.edu.

## **2\. Scope та Пріоритети**

### **In Scope**

| \# | Завдання | Пріоритет |
| :---- | :---- | :---- |
| 1 | Розгортання Docker-стеку (MariaDB \+ Matomo Apache \+ Cron на fpm-alpine) | **P0** |
| 3 | Traefik інтеграція: labels, ReplacePathRegex middleware для маскування трекера | **P0** |
| 4 | Cookieless трекінг \+ IP anonymization (GDPR) | **P0** |
| 5 | Інтеграція маскованого трекера в Koha через patch-koha-templates.sh | **P0** |
| 6 | Активація та налаштування CSP-заголовків у Koha (через patch-koha-templates.sh) | **P0** |
| 7 | Site Search для Koha (параметр q) | **P0** |
| 8 | Cron-архівація звітів (CLI archiving, browser-trigger OFF) | **P0** |
| 9 | Data Retention policy (12 міс. raw logs, назавжди — archives) | **P0** |
| 10 | DB Backup: локально \+ Google Drive (rclone) | **P0** |
| 11 | Базовий моніторинг: диск, healthcheck, cron-статус | **P0** |
| 12 | SSO інтеграція (MS365 / Entra ID) | **P0** |
| 13 | Інтеграція трекера в DSpace 9 \+ CSP | **P1** |
| 14 | Custom Dimensions (Mobile/Desktop) | **P1** |
| 15 | Базові дашборди для керівництва | **P1** |
| 16 | MariaDB тюнінг під великі обсяги | **P2** |
| 17 | Масштабування на нові системи установи | **P2** |

### **Out of Scope**

* Аналітика серверних логів (ELK — окремий стек)  
* Розробка кастомних плагінів Matomo  
* Розподілене трасування (Jaeger/Tempo)  
* Alertmanager / PagerDuty інтеграція

## **3\. Production Minimum Architecture**

  ┌──────────────────────────────────────────────────────────┐  
  │  EXTERNAL USERS / STAFF                                  │  
  │       (браузер → analytics.mylibrary.edu)                │  
  └────────────────────┬─────────────────────────────────────┘  
                       │ HTTPS  
  ┌────────────────────▼─────────────────────────────────────┐  
  │  Shared external ingress / tunnel layer                  │  
  │  (розгорнутий поза цим репозиторієм)                     │  
  └────────────────────┬─────────────────────────────────────┘  
                       │ http://traefik:80  
                       │ proxy-net (shared external network)  
  ┌────────────────────▼─────────────────────────────────────┐  
  │  Traefik (існуючий, в proxy-net)                         │  
  │  \- SSL termination                                       │  
  │  \- ReplacePathRegex middleware (via matomo-app labels)   │  
  └────────────────────┬─────────────────────────────────────┘  
                       │ proxy-net  
  ┌────────────────────▼─────────────────────────────────────┐  
  │  matomo-app (matomo:apache, all-in-one)                  │  
  │  \- мережі: proxy-net \+ matomonet                         │  
  └────────────────────┬─────────────────────────────────────┘  
                       │ matomonet (internal: true)  
  ┌────────────────────▼─────────────────────────────────────┐  
  │  mariadb:11                                              │  
  │  (тільки matomonet, жодного виходу назовні)              │  
  └──────────────────────────────────────────────────────────┘  
  ┌──────────────────────────────────────────────────────────┐  
  │  matomo-cron (matomo:fpm-alpine, hourly loop)            │  
  │  \- мережа: тільки matomonet                              │  
  └──────────────────────────────────────────────────────────┘  
           ↑                         ↑  
    JS-tracker ping            JS-tracker ping  
  from Koha OPAC             from DSpace 9 UI  
  (via patch-koha-           (index.html Angular)  
   templates.sh)

**Мережева модель:**

* matomonet — internal: true, bridge. Містить: matomo-app, mariadb, matomo-cron.  
* proxy-net — external: true (існуюча мережа Traefik). Підключається matomo-app.  
* Зовнішній ingress/tunnel шар не розгортається в цьому репозиторії. Усі зовнішні маршрути в ньому дивляться на `http://traefik:80`, а Traefik далі маршрутизує запити до matomo-app за labels. Виходу в публічний інтернет напряму немає.  
* matomo-app \= точка дотику між matomonet та proxy-net.  
* Matomo не має прямого мережевого доступу до kohanet. Взаємодія — виключно через HTTP-трекер у браузері відвідувача.

## **4\. Phased Roadmap**

### **Phase 1 ✅ — Pre-Prod Foundation**

**Часовий горизонт:** T+0 → T+3 дні **Пріоритет:** P0

#### **Мета**

Розгорнути функціональний ізольований Docker-стек Matomo з MariaDB і Cron-контейнером. Система повинна бути доступна через Traefik та пройти базову перевірку здоров'я.

#### **Поточний статус виконання (станом на 2026-03-12)**

* [x] 1.1 — Структура репозиторію створена
* [x] 1.2 — Базовий docker-compose стек підготовлено
* [x] 1.3 — Traefik labels і tracker rewrite додано
* [x] 1.4 — `.env.example` підготовлено
* [x] 1.5 — `verify-env.sh` реалізовано
* [x] 1.6 — `check-ports-policy.sh` реалізовано
* [x] 1.7 — `ci-checks.yml` додано
* [x] 1.8 — Перший запуск і проходження Wizard виконано (2026-03-16)
* [x] `docs/architecture.md` створено
* [x] `docs/deployment.md` створено

#### **Що робимо**

**1.1 — Структура репозиторію**  
matomo-deploy/  
├── docker-compose.yaml  
├── .env.example  
├── .gitignore  
├── scripts/  
│   ├── verify-env.sh            \# Валідація .env перед запуском  
│   ├── backup.sh                \# DB backup локально \+ rclone → Google Drive  
│   ├── restore.sh               \# Restore procedure  
│   └── check-ports-policy.sh   \# Перевірка відсутності публічних портів  
├── .github/  
│   └── workflows/  
│       └── ci-checks.yml        \# shellcheck, hadolint, gitleaks, ports-check  
└── docs/  
    └── (заглушки — заповнюються в Phase 4\)

**1.2 — Сервіси та мережі**  
Мережі у docker-compose.yaml: matomonet (internal: true, bridge) та proxy-net (external: true).  
matomo-db — mariadb:11. Мережа: тільки matomonet. security\_opt: \[no-new-privileges:true\]. Healthcheck через mariadb-admin ping. Mem limit: 1g.  
matomo-app — matomo:apache. Мережі: matomonet \+ proxy-net. security\_opt: \[no-new-privileges:true\]. Traefik labels (детально — п. 1.3). JSON-file logging з ротацією. Mem limit: 512m. depends\_on: matomo-db (healthy).  
matomo-cron — matomo:fpm-alpine **(P0)**. Мережа: тільки matomonet. Використання fpm-alpine оптимізує споживання ресурсів. Entrypoint: нескінченний цикл php console core:archive \--url=... && sleep 3600\. Mem limit: 256m. depends\_on: matomo-db (healthy).  
Окремий tunnel-контейнер у цьому репозиторії **не розгортається**. Зовнішній ingress-шар винесено на рівень сервера як спільний для всіх застосунків; з боку цього стеку достатньо підключити `matomo-app` до `proxy-net` і описати Traefik labels.  
**Щодо cap\_drop:** Застосовується тільки no-new-privileges:true для всіх контейнерів. Повний cap\_drop: \[ALL\] **не застосовується** без попереднього тестування — може зламати старт або healthcheck MariaDB/Apache. Аудит і поступове додавання cap\_drop — Post-Prod Phase A.  
**1.3 — Traefik labels на matomo-app**  
Необхідні labels:

* Увімкнути Traefik для контейнера  
* Router rule: Host("analytics.mylibrary.edu")  
* Entrypoint: web  
* Service port: 80  
* **ReplacePathRegex middleware (AdBlock Mitigation):** обов'язково налаштувати маскування трекера:  
  * перепис ^/js/app\\.js$$ → /matomo.js  
  * перепис ^/js/ping$$ → /matomo.php

**1.4 — .env.example (SSOT)**  
Групи змінних: Database (DB\_ROOT\_PASS, DB\_NAME, DB\_USER, DB\_PASS, DB\_PREFIX), Volumes (VOL\_DB\_PATH, VOL\_MATOMO\_DATA), Matomo (MATOMO\_HOST, MATOMO\_API\_TOKEN), Backup (BACKUP\_DIR, BACKUP\_RETENTION\_DAYS, RCLONE\_REMOTE, RCLONE\_DEST\_PATH).  
Усі секрети зберігаються **виключно у .env** на хості (права 600). .env у .gitignore. CI (gitleaks) блокує випадковий коміт секретів.  
**1.5 — verify-env.sh**  
Перевіряє: всі обов'язкові змінні задані, жодна не містить CHANGE\_ME. Fail-fast: exit 1 при будь-якій помилці.  
**1.6 — check-ports-policy.sh**  
Перевіряє відсутність ports: з публічним зв'язуванням у docker-compose.yaml. Запускається в CI.  
**1.7 — CI pipeline**  
Jobs: shellcheck для всіх \*.sh, hadolint (якщо є Dockerfile), gitleaks, docker compose config \--quiet, check-ports-policy.sh.  
**1.8 — Перший запуск**  
Послідовність: скопіювати .env.example → .env, заповнити, запустити verify-env.sh, створити директорії volumes, docker compose up \-d, перевірити docker compose ps, пройти Matomo Installation Wizard. Після завершення Wizard — config/config.ini.php зберігається у volume.

#### **Що НЕ робимо на цьому етапі**

* Не інтегруємо трекер у Koha / DSpace  
* Не налаштовуємо Privacy / Cookieless  
* Не запускаємо Backup  
* Не вносимо CSP-зміни

#### **Залежності**

* Traefik запущений у proxy-net  
* Зовнішній ingress/tunnel шар на сервері вже маршрутизує `analytics.mylibrary.edu` на `http://traefik:80`  
* Docker Compose \>= 2.x на хості

#### **Ризики**

| Ризик | Мітигація |
| :---- | :---- |
| matomo-app не бачить Traefik | Перевірити що обидва в proxy-net; перевірити labels |
| Зовнішній ingress не доводить трафік до Traefik | Перевірити серверний tunnel/ingress-шар і маршрут `http://traefik:80` |
| Wizard перезаписує config | Volume mount зберігає config/config.ini.php |
| Секрет у git | gitleaks у CI; .env у .gitignore |
| cap\_drop ламає контейнери | Не застосовувати cap\_drop: ALL без тестування |

#### **Definition of Done (DoD)**

* [x] docker compose ps — всі сервіси Up / (healthy)
* [x] Matomo відкривається на https://matomo.pinokew.buzz
* [x] Wizard пройдено, SuperUser створено
* [x] Жодного відкритого порту matomo-стеку на хості
* [x] CI pipeline зелений
* [x] .env не в git history

#### **Артефакти**

* docker-compose.yaml, .env.example, .gitignore  
* scripts/verify-env.sh, scripts/check-ports-policy.sh  
* .github/workflows/ci-checks.yml

### **Phase 2 ✅ — Production-Ready Minimum**

**Часовий горизонт:** T+3 → T+10 днів **Пріоритет:** P0

#### **Поточний статус виконання (станом на 2026-03-17)**

* [x] 2.1 — Privacy-First налаштування (IP anonymization=2 bytes, Cookieless=ON, DNT=ON, retention: raw logs 12 months / archives never)
* [x] 2.2 — CLI Archiving через Cron (cron підтверджено; Browser triggered archiving = OFF)
* [x] 2.3 — Інтеграція з Koha через patch-koha-matomo.sh (tracking + masked endpoint + DNT + SiteSearch + CustomDimension — виконано в Koha-репо)
* [x] 2.4 — CSP-заголовки для Koha (enforcement активовано; нулі violations)
* [x] 2.5 — DB Backup: локально + Google Drive (rclone) — реалізовано та верифіковано (`--dry-run` + реальний backup/upload)
* [~] 2.6 — SSO: MS365 / Entra ID (LoginOIDC встановлено й активовано; триває Entra-конфіг і валідація входу)

#### **Мета**

Виконати всі операції, без яких система не може приймати реальний трафік: Privacy-First налаштування, інтеграція трекера в Koha через patch-koha-templates.sh (включно з CSP), cron-архівація, бекап, SSO.

#### **2.1 — Privacy-First налаштування**

Matomo Admin UI → Administration → Privacy:

| Налаштування | Значення |
| :---- | :---- |
| Anonymize IP | Mask 2 bytes |
| Cookieless Tracking | Enabled (глобально) |
| Honor Do Not Track | Enabled |
| Delete raw logs after | 12 months |
| Keep aggregated reports | Never delete |

#### **2.2 — CLI Archiving через Cron**

Matomo Admin UI → Administration → General Settings → Archiving Settings: Enable browser triggered archiving → **OFF**.  
Cron-архівація вже налаштована у matomo-cron (Phase 1). Верифікація: docker compose logs matomo-cron містить Done archiving\!.

#### **2.3 — Інтеграція з Koha через patch-koha-templates.sh**

**Метод:** JS-сніппет трекера вставляється **автоматично** через patch-koha-templates.sh (або окремий модуль scripts/patch/patch-koha-matomo.sh за аналогією з існуючою patch-архітектурою Koha-стеку). Скрипт встановлює системне налаштування OpacCustomJS безпосередньо через koha-mysql CLI або SQL-запит до Koha DB.  
Це забезпечує: ідемпотентність (повторний запуск не дублює сніппет), збереження при оновленнях Docker-контейнерів Koha, відповідність підходу patch-based configuration всього Koha-стеку.  
**Сніппет містить:**

* disableCookies() — Cookieless mode (примусово)  
* setDoNotTrack(true) — підтримка DNT  
* enableSiteSearch('q') — Site Search для Koha  
* Custom Dimension 1: Device Type (Mobile / Desktop)  
* setSiteId('1')  
* **Обов'язково:** setTrackerUrl('https://analytics.mylibrary.edu/js/ping') — використовуємо замаскований URL для обходу AdBlock.

Актуальна версія сніппету зберігається в docs/snippets/koha-opac-tracker.js.

#### **2.4 — CSP-заголовки для Koha через patch-koha-templates.sh**

**Контекст:** CSP у Koha-стеку **не активовано**. Phase 2 активує CSP вперше — це не зміна існуючої конфігурації, а первинне ввімкнення.  
**Метод:** Той самий patch-koha-templates.sh додає Header always set Content-Security-Policy до Apache VirtualHost Koha.  
**Рекомендована послідовність активації:**

1. Спочатку розгорнути у Content-Security-Policy-Report-Only режимі  
2. Зібрати violations у DevTools / сервер-логах протягом кількох днів  
3. Виправити усі violations (інлайн-скрипти, сторонні ресурси)  
4. Перейти в Content-Security-Policy (enforcement)

**Обов'язковий мінімум директив:** script-src, connect-src, img-src повинні містити https://analytics.mylibrary.edu. style-src та default-src — за результатами аудиту violations.

#### **2.5 — DB Backup: локально \+ Google Drive (rclone)**

**Стратегія 3-2-1:**

* Рівень 1: локальний .sql.gz дамп у $BACKUP\_DIR  
* Рівень 2: автоматичне завантаження у Google Drive через rclone після кожного бекапу  
* Рівень 3: відповідальність адміністрації (NAS / офсайт) — поза скопом roadmap

**backup.sh логіка (без hardcode, env-driven):**

1. Читає всі параметри з env  
2. Підтримує \--dry-run  
3. mysqldump \--single-transaction через Swarm runtime (`docker exec` у running task `matomo_matomo-db`; compose fallback лише для локального dev)  
4. Стиснення у gzip  
5. rclone copy на $RCLONE\_REMOTE:$RCLONE\_DEST\_PATH  
6. Prune локальних файлів старше $BACKUP\_RETENTION\_DAYS днів

Rclone вже налаштований на хості. RCLONE\_REMOTE та RCLONE\_DEST\_PATH підтягуються з .env.  
**Systemd timer:** matomo-backup.timer щодня о 02:00 (структура service \+ timer — аналогічно Koha-стеку).

#### **2.6 — SSO: MS365 / Entra ID**

**Мета:** Обмежити доступ до Matomo-дашбордів виключно авторизованим персоналом установи через MS365 / Entra ID **до** Go-Live.  
**Підхід:** Безкоштовний плагін LoginOIDC (`dominik-th/matomo-plugin-LoginOIDC`) + Microsoft Entra ID (OIDC).  
**Кроки:**

1. Встановити LoginOIDC у `plugins/LoginOIDC` і активувати через Matomo CLI  
2. Зареєструвати Matomo як App Registration в Entra ID (OpenID Connect)  
3. Налаштувати OIDC параметри в Matomo (issuer, client id/secret, redirect URI, scopes)  
4. Налаштувати claims: email/upn -> username, за потреби groups -> Matomo roles  
5. Протестувати SSO з тестовими адмін-акаунтами Entra ID  
5. Залишити один локальний fallback-адмін акаунт (задокументувати у docs/deployment.md)  
6. Відключити публічну реєстрацію та password reset у Matomo

**До активації SSO:** ізолювати доступ до analytics.mylibrary.edu через Traefik middleware (IP allowlist або BasicAuth як тимчасовий захід).

#### **Що НЕ робимо на цьому етапі**

* Не інтегруємо DSpace (Phase 3\)  
* Не налаштовуємо дашборди для керівництва (Phase 4\)

#### **Залежності**

* Phase 1 DoD виконано  
* Site ID 1 (Koha) зареєстровано в Matomo Admin  
* Доступ до Koha DB для patch-koha-matomo.sh  
* Entra ID tenant з правами на реєстрацію Enterprise Application

#### **Ризики**

| Ризик | Мітигація |
| :---- | :---- |
| CSP ламає рендеринг Koha | Починати з Report-Only режиму; тест на staging |
| patch-koha-matomo.sh дублює сніппет | Ідемпотентна перевірка: grep перед записом |
| SSO неправильний маппінг ролей | Тест з тестовим акаунтом до відключення local login |

#### **Definition of Done (DoD)**

* [x] DevTools → Cookies: відсутні \_pk\_\* після відкриття OPAC  
* [x] Matomo Real-Time показує відвідувачів з Koha  
* [x] Пошук ?q=test → Matomo Site Search  
* [x] docker compose logs matomo-cron містить Done archiving\!  
* [x] Matomo Admin: Browser triggered archiving \= **Disabled**  
* [x] Backup: .sql.gz у $BACKUP\_DIR \+ підтверджено у Google Drive  
* [x] backup.sh \--dry-run проходить без помилок  
* [x] Data Retention: Raw logs \= 12 months, Archives \= Never  
* [x] IP у Matomo Real-Time відображається як x.x.0.0  
* [x] Koha OPAC: нуль CSP violations у DevTools → Console  
* [x] SSO: вхід через MS365 акаунт успішний; fallback-адмін перевірено

#### **Артефакти**

* scripts/backup.sh, scripts/restore.sh — автономні скрипти працюють через Swarm runtime (`DOCKER_RUNTIME_MODE=swarm`, `STACK_NAME=matomo`) і читають `env.<env>.enc` через SOPS `/dev/shm`  
* scripts/apply-matomo-config.sh  
* scripts/patch/patch-koha-matomo.sh  
* docs/snippets/koha-opac-tracker.js  
* docs/custom-dimensions.md  
* docs/backup-restore-runbook.md

### **Phase 3 ✅ — DSpace 9 Integration**

**Часовий горизонт:** T+10 → T+17 днів **Пріоритет:** P1

#### **Мета**

Підключити DSpace 9 (Angular UI) до Matomo як Site ID 3\. Налаштувати відстеження Bitstream downloads та Site Search.

#### **Що робимо**

**3.1 — Реєстрація сайту**  
Matomo Admin → Websites → Add new site: DSpace Repository, URL https://dspace.mylibrary.edu, Site ID 3\.  
**3.2 — JS-сніппет для DSpace 9 (Angular)**  
DSpace 9 побудований на Angular. Сніппет вставляється в src/index.html. Містить: disableCookies(), setDoNotTrack(true), enableSiteSearch('query', 'filter'), enableLinkTracking(), setSiteId('3'). **Обов'язково:** setTrackerUrl('https://analytics.mylibrary.edu/js/ping') — використовуємо замаскований URL для обходу AdBlock.  
Актуальна версія: docs/snippets/dspace-tracker.js.  
**3.3 — Bitstream Download Tracking**  
DSpace 9 Bitstream URLs: /bitstream/handle/.... Підхід залежить від Angular routing :
* Базовий варіант: enableLinkTracking() \+ налаштування Download URL patterns у Matomo Admin  

**3.4 — CSP для DSpace 9**  
Додати analytics.mylibrary.edu до script-src та connect-src у Traefik-конфігурації DSpace. Аналогічний підхід Content-Security-Policy-Report-Only як для Koha.

#### **Що НЕ робимо на цьому етапі**

* Не розробляємо Angular-компоненти або кастомні плагіни DSpace  
* Не налаштовуємо авторську статистику (Post-Prod)

#### **Залежності**

* Phase 2 DoD виконано  
* Доступ до DSpace 9 codebase / build pipeline  
* Site ID 3 зареєстровано в Matomo

#### **Definition of Done (DoD)**

* [x] DSpace Bitstream кліки → Matomo Downloads  
* [x] Пошукові запити у DSpace → Matomo Site Search  
* [x] Нуль CSP violations у консолі DSpace  
* [x] Відсутні \_pk\_\* cookies у DSpace

#### **Артефакти**

* docs/snippets/dspace-tracker.js  
* docs/integrations/dspace.md

### **Phase 4 ✅ — Production Readiness & Go-Live**

**Часовий горизонт:** T+17 → T+21 днів **Пріоритет:** P0 (Gate), P1 (Dashboards, Docs)

#### **Мета**

Фінальна верифікація production readiness, базові дашборди для керівництва, обов'язкова документація.

#### **Що робимо**

**4.1 — Production Readiness Gate** — повний чекліст у Розділі 7\.  
**4.2 — Базові дашборди (P1)**  
Matomo → Dashboard → "Бібліотека — Executive View". Мінімальний набір: Unique Visitors (30 днів), Site Search Keywords Koha (Top 20), Downloads DSpace (Top 20), Devices (Mobile/Desktop), Countries.  
Спільний view-only акаунт library-reports@mylibrary.edu для керівництва. Авторизація через SSO.  
**4.3 — Документація** — повний перелік у Розділі 9\.

## **5\. ✅ Must-Have Analytics Tracking & Reports**

### **Must-Have до Go-Live**

| Звіт | Де в Matomo | Для кого |
| :---- | :---- | :---- |
| Unique Visitors (all sites) | Visitors → Overview | Керівництво |
| Site Search — Koha | Behavior → Site Search | Бібліотекарі |
| Downloads — DSpace | Behavior → Downloads | Адміністрація |
| Real-Time Visitors | Dashboard → Real-time | DevOps (верифікація) |
| Referrers | Acquisition → All Channels | Адміністрація |

### **Custom Dimensions — реєстрація (до Go-Live)**

Administration → Websites → Custom Dimensions → Create:

* Dimension 1: Device Type (scope: Visit) — Mobile / Desktop

### **Site Search параметри (обов'язково)**

* Koha: Query parameter \= q  
* DSpace: Query parameter \= query, Category parameter \= filter

### **Звіти Post-Prod (можна відкласти)**

Custom Reports (авторська статистика), Goals & Conversions, Cohort Analysis, Scheduled Email Reports.

## **6\. ✅ Phase 6 — Monitoring & Alerting (VictoriaMetrics + Grafana)**

### **6.1 — Збір метрик у VictoriaMetrics (P0)**

Базовий моніторинг централізовано в VictoriaMetrics (single source of metrics). Обов'язкові джерела: доступність Matomo (HTTP probe), технічні метрики backup/restore/archiving з скриптів.

### **6.2 — Health & Availability (P0)**

Контроль доступності Matomo переводиться на метрики та правила в Grafana Alerting (джерело даних — VictoriaMetrics):

* `matomo_up` (або `probe_success`) для `https://analytics.mylibrary.edu/` має бути `1`.
* `matomo_db_health` (еквівалент docker healthcheck mariadb) має бути `1`.
* Якщо один із показників невалідний понад 5 хв — алерт у Grafana.

### **6.3 — Capacity Monitoring (P0)**

* DB size check: добова метрика розміру Matomo DB; перевищення 5 GB — warning-алерт для перегляду retention.

### **6.4 — Archiving & Backup Freshness Alerts (P0)**

Контроль регулярних задач переводиться з локальних grep/email-перевірок на Grafana Alerting:

* `matomo_archiving_last_success_timestamp` — алерт, якщо немає успішної архівації > 2 год.
* `matomo_backup_last_success_timestamp` — **новий обов'язковий алерт**: якщо немає успішного щоденного backup > 26 год.

### **6.5 — Restore Readiness Alert (P0)**

Додається окремий контроль відновлюваності:

* `matomo_restore_smoke_last_success_timestamp` — **новий обов'язковий алерт**: якщо не було успішного weekly smoke test restore > 8 діб.
* Smoke restore виконується в ізольованому тестовому оточенні; результат публікується як метрика у VictoriaMetrics, алертинг — у Grafana.

## **7\. Production Readiness Gate**

Без проходження цього Gate **забороняється** оголошувати систему Production-Ready.

### **Go-Live Checklist**

#### **🔒 Security & Privacy**

* [x] Відсутні \_pk\_\* cookies у DevTools після відкриття OPAC  
* [x] IP у Matomo Real-Time відображається як x.x.0.0  
* [x] Do Not Track: Enabled  
* [x] Жодного відкритого порту matomo-стеку на хості  
* [x] Зовнішній ingress/tunnel шар на сервері маршрутизує `analytics.mylibrary.edu` на `http://traefik:80` без помилок  
* [x] Traefik router для analytics.mylibrary.edu активний і віддає Matomo через labels  
* [x] .env не в git history  
* [x] Gitleaks в CI зелений  
* [x] SSO: вхід через MS365 акаунт успішний  
* [x] Локальний fallback-адмін задокументовано та перевірено

#### **⚡ Performance & Archiving**

* [x] matomo.js завантажується \< 200ms (DevTools → Network)  
* [x] Cache-Control header присутній для matomo.js  
* [x] Browser triggered archiving: **Disabled**  
* [x] docker compose logs matomo-cron містить Done archiving\!

#### **📊 Tracking**

* [x] Koha OPAC: відвідувач з'являється в Matomo Real-Time  
* [x] Пошук ?q=test у Koha → Matomo Site Search  
* [x] DSpace: Bitstream клік → Matomo Downloads  
* [x] Custom Dimension 1 (Device Type) записується

#### **💾 Data & Backup**

* [x] Backup: .sql.gz у $BACKUP\_DIR \+ підтверджено у Google Drive  
* [x] backup.sh \--dry-run проходить  
* [x] Data Retention: Raw logs \= 12 months, Archives \= Never  
* [x] check-disk.sh → ✅ для всіх volumes

#### **📄 CSP**

* [x] Koha OPAC: нуль CSP violations у DevTools  
* [x] DSpace: нуль CSP violations у DevTools

#### **📚 Documentation**

* [x] docs/architecture.md заповнено  
* [x] docs/deployment.md заповнено  
* [x] docs/backup-restore.md заповнено  
* [x] docs/privacy-compliance.md заповнено  
* [x] docs/snippets/koha-opac-tracker.js актуальна

## **8\. Post-Prod Roadmap**

### **Post-Prod Phase A — Stability & Observability**

**Коли:** 2–4 тижні після Go-Live · **Пріоритет:** P1  
**A1 — MariaDB Tuning.** Після \~2 тижнів реального трафіку: аналіз slow query log, тюнінг innodb\_buffer\_pool\_size (50-70% від виділеної RAM), innodb\_log\_file\_size, max\_connections. Конфігурація через volume-mounted my.cnf.  
**A2 — Scheduled Reports.** Matomo → Email Reports: щотижневий / щомісячний звіт (Unique Visitors, Top Site Search, Top Downloads).  
**A3 — Розширений Disk Alerting.** Інтегрувати check-disk.sh з email або Telegram-нотифікацією.  
**A4 — Аудит cap\_drop.** Протестувати cap\_drop: \[ALL\] \+ вибіркові cap\_add для matomo-app та mariadb у staging. Якщо стабільно — додати у docker-compose.yaml.

### **Post-Prod Phase B — Scale: Нові системи установи**

**Коли:** За потребою · **Пріоритет:** P2  
Алгоритм підключення нової системи: реєстрація сайту у Matomo → отримання Site ID → вставка JS-сніппету (шаблон з docs/snippets/) → оновлення CSP → тест Real-Time → документування у docs/integrations/.  
**Потенційні наступні системи:**

| Система | Site ID (плановий) | Пріоритет |
| :---- | :---- | :---- |
| Бібліотечний веб\-портал | 2 | P1 |
| Електронний журнал | 4 | P2 |
| Інша інстанція репозиторію | 5 | P2 |

## **9\. Required Repository Documentation (docs/)**

| Файл | Призначення | Коли | Owner |
| :---- | :---- | :---- | :---- |
| docs/architecture.md | Топологія стеку, мережева схема, Traefik інтеграція | Phase 1 | DevOps |
| docs/deployment.md | Runbook: перший запуск, оновлення, відкат, SSO fallback | Phase 1–2 | DevOps |
| docs/backup-restore.md | Бекап, rclone, restore, PITR | Phase 2 | DevOps/SRE |
| docs/privacy-compliance.md | Cookieless, IP mask, Data Retention, GDPR | Phase 2 | DevOps \+ DPO |
| docs/known-limitations.md | AdBlock втрати (\~20-30%), MariaDB ліміти | Phase 4 | DevOps |
| docs/integrations/koha.md | patch-koha-matomo.sh, CSP, Custom Dimensions | Phase 2 | DevOps |
| docs/integrations/dspace.md | DSpace 9 Angular, Bitstream tracking, CSP | Phase 3 | DevOps |
| docs/snippets/koha-opac-tracker.js | Актуальна версія JS-трекера для Koha | Phase 2 | DevOps |
| docs/snippets/dspace-tracker.js | Актуальна версія JS-трекера для DSpace 9 | Phase 3 | DevOps |
| docs/custom-dimensions.md | Custom Dimensions: ID, scope, опис | Phase 2 | DevOps |
| docs/monitoring.md | Healthchecks, disk alerts, cron status, DB size | Phase 4 | SRE |
| docs/operations/data-retention.md | Retention policy, де налаштовано, як перевірити | Phase 2 | DevOps |
| docs/post-prod/scaling-guide.md | Алгоритм підключення нової системи | Post-Prod B | DevOps |
| AGENTS.md | Guide для нової AI-сесії або нового інженера | Phase 1 | DevOps |
| CHANGELOG.md | Індекс змін (за аналогією з Koha-стеком) | Phase 1 | DevOps |

## **10\. Open Questions / Gaps**

| \# | Питання / Gap | Статус | Критичність |
| :---- | :---- | :---- | :---- |
| 1 | **Traefik RewritePath:** Потреба у глобальному RewritePath / StripPrefix | ✅ Вирішено: Використовувати Traefik Middlewares **лише** для AdBlock-підміни трекера, як описано в Phase 1.3 | — |
| 2 | **DSpace 9 Bitstream routing:** Angular SSR чи CSR навігація для Bitstream-сторінок? Впливає на вибір методу download tracking (enableLinkTracking vs trackLink через router events). | ⬜ Відкрито | P1 |
| 3 | **CSP у Koha не активовано:** Первинне ввімкнення CSP — ризик порушення рендерингу якщо є нелокальні скрипти або inline-обробники у Koha-темах. Обов'язковий Report-Only режим перед enforcement. | ⬜ Потребує аудиту | **P0** |
| 4 | **rclone Google Drive:** rclone remote вже налаштовано на хості? Яка Google Drive папка-ціль? Обмеження на розмір? Service Account чи OAuth? | ✅ Вирішено: rclone вже налаштований на хості, шлях до папки-цілі передається безпечно через .env. | — |
| 5 | **Matomo API Token у .env:** MATOMO\_API\_TOKEN для health-перевірок зберігається у .env. Потрібно підтвердити що .env захищено (права 600, не в git, не передається в логи). | ⬜ Підтвердити | P1 |
| 6 | **Koha сесійний механізм:** Визначення статусу авторизованого читача (Guest/LoggedIn) у JS-трекері. | ✅ Вирішено: Статус авторизації не береться до уваги, оскільки це не є принциповим для базової статистики каталогу. | — |
| 7 | **Matomo образ: matomo:apache (all-in-one).** Рішення прийнято: matomo:apache. Traefik маршрутизує на порт 80 Apache. Окремий Nginx — не потрібен. | ✅ Вирішено | — |
| 8 | **SSO (MS365) перенесено в P0.** Реалізується через LoginSaml до Go-Live. Entra ID tenant та права на Enterprise Application повинні бути готові до Phase 2\. | ✅ Вирішено | — |

**Версія документу:** 1.2 — Березень 2026 **Наступний перегляд:** після Go-Live (T+21) **Maintainer:** DevOps / System Admin Team
