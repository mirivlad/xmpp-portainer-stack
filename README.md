# XMPP Portainer Stack

Готовый self-hosted XMPP-стек для Docker Compose / Portainer:

- **Prosody 13** — XMPP-сервер;
- **PostgreSQL 17** — SQL-хранилище Prosody;
- **coturn** — STUN/TURN для аудио/видеозвонков;
- **MUC** — групповые чаты (`conference.<domain>`);
- **HTTP File Share** — загрузка файлов (`share.<domain>`);
- **WebSocket / BOSH** — web-клиенты;
- **web registration** — регистрация пользователей;
- **web admin** — административный web-интерфейс;
- **nginx** — TLS termination и reverse proxy;
- **Let's Encrypt / certbot** — сертификат и автоматическое обновление сертификатов Prosody.

> Проект ориентирован прежде всего на обычный Linux-хост с Docker/Portainer и nginx на хостовой системе. Конфигурация coturn рассчитана в том числе на сервер, находящийся за NAT.

## Схема

```text
Internet
   |
   +-- TCP 80/443 --------> nginx --------> Prosody HTTP :5280
   |                                      |- /register
   |                                      |- /admin
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
- публичный IPv4 (прямой либо через NAT с пробросом портов);
- DNS-записи доменов XMPP, MUC, file share и TURN.

Автоматический `scripts/setup-host.sh` рассчитан на Linux-хост, где nginx читает `/etc/nginx/conf.d/*.conf` (в частности стандартные Debian/Ubuntu-конфигурации).

## DNS

Если основной XMPP-домен — `xmpp.example.org`, создайте записи:

| Имя | Тип | Значение |
|---|---|---|
| `xmpp.example.org` | A | публичный IPv4 сервера/NAT |
| `conference.xmpp.example.org` | A | тот же публичный IPv4 |
| `share.xmpp.example.org` | A | тот же публичный IPv4 |
| `turn.xmpp.example.org` | A | тот же публичный IPv4 |

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

**TURN relay range необходимо пробрасывать 1:1**, без перенумерации портов. Если вы изменили `TURN_MIN_PORT`/`TURN_MAX_PORT`, измените тот же диапазон на роутере и в firewall.

Наружу **не требуется** публиковать:

- `5280/tcp` — в compose он доступен только как `127.0.0.1:5280` для локального nginx;
- `5432/tcp` — PostgreSQL доступен только во внутренней Docker-сети;
- `5349/tcp/udp` — в этой конфигурации TURN TLS/DTLS отключены.

## Быстрый старт

### 1. Клонировать репозиторий

Рекомендуемый путь на хосте:

```bash
sudo git clone https://github.com/mirivlad/xmpp-portainer-stack.git /opt/xmpp-portainer-stack
cd /opt/xmpp-portainer-stack
```

### 2. Создать `.env`

```bash
sudo cp .env.example .env
sudo nano .env
```

Сгенерировать секреты можно, например, так:

```bash
openssl rand -hex 32
```

Не публикуйте `.env` и не добавляйте его в Git.

### 3. Подготовить nginx и сертификаты

После того как DNS уже указывает на сервер и порт 80 доступен снаружи:

```bash
sudo ./scripts/setup-host.sh
```

Скрипт:

1. проверит обязательные переменные и зависимости;
2. создаст ACME webroot;
3. временно установит HTTP-конфигурацию nginx для ACME;
4. получит SAN-сертификат Let's Encrypt для:
   - `${XMPP_DOMAIN}`;
   - `conference.${XMPP_DOMAIN}`;
   - `share.${XMPP_DOMAIN}`;
5. установит полный nginx reverse-proxy конфиг;
6. скопирует только нужные сертификаты в `CERT_SOURCE_DIR` для Prosody;
7. установит certbot deploy-hook, который после renew обновляет сертификаты Prosody и делает reload работающего контейнера.

Скрипт управляет только `/etc/nginx/conf.d/xmpp-portainer-stack.conf`. Если там уже находится чужой конфиг, он остановится и ничего не перезапишет.

Готовые шаблоны находятся в каталоге `nginx/` и могут использоваться вручную вместо скрипта.

### 4. Развернуть stack

#### Portainer

Создайте Stack, вставьте `docker-compose.yml` или подключите этот Git-репозиторий и добавьте значения из `.env` в Environment variables стека.

Важно: `CERT_SOURCE_DIR` — путь **на Docker-хосте**, подготовленный `setup-host.sh`.

#### Docker Compose

```bash
sudo docker compose up -d
```

### 5. Проверить

```bash
docker ps

docker logs xmpp-prosody
docker logs xmpp-turn

docker exec xmpp-prosody prosodyctl check config
docker exec xmpp-prosody prosodyctl check certs
docker exec xmpp-prosody prosodyctl check turn
```

## Переменные окружения

| Переменная | Пример | Назначение |
|---|---|---|
| `XMPP_DOMAIN` | `xmpp.example.org` | основной XMPP-домен |
| `XMPP_ADMIN_USER` | `admin` | имя первого администратора |
| `XMPP_ADMIN_PASSWORD` | `...` | пароль администратора |
| `POSTGRES_PASSWORD` | `...` | пароль БД Prosody |
| `LE_CERT_NAME` | `xmpp.example.org` | имя lineage сертификата certbot |
| `LE_EMAIL` | `admin@example.org` | email для Let's Encrypt |
| `TURN_SECRET` | `...` | общий secret Prosody/coturn |
| `TURN_LISTEN_IP` | `192.168.1.54` | локальный IP, на котором слушает coturn |
| `TURN_RELAY_IP` | `192.168.1.54` | локальный relay IP coturn |
| `TURN_EXTERNAL_IP` | `203.0.113.10` | публичный IPv4 NAT |
| `TURN_MIN_PORT` | `49160` | начало relay range |
| `TURN_MAX_PORT` | `49200` | конец relay range |
| `CERT_SOURCE_DIR` | `/var/lib/xmpp-portainer-stack/certs` | staging-каталог сертификатов для контейнера |

Для сервера за NAT coturn получает mapping вида:

```text
PUBLIC_IP/PRIVATE_RELAY_IP
```

из `TURN_EXTERNAL_IP` и `TURN_RELAY_IP`.

## Web endpoints

Для `XMPP_DOMAIN=xmpp.example.org`:

- регистрация: `https://xmpp.example.org/register`;
- web admin: `https://xmpp.example.org/admin`;
- WebSocket: `wss://xmpp.example.org/xmpp-websocket`;
- HTTP File Share: `https://share.xmpp.example.org/`.

## nginx

`nginx/xmpp.conf.template` — полный пример виртуальных хостов после выпуска сертификата.

`nginx/xmpp-http.conf.template` — минимальная конфигурация, используемая для первичного ACME HTTP-01 challenge.

Prosody HTTP-порт `5280` намеренно не публикуется в интернет: nginx подключается к `127.0.0.1:5280`.

Лимит загрузки nginx выставлен в `100m`, в соответствии с лимитом HTTP File Share в Prosody.

## Сертификаты

Контейнер Prosody **не получает read-доступ ко всему `/etc/letsencrypt` хоста**. `scripts/sync-certs.sh` копирует только:

```text
fullchain.pem
privkey.pem
```

нужного lineage в `CERT_SOURCE_DIR`. Этот каталог монтируется в контейнер read-only, после чего сертификат копируется в собственный volume Prosody для трех XMPP-hostnames.

При очередном `certbot renew` deploy-hook запускает `sync-certs.sh`; если `xmpp-prosody` работает, сертификаты обновляются внутри контейнера и выполняется `prosodyctl reload`.

## Хранилище

Используются named volumes:

- `xmpp_db` — PostgreSQL;
- `xmpp_data` — данные Prosody и community plugins;
- `xmpp_certs` — рабочие копии сертификатов Prosody.

Удаление контейнеров не удаляет эти данные. Не выполняйте `docker compose down -v`, если не хотите удалить volumes.

## Community modules

Стек использует `mod_admin_web2` и `mod_register_web` из Prosody Community Modules. Они устанавливаются автоматически в persistent storage Prosody при первом запуске.

Оба модуля имеют статус **Alpha**. Особенно осторожно относитесь к `/admin`: не считайте web-admin полноценной заменой защищенному административному доступу и при необходимости ограничьте этот location в nginx по IP/VPN.

`mod_admin_web2` для Prosody 13 также требует web-зависимости; entrypoint автоматически запускает поставляемый модулем `get_deps.sh` после первой установки.

## Регистрация

В XMPP отключена стандартная свободная in-band registration:

```lua
allow_registration = false
```

Регистрация предоставляется через `mod_register_web` по `/register` и ограничивается throttle-настройками.

По умолчанию используется шаблон самого community module. Если нужен собственный шаблон регистрации, см. комментарии в `docker-compose.yml` и документацию `mod_register_web`.

## Безопасность

- не публикуйте `.env`;
- PostgreSQL не выставлен наружу;
- Prosody HTTP доступен только через localhost/nginx;
- TURN использует long-term credentials, создаваемые Prosody через shared secret;
- административный community module имеет Alpha status — рекомендуется дополнительное ограничение `/admin` через nginx, VPN или firewall;
- следите за обновлениями Docker images и community modules.

## Обновление

```bash
git pull
docker compose pull
docker compose up -d
```

Для Portainer используйте обычный механизм redeploy/update stack.

---

Конфигурация основана на рабочем домашнем XMPP-развертывании и вынесена в переносимый шаблон без привязки к конкретным IP-адресам, доменам и путям пользователя.
