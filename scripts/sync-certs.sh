#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${1:-${ROOT_DIR}/.env}"

if [[ ! -r "${ENV_FILE}" ]]; then
  echo "Cannot read environment file: ${ENV_FILE}" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

: "${XMPP_DOMAIN:?XMPP_DOMAIN is required}"
: "${LE_CERT_NAME:?LE_CERT_NAME is required}"

CERT_SOURCE_DIR="${CERT_SOURCE_DIR:-/var/lib/xmpp-portainer-stack/certs}"
LE_LIVE_DIR="/etc/letsencrypt/live/${LE_CERT_NAME}"

if [[ ! -r "${LE_LIVE_DIR}/fullchain.pem" || ! -r "${LE_LIVE_DIR}/privkey.pem" ]]; then
  echo "Certificate files not found in ${LE_LIVE_DIR}" >&2
  exit 1
fi

install -d -m 0700 "${CERT_SOURCE_DIR}"
install -m 0644 -T "${LE_LIVE_DIR}/fullchain.pem" "${CERT_SOURCE_DIR}/fullchain.pem"
install -m 0600 -T "${LE_LIVE_DIR}/privkey.pem" "${CERT_SOURCE_DIR}/privkey.pem"

echo "Staged certificate in ${CERT_SOURCE_DIR}"

if ! command -v docker >/dev/null 2>&1; then
  exit 0
fi

if [[ "$(docker inspect -f '{{.State.Running}}' xmpp-prosody 2>/dev/null || true)" != "true" ]]; then
  echo "xmpp-prosody is not running; staged certificate will be imported on next container start."
  exit 0
fi

echo "Updating certificates inside xmpp-prosody..."
docker exec --user root xmpp-prosody /bin/bash -lc '
  set -euo pipefail
  test -r /cert-source/fullchain.pem
  test -r /cert-source/privkey.pem
  mkdir -p /etc/prosody/certs

  for host in "$XMPP_DOMAIN" "conference.$XMPP_DOMAIN" "share.$XMPP_DOMAIN"; do
    cp -L /cert-source/fullchain.pem "/etc/prosody/certs/$host.crt"
    cp -L /cert-source/privkey.pem "/etc/prosody/certs/$host.key"
  done

  chown -R prosody:prosody /etc/prosody/certs
  find /etc/prosody/certs -type f -name "*.crt" -exec chmod 0644 {} +
  find /etc/prosody/certs -type f -name "*.key" -exec chmod 0600 {} +

  prosodyctl check certs
  prosodyctl reload
'

echo "Prosody certificates reloaded."
