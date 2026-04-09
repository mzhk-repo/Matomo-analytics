# Deployment Runbook — Phase 1

## 1. Призначення

Цей runbook описує перший запуск Matomo-стеку в межах `Phase 1 — Pre-Prod Foundation`.

## 2. Передумови

Перед запуском мають бути готові:

- Docker Engine і Docker Compose `>= 2.x`
- існуюча Docker network `proxy-net`
- працюючий Traefik у `proxy-net`
- зовнішній ingress/tunnel шар на сервері, який веде `analytics.mylibrary.edu` на `http://traefik:80`
- якщо TLS термінується до Traefik (наприклад Cloudflare Tunnel), прокинути до Matomo `X-Forwarded-Proto=https` (у цьому репо це робиться через labels `matomo-forwarded-*`)

## 3. Підготовка конфігурації

1. Скопіювати `.env.example` в `.env`.
2. Заповнити всі значення без `CHANGE_ME`.
3. Перевірити, що шляхи `VOL_DB_PATH`, `VOL_MATOMO_DATA`, `BACKUP_DIR` відповідають хосту.
4. Переконатися, що образи задаються через env-змінні:
   - `MARIADB_IMAGE`
   - `MATOMO_IMAGE`
   - `CRON_IMAGE`
5. Для SMTP-нотифікацій (MS365) задати в `.env`:
   - `SMTP_USER`
   - `SMTP_PASS`
   - (опційно) `MATOMO_CFG_SMTP_*` overrides; за замовчуванням використовується `smtp.office365.com:587`, `tls`, `Login`.

## 4. Обов'язкові локальні перевірки перед стартом

```bash
./scripts/verify-env.sh .env
./scripts/check-ports-policy.sh docker-compose.yaml
cp .env.example .env.tmp && docker compose --env-file .env.tmp -f docker-compose.yaml config --quiet && rm -f .env.tmp
```

Примітка: для реального запуску використовувати тільки справжній `.env`, не `.env.example`.

## 5. Перший запуск

```bash
./scripts/init-volumes.sh .env
docker compose up -d
docker compose ps
./scripts/apply-matomo-config.sh .env
```

Очікування для Phase 1:

- `matomo-db` має перейти в `healthy`
- `matomo-app` і `matomo-cron` мають бути `Up`
- стек не повинен відкривати публічні порти напряму
- базові налаштування `config.ini.php` застосовуються скриптом (IaC, без ручного редагування)

## 6. Первинна верифікація

Після старту перевірити:

```bash
docker compose ps
docker compose logs --tail=100
```

Що перевіряємо:

- `matomo-db` healthy
- `matomo-app` стартує без помилок підключення до БД
- `matomo-cron` стартує коректно
- Traefik бачить router/service для Matomo за labels

### 6.1 Troubleshooting: нескінченні 302 редіректи

Симптом:

- запити до `https://<MATOMO_HOST>/` постійно повертають `302` з `Location: https://<MATOMO_HOST>/`

Причина:

- `force_ssl=1` у Matomo увімкнений, але до застосунку не доходить `X-Forwarded-Proto=https`

Що перевірити:

```bash
curl -sSIL --max-redirs 5 "https://${MATOMO_HOST}"
```

Якщо бачите цикл `302`, перевірити що в `docker-compose.yaml` активні middleware:

- `matomo-forwarded-https`
- `matomo-forwarded-port`

Після змін зробити redeploy стеку.

## 7. Matomo Installation Wizard

Після доступності `https://analytics.mylibrary.edu`:

1. пройти Installation Wizard;
2. створити SuperUser;
3. завершити первинну ініціалізацію;
4. переконатися, що `config/config.ini.php` збережено у volume `VOL_MATOMO_DATA`.

## 8. Що ще не входить у Phase 1

На цьому етапі не виконуємо:

- Koha integration
- DSpace integration
- privacy settings в Matomo UI
- CSP rollout
- production backup execution
- SSO configuration

## 9. Rollback

Базовий rollback для Phase 1:

```bash
docker compose down
```

Якщо треба відкотити зміни у файлах репозиторію, використовувати git-процес окремо. Дані у volumes не видаляються автоматично.

## 10. Поточні обмеження

- `backup.sh` і `restore.sh` реалізовані; для фактичного backup/upload/restore потрібні валідні `.env`, доступ до Docker daemon і налаштований `rclone` remote.
- `check-disk.sh` готовий для локального/cron використання, але нотифікації ще не додані.
- Успішний `docker compose up -d` залежить від реального `.env`, наявності `proxy-net` і готової зовнішньої маршрутизації до `http://traefik:80`.

## 10.1 Swarm Redeploy (Phase 6+)

Для Swarm не використовувати прямий:

```bash
docker stack deploy -c docker-compose.yaml -c docker-compose.swarm.yml matomo
```

Причина: `docker stack deploy` напряму не обробляє compose-merge/`!reset` так само, як `docker compose config`, через що можуть "просочуватись" compose-only поля (наприклад `mem_limit`).

Канонічний шлях:

```bash
./scripts/deploy-orchestrator.sh --swarm matomo
```

Що робить скрипт:
- рендерить merged manifest (`docker compose config`);
- прибирає top-level `name:`;
- нормалізує Swarm-сумісність (`published` як integer, видалення `host_ip`);
- виконує `docker stack deploy` тільки по підготовленому manifest.

## 11. SSO (Phase 2.6) — LoginOIDC + Microsoft Entra ID

### 11.1 Поточний технічний стан

