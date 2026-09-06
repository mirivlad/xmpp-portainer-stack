# XMPP Portainer Stack

Готовый self-hosted XMPP deployment kit для Docker Compose / Portainer:

- **Prosody `latest`** — последняя стабильная версия XMPP-сервера;
- **PostgreSQL 17** — SQL-хранилище Prosody;
- **coturn** — STUN/TURN для аудио/видеозвонков;
- **MUC** — групповые чаты (`conference.<domain>`);
- **HTTP File Share** — загрузка файлов (`share.<domain>`);
- **WebSocket / BOSH** — web-клиенты;
- **web registration** — регистрация пользователей;
- **web admin** — административный web-интерфейс с дополнительным nginx Basic Auth;
- **nginx** — TLS termination и reverse proxy;
- **Let's Encrypt / certbot** — сертификаты и автоматическое обновление сертификатов Prosody;
- **init / doctor / backup / restore / update scripts** — подготовка и эксплуатация сервера.

Проект ориентирован прежде всего на обычный Linux-хост с Docker/Portainer и nginx на хостовой системе. Конфигурация coturn рассчитана в том числе на сервер за NAT.

## Схема

```text
Internet
   |
   +-- TCP 80/443 --------> nginx --------> Prosody HTTP :5280
   |                                      |- /register
   |                                      |- /admin  (nginx Basic Auth + XMPP login)
   |                                      |- /xmpp-websocket
   |                                      `- HTTP file share
   |
   +-- TCP 5222 ----------> Prosody       XMPP clients
   +-- TCP 5269 ----------> Prosody       XMPP federation
   |
   +-- UDP/TCP 3478 ------> coturn        STUN/TURN
   `-- UDP relay range ---> coturn        TURN media relay

Prosody <----> PostgreSQL
```

## Требования

На хосте должны быть установлены:

- Docker Engine и Docker Compose plugin либо Portainer;
- nginx;
- certbot;
- openssl;
- `htpasswd` (`apache2-utils` в Debian/Ubuntu);
- публичный IPv4 напрямую или через NAT;
- DNS-записи для XMPP, MUC, file share и TURN.

Автоматический `scripts/setup-host.sh` рассчитан на Linux-хост, где nginx читает `/etc/nginx/conf.d/*.conf`.

## DNS

Если основной XMPP-домен — `xmpp.example.org`, создайте A-записи:

| Имя | Значение |
|---|---|
| `xmpp.example.org` | публичный IPv4 сервера/NAT |
| `conference.xmpp.example.org` | тот же IPv4 |
| `share.xmpp.example.org` | тот же IPv4 |
| `turn.xmpp.example.org` | тот же IPv4 |

При использовании стандартных XMPP-портов отдельные SRV-записи для этой схемы не обязательны.

## Порты и NAT

Если XMPP-хост находится за NAT, пробросьте:

| WAN-порт | Протокол | LAN-порт | Назначение |
|---:|:---:|---:|---|
| 80 | TCP | 80 | nginx / ACME HTTP-01 / redirect на HTTPS |
| 443 | TCP | 443 | nginx / HTTPS / WebSocket / HTTP File Share |
| 5222 | TCP | 5222 | XMPP client-to-server |
| 5269 | TCP | 5269 | XMPP server-to-server / federation |
| 3478 | UDP | 3478 | STUN/TURN |
| 3478 | TCP | 3478 | TURN over TCP |
| 49160-49200 | UDP | 49160-49200 | TURN relay range |

**TURN relay range необходимо пробрасывать 1:1**, без перенумерации портов. Если изменены `TURN_MIN_PORT`/`TURN_MAX_PORT`, тот же диапазон нужно изменить на роутере и в firewall.

Наружу не требуется публиковать:

- `5280/tcp` — он привязан только к `127.0.0.1` для локального nginx;
- `5432/tcp` — PostgreSQL находится только во внутренней Docker-сети;
- `5349/tcp/udp` — TURN TLS/DTLS в базовой конфигурации пока отключены.

## Быстрый старт

### 1. Клонировать репозиторий

```bash
sudo git clone https://github.com/mirivlad/xmpp-portainer-stack.git /opt/xmpp-portainer-stack
cd /opt/xmpp-portainer-stack
```

### 2. Сгенерировать конфигурацию

Рекомендуемый путь:

```bash
sudo ./scripts/init-config.sh
```

Скрипт спросит домен, email Let's Encrypt, публичный и локальный TURN IP, имена администраторов и автоматически сгенерирует независимые случайные секреты для:

- XMPP admin;
- nginx Basic Auth;
- PostgreSQL;
- TURN.

