# XMPP Portainer Stack

Готовый самостоятельный XMPP-сервер на **Prosody 13 + PostgreSQL + Caddy + coturn**. Устанавливается как Docker Compose или Git stack в Portainer. Основной вариант не требует отдельно установленного Nginx, Certbot, ручного копирования сертификатов или файлов на Docker-хост.

- XMPP для клиентов и серверов (5222/5269);
- регистрация через красивую русскоязычную HTML-форму с CAPTCHA;
- история MAM, группы MUC, OMEMO в совместимых клиентах, WebSocket и BOSH;
- HTTP-загрузка файлов, TURN для звонков;
- веб-администрирование /admin за HTTP Basic Auth;
- **Caddy автоматически получает и продлевает сертификаты**, а Prosody импортирует их и подхватывает обновления;
- PostgreSQL и TURN получают случайные секреты из persistent Docker volume.

## 1. Что подготовить

Нужен Linux-сервер с Docker Engine и Docker Compose v2 (либо Portainer с Docker endpoint), публичный домен и доступный извне IP.

Для примера используем основной XMPP-домен `xmpp.example.org`. Создайте DNS-записи:

| Запись | Тип | Значение |
|---|---|---|
| `xmpp.example.org` | A | публичный IPv4 сервера |
| `share.xmpp.example.org` | A | тот же IPv4 |
| `conference.xmpp.example.org` | A | тот же IPv4 |
| `turn.xmpp.example.org` | A | тот же IPv4 |

Если есть публичный IPv6, добавьте AAAA **только когда он действительно доступен на сервере**. При использовании NAT перенаправьте порты с роутера.

Открыть на сервере/роутере: **TCP 80, 443, 5222, 5269, 3478**, **UDP 443, 3478, 49160–49200**. TCP/UDP 443 используются Caddy; UDP 3478 и relay-диапазон используются TURN. В первую очередь проверьте TCP 80/443 — без них автоматическая выдача сертификатов может не состояться.