- `LoginOIDC` встановлено у `plugins/LoginOIDC` і активовано в Matomo.
- У `config/config.ini.php` виставлено:
  - `login_allow_signup = 0`
  - `login_allow_reset_password = 0`
- Публічний домен Matomo: `https://matomo.pinokew.buzz`.
- Локальний fallback-адмін збережено (політика rollback-доступу).

### 11.2 Entra ID App Registration (OIDC)

1. Entra Admin Center → **App registrations** → **New registration**.
2. Name: `Matomo Analytics`.
3. Supported account types: `Accounts in this organizational directory only`.
4. Redirect URI (Web):
   - `https://matomo.pinokew.buzz/index.php?module=LoginOIDC&action=callback&provider=oidc`
5. Після створення зберегти:
   - `Application (client) ID`
   - `Directory (tenant) ID`
6. Certificates & secrets → створити `Client secret` і зберегти **Secret Value** (не `Secret ID`).
7. API permissions:
   - `openid`
   - `profile`
   - `email`
   - (за потреби) `offline_access`
8. Authentication → ID tokens = Enabled.

### 11.3 Matomo LoginOIDC налаштування

В Matomo: Administration → Plugins → LoginOIDC:

- Provider name: `Entra ID`
- Client ID: `<Application (client) ID>`
- Client Secret: `<Client secret value>`
- Authorize URL:
   - `https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/authorize`
- Token URL:
   - `https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/token`
- Userinfo URL:
   - `https://graph.microsoft.com/oidc/userinfo`
- Userinfo ID: `email`
- Scopes: `openid profile email`
- Redirect URI override: залишити порожнім (вмикати тільки якщо є нестандартний reverse-proxy сценарій)
- Auto linking: увімкнути
- Auto create users (OAuth signup): вимкнути
- Onboarding нових користувачів: через `UsersManager.inviteUser`, після чого OIDC виконує автопривʼязку до існуючого login/email

Критично важливо: LoginOIDC очікує callback з параметром `provider=oidc`, тому Redirect URI в Entra має збігатися **1-в-1** з:

Примітка: Microsoft Graph `/oidc/userinfo` повертає поля `sub`, `name`, `family_name`, `given_name`, `email` — але **не** `preferred_username`. Тому для Entra в нашій моделі використовується `userinfoId=email` + `autoLinking=ON`. При вимкненому `allowSignup` вхід працює для вже запрошених (inviteUser) користувачів, login яких збігається з корпоративним email.

- `https://matomo.pinokew.buzz/index.php?module=LoginOIDC&action=callback&provider=oidc`

### 11.4 Тестовий сценарій (обовʼязково)

Провести вхід через OIDC для:

- 

Перевірити:

1. Кнопка OIDC логіну доступна на сторінці входу.
2. Обидва акаунти проходять логін без помилок callback/state.
3. Якщо акаунт входить вперше і `Auto create users` увімкнено, користувач створюється автоматично.
4. Локальний fallback-адмін все ще може увійти через стандартний логін.

### 11.5 Rollback

Якщо OIDC нестабільний:

```bash
docker compose exec -T matomo-app php /var/www/html/console plugin:deactivate LoginOIDC
```

Після rollback перевірити доступність входу fallback-адміном.

### 11.6 Runbook: створення нових користувачів і надання прав

Рекомендований шлях: **UsersManager API (POST)**.

Передумови:

- у `.env` заданий валідний `TOKEN_AUTH` користувача з правами керування користувачами;
- API-виклики робимо через `POST` (для деяких токенів `GET` може повертати auth error);
- для OIDC-сценарію `login` і `email` мають збігатися з корпоративним email.

1. Перевірити токен:

```bash
source .env
curl -sS -X POST "https://${MATOMO_HOST}/index.php" \
   -d "module=API&format=JSON&method=UsersManager.getUsersLogin&token_auth=${TOKEN_AUTH}"
```

2. Створити **звичайного** користувача через invite (рекомендовано для OIDC):

```bash
source .env
curl -sS -X POST "https://${MATOMO_HOST}/index.php" \
   -d "module=API&format=JSON&method=UsersManager.inviteUser&userLogin=user@ldubgd.edu.ua&email=user@ldubgd.edu.ua&initialIdSite=1&token_auth=${TOKEN_AUTH}"
```

Примітка: якщо токен не superuser, параметр `initialIdSite` є обовʼязковим.

3. Надати права superuser (за потреби):

```bash
source .env
curl -sS -X POST "https://${MATOMO_HOST}/index.php" \
   -d "module=API&format=JSON&method=UsersManager.setSuperUserAccess&userLogin=user@ldubgd.edu.ua&hasSuperUserAccess=1&token_auth=${TOKEN_AUTH}"
```

4. Валідація:

```bash
source .env
curl -sS -X POST "https://${MATOMO_HOST}/index.php" \
   -d "module=API&format=JSON&method=UsersManager.getUsersHavingSuperUserAccess&token_auth=${TOKEN_AUTH}"
```

UI-alternative: `Administration → Users` (ручне створення/видача ролей).

CLI/DB fallback (аварійно, коли API/UI недоступні): використовувати тільки тимчасово з подальшою синхронізацією через UsersManager API.

Важливо: у Matomo 5 локальна перевірка пароля використовує формат `password_verify(md5(<plain_password>), stored_hash)`. Тому при ручному SQL-оновленні пароля потрібно зберігати `password_hash(md5(password))`, а не `password_hash(password)`.

Приклад генерації правильного хешу:

```bash
docker compose exec -T matomo-app php -r "echo password_hash(md5('TEMP_PASSWORD'), PASSWORD_DEFAULT), PHP_EOL;"
```