`.env` создается с правами `0600` и исключен из Git.

Для ручной настройки можно вместо этого скопировать `.env.example` в `.env`.

### 3. Подготовить хост

После того как DNS уже указывает на сервер и TCP/80 доступен снаружи:

```bash
sudo ./scripts/setup-host.sh
```

Скрипт:

1. проверяет переменные и зависимости;
2. готовит ACME webroot и nginx bootstrap-конфиг;
3. получает SAN-сертификат для `${XMPP_DOMAIN}`, `conference.${XMPP_DOMAIN}` и `share.${XMPP_DOMAIN}`;
4. создает bcrypt `htpasswd` для `/admin`;
5. создает защищенные `0600` файлы TURN secret и coturn config;
6. устанавливает полный nginx reverse proxy;
7. копирует только нужный LE certificate/key в staging-каталог Prosody;
8. устанавливает certbot deploy-hook для автоматического обновления сертификатов Prosody.

Скрипт управляет только `/etc/nginx/conf.d/xmpp-portainer-stack.conf`. Чужой файл по этому пути он не перезапишет.

### 4. Развернуть stack

Docker Compose:

```bash
sudo docker compose up -d --pull always
```

В Portainer можно использовать Git repository stack. Переменные из `.env` должны быть добавлены в Environment variables, а host paths `CERT_SOURCE_DIR`, `TURN_SECRET_FILE` и `TURN_CONFIG_FILE` должны совпадать с путями, подготовленными `setup-host.sh`.

### 5. Проверить установку

```bash
sudo ./scripts/doctor.sh
```

`doctor.sh` проверяет:

- обязательные переменные и host tools;
- DNS четырех hostnames;
- срок действия и SAN сертификата;
- `nginx -t`;
- наличие Basic Auth на `/admin`;
- staging TURN secret/config и их permissions;
- отсутствие TURN secret в Docker container metadata;
- состояние контейнеров и PostgreSQL;
- `prosodyctl check config`, `certs`, `dns`, `turn`, `features`;
- локальные XMPP/HTTP/TURN listeners;
- HTTPS `/admin` и `/register`.

В конце выводится `OK / WARN / FAIL`. Внешний NAT и TURN relay range все равно нужно хотя бы один раз проверить из другой сети.

## Web endpoints

Для `XMPP_DOMAIN=xmpp.example.org`:

- регистрация: `https://xmpp.example.org/register`;
- web admin: `https://xmpp.example.org/admin`;
- WebSocket: `wss://xmpp.example.org/xmpp-websocket`;
- HTTP File Share: `https://share.xmpp.example.org/`.

`/admin` защищен двумя слоями: сначала nginx HTTP Basic Auth (`ADMIN_HTTP_USER` / `ADMIN_HTTP_PASSWORD`), затем собственная XMPP-аутентификация web-admin.

## Переменные окружения

| Переменная | Назначение |
|---|---|
| `XMPP_DOMAIN` | основной XMPP-домен |
| `XMPP_ADMIN_USER` | XMPP admin username |
| `XMPP_ADMIN_PASSWORD` | пароль XMPP admin |
| `ADMIN_HTTP_USER` | nginx Basic Auth user для `/admin` |
| `ADMIN_HTTP_PASSWORD` | nginx Basic Auth password |
| `ADMIN_HTPASSWD_FILE` | host path файла htpasswd |
| `POSTGRES_PASSWORD` | пароль БД Prosody |
| `LE_CERT_NAME` | имя certbot lineage |
| `LE_EMAIL` | email Let's Encrypt |
| `CERT_SOURCE_DIR` | staging certificate/key для Prosody |
| `TURN_SECRET` | общий Prosody/coturn shared secret |
| `TURN_SECRET_FILE` | host staging-файл TURN secret |
| `TURN_CONFIG_FILE` | host path с coturn config |
| `TURN_LISTEN_IP` | локальный IP coturn |
| `TURN_RELAY_IP` | локальный relay IP coturn |
| `TURN_EXTERNAL_IP` | публичный IPv4 NAT |
| `TURN_MIN_PORT` | начало relay range |
| `TURN_MAX_PORT` | конец relay range |

Для сервера за NAT coturn получает mapping `PUBLIC_IP/PRIVATE_RELAY_IP`.

## Prosody и community modules

`prosodyim/prosody:latest` используется намеренно: официальный образ Prosody определяет `latest` как последнюю стабильную версию. Compose использует `pull_policy: always`, поэтому при redeploy/pull подтягиваются свежие stable/security fixes.