**Важно:** стандартный стек занимает 80/443. Если там уже работает Nginx, Caddy или другой сервис, используйте другой сервер либо режим [за существующим Nginx](#если-nginx-уже-есть).

## 2. Docker Compose — установка за несколько команд

```bash
git clone https://github.com/mirivlad/xmpp-portainer-stack.git
cd xmpp-portainer-stack
cp .env.example .env
${EDITOR:-nano} .env
docker compose up -d
docker compose ps
```

В `.env` достаточно указать три значения:

```dotenv
XMPP_DOMAIN=xmpp.example.org
ACME_EMAIL=admin@example.org
XMPP_ADMIN_PASSWORD=ПРИДУМАЙТЕ_НАДЁЖНЫЙ_ПАРОЛЬ
```

`XMPP_ADMIN_USER` и `ADMIN_HTTP_USER` по умолчанию равны `admin`. Пароль нужен и для входа администратора XMPP, и для предварительной HTTP Basic Auth на `/admin`. Секреты PostgreSQL и TURN создаются автоматически, сохраняются в отдельном Docker volume и **не пересоздаются при обычном перезапуске**.

Во время первого старта `bootstrap` скачает из публичного GitHub-репозитория HTML-шаблоны и Caddyfile в Docker volumes. Затем Caddy запросит сертификаты Let's Encrypt; Prosody дождётся их появления и запустится. Первый запуск зависит от DNS, доступности портов и внешних серверов ACME. Для дополнительной предсказуемости укажите `ASSETS_REF` — тег релиза или SHA коммита вместо `main`.

### Проверка

```bash
docker compose ps
docker compose logs --tail=100 bootstrap caddy prosody
curl -IL https://xmpp.example.org/register/
curl -L https://xmpp.example.org/register/ | grep 'name="username"'
```

Проверьте, что форма открывается, и создайте тестовый аккаунт. Статус `healthy` у Prosody включает HTTP-проверку регистрации, а не только открытый порт 5222.

Адреса:
- главная: `https://xmpp.example.org/`;
- регистрация: `https://xmpp.example.org/register/`;
- администрирование: `https://xmpp.example.org/admin/`;
- HTTP upload: `https://share.xmpp.example.org/`;
- WebSocket: `wss://xmpp.example.org/xmpp-websocket`;
- BOSH: `https://xmpp.example.org/http-bind`.

В клиенте используйте JID `user@xmpp.example.org`; обычно клиент сам находит порт 5222. При необходимости настройте SRV-записи для делегирования XMPP, если JID-домен отличается от сетевого имени.

## 3. Portainer Community Edition — установка из GitHub

В Portainer откройте **Stacks → Add stack → Repository** и укажите:

- Repository URL: `https://github.com/mirivlad/xmpp-portainer-stack`
- Repository reference: `refs/heads/main`
- Compose path: `docker-compose.yml`

Добавьте Environment variables: `XMPP_DOMAIN`, `ACME_EMAIL`, `XMPP_ADMIN_PASSWORD` (и необязательные дополнительные параметры). Нажмите **Deploy the stack**.

**Не нужно** настраивать относительные bind mounts или самостоятельно копировать HTML. Для совместимости с Portainer CE `bootstrap` скачивает открытые ресурсы из GitHub и переносит их в **именованные Docker volumes**. Таким образом проект не зависит от расположения временного Git checkout в Portainer.

При обновлении стека из GitHub используйте **Pull and redeploy / Force redeployment**, чтобы `bootstrap` заново загрузил версии шаблонов. Данные PostgreSQL, Prosody, сертификаты Caddy и секреты остаются в именованных volumes. Не включайте «удалить тома» при обновлении.

## 4. Сертификаты — без ручного Certbot

Caddy сам проводит ACME-проверку для трёх HTTPS-имён (основной домен, `share.` и `conference.`), сохраняет ключи в volume `caddy_data` и продлевает сертификаты. Prosody **не использует самоподписанные сертификаты для публичного сервиса**: при старте ожидает действующие сертификаты Caddy, проверяет доменное имя и срок действия, затем копирует ключи в свой том. Проверка обновлений — раз в 30 минут с командой `prosodyctl reload`.

**Не удаляйте `caddy_data`, `xmpp_certs` и `runtime_secrets`** — эти тома входят в восстановление после сбоя. Для доменов с некорректным DNS Caddy не сможет получить сертификат; причина будет видна в `docker compose logs caddy`.

## 5. Звонки / TURN за NAT

coturn по умолчанию использует host networking на Linux. На сервере с собственным публичным IPv4 дополнительных IP-параметров не требуется. За NAT иногда необходимо указать:

```dotenv
TURN_EXTERNAL_IP=203.0.113.10
TURN_RELAY_IP=192.168.1.20
```

Первый — внешний адрес, второй — реальный локальный адрес сервера, а также необходимо пробросить UDP relay-диапазон 49160–49200. Для работы аудио/видеозвонков проверьте TURN извне, а не только локальный healthcheck. Компоненты браузерного HTTP/TURN не заменяют поддержку звонков со стороны XMPP-клиента.

## 6. Если Nginx уже есть

На сервере, где 80/443 уже заняты другим reverse proxy (как на нашем `tomas`), **не запускайте стандартный Compose параллельно** — будет конфликт портов.

Ранее использовавшийся комплект сохранён в `deploy/host-nginx/docker-compose.yml`, а образец переменных — в `deploy/host-nginx/.env.example`. Старые `scripts/*.sh` обслуживают **только** этот вариант. Для них обязательно явно задать `COMPOSE_FILE`:

```bash
cp deploy/host-nginx/.env.example .env
# заполнить домен, пути к сертификатам, TURN и пароли
export COMPOSE_FILE="$PWD/deploy/host-nginx/docker-compose.yml"
sudo --preserve-env=COMPOSE_FILE ./scripts/setup-host.sh
docker compose up -d
```

Установка через `scripts/setup-host.sh` требует Nginx, Certbot и root-доступа на хосте; для нового самостоятельного стека она **не нужна**. При переходе с прежнего Portainer stack нужно отдельно сверить volumes, сертификаты, пароли и параметры TURN. **Нельзя автоматически заменять существующий Compose**, иначе возникнет риск создания новой пустой базы рядом с рабочей.

## 7. Обслуживание и ограничения

- `docker compose up -d` — запуск / обновление сервисов;
- `docker compose logs -f caddy prosody` — диагностика ACME и регистрации;
- `docker compose exec prosody prosodyctl check config` — проверка Prosody;
- обязательно делайте резервные копии **Docker volumes**: `xmpp_db`, `xmpp_data`, `xmpp_certs`, `caddy_data`, `runtime_secrets` (а также шаблоны, если они изменялись вручную);
- HTML в `web/` и `register-templates/` версионируется в репозитории;
- базовые параметры регистрации и частоты создания учётных записей находятся в Compose.

Стек рассчитан на один Linux Docker host. Для Docker Swarm, Kubernetes и уже существующей БД требуется отдельная конфигурация. Реальную выдачу публичного сертификата можно проверить только на домене с рабочими DNS и внешним доступом к портам ACME.

## Лицензия

См. `LICENSE`.

## Поддержать разработчика / Support development

Если проект оказался полезен, вы можете добровольно поддержать его развитие. / If this project is useful to you, you can voluntarily support its development.

[![Угостить разработчика кофе / Buy me a coffee](https://img.shields.io/badge/Support-Buy%20me%20a%20coffee-7055a5?style=flat-square&logo=buymeacoffee&logoColor=white)](https://mirv.top/support/)