Чтобы это не делало остальной стек недетерминированным, community modules зафиксированы отдельно:

- `mod_admin_web2` — `2-1`;
- `mod_register_web` — `47-1`.

Они устанавливаются из конкретных `.src.rock` URL в persistent Prosody storage. При изменении pin entrypoint обновит нужный модуль.

Оба модуля имеют Alpha status. Поэтому `/admin` дополнительно закрыт nginx Basic Auth.

## TURN secret

TURN secret больше не передается в command line coturn и не хранится как environment variable контейнера Prosody. `setup-host.sh` создает два host-файла с правами `0600`:

```text
/var/lib/xmpp-portainer-stack/turn-secret
/var/lib/xmpp-portainer-stack/turnserver.conf
```

Prosody читает secret из read-only bind mount при старте, а coturn получает read-only config file. `doctor.sh` дополнительно проверяет, что значение secret не присутствует в persistent Docker container metadata.

## Сертификаты

Prosody не получает доступ ко всему `/etc/letsencrypt`. `scripts/sync-certs.sh` копирует только `fullchain.pem` и `privkey.pem` нужного lineage в `CERT_SOURCE_DIR`.

После `certbot renew` deploy-hook обновляет сертификаты внутри работающего Prosody и выполняет `prosodyctl reload`.

## Backup

Создать backup вручную:

```bash
sudo ./scripts/backup.sh
```

По умолчанию архив сохраняется в `/var/backups/xmpp-portainer-stack/` с правами `0600`.

Backup содержит:

- PostgreSQL dump;
- `/var/lib/prosody` (включая persistent community modules и Prosody data);
- deployment `.env`;
- metadata с версиями/ID образов.

Prosody кратковременно останавливается на время согласованного снимка DB + data, затем автоматически запускается снова.

**Backup содержит секреты из `.env`. Храните его как секретный файл.**

## Restore / Disaster Recovery

На новом хосте клонируйте этот репозиторий и выполните:

```bash
sudo ./scripts/restore.sh /path/to/xmpp-portainer-stack-YYYYMMDDTHHMMSSZ.tar.gz
```

Restore восстанавливает `.env`, PostgreSQL и `/var/lib/prosody`. После восстановления заново подготовьте host-specific nginx/certbot/TURN files:

```bash
sudo ./scripts/setup-host.sh
sudo docker compose up -d --pull always
sudo ./scripts/doctor.sh
```

Если на новом хосте другой публичный/локальный IP или домен, сначала поправьте восстановленный `.env` перед `setup-host.sh`.

## Обновление

Для обычного Docker Compose deployment используйте backup-first workflow:

```bash
cd /opt/xmpp-portainer-stack
sudo git pull
sudo ./scripts/update.sh
```

`update.sh` делает backup, обновляет host-generated files, подтягивает свежие Docker images, пересоздает services и запускает `doctor.sh`.

При ошибке обновления скрипт не пытается вслепую откатывать новый major Prosody поверх уже измененных данных. Он останавливается, сохраняет pre-update backup и оставляет явный путь восстановления через `restore.sh`.

Для Portainer перед redeploy также рекомендуется запустить `backup.sh`, затем redeploy с pull latest image и после него `doctor.sh` на Docker-хосте.

## Миграция существующего `.env`

Если стек уже использовался до появления Basic Auth/TURN staging, добавьте в `.env`:

```env
ADMIN_HTTP_USER=admin
ADMIN_HTTP_PASSWORD=<new-random-password>
ADMIN_HTPASSWD_FILE=/etc/nginx/.htpasswd-xmpp-admin
TURN_SECRET_FILE=/var/lib/xmpp-portainer-stack/turn-secret
TURN_CONFIG_FILE=/var/lib/xmpp-portainer-stack/turnserver.conf
```

После этого обязательно выполните:

```bash
sudo ./scripts/setup-host.sh
sudo docker compose up -d --pull always
sudo ./scripts/doctor.sh
```

## Что пока намеренно не включено

Следующие улучшения планируются отдельно, потому что меняют сетевой/пользовательский контракт стека:

- режим регистрации `open / invite / disabled`;
- TURN TLS (`turns`, порт 5349);
- раздельные `JID_DOMAIN` и `XMPP_HOST` с генерацией SRV-записей;
- полноценный внешний integration test TURN/NAT из второй сети.

## Лицензия

MIT License. См. `LICENSE`.

---

Конфигурация основана на рабочем домашнем XMPP-развертывании и вынесена в переносимый deployment kit без привязки к конкретным IP-адресам, доменам и путям пользователя.
