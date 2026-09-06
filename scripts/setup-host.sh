#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${1:-${ROOT_DIR}/.env}"

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root, for example: sudo ./scripts/setup-host.sh" >&2
  exit 1
fi

if [[ ! -r "${ENV_FILE}" ]]; then
  echo "Cannot read ${ENV_FILE}. Copy .env.example to .env and edit it first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

required_vars=(
  XMPP_DOMAIN
  XMPP_ADMIN_PASSWORD
  POSTGRES_PASSWORD
  LE_CERT_NAME
  LE_EMAIL
  TURN_SECRET
  TURN_LISTEN_IP
  TURN_RELAY_IP
  TURN_EXTERNAL_IP
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" || "${!var}" == "CHANGE_ME" ]]; then
    echo "Set ${var} in ${ENV_FILE}" >&2
    exit 1
  fi
done

if [[ ! "${XMPP_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "XMPP_DOMAIN contains unsupported characters: ${XMPP_DOMAIN}" >&2
  exit 1
fi

if [[ ! "${LE_CERT_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "LE_CERT_NAME contains unsupported characters: ${LE_CERT_NAME}" >&2
  exit 1
fi

TURN_MIN_PORT="${TURN_MIN_PORT:-49160}"
TURN_MAX_PORT="${TURN_MAX_PORT:-49200}"
CERT_SOURCE_DIR="${CERT_SOURCE_DIR:-/var/lib/xmpp-portainer-stack/certs}"
ACME_WEBROOT="${ACME_WEBROOT:-/var/www/xmpp-acme}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/conf.d/xmpp-portainer-stack.conf}"

if ! [[ "${TURN_MIN_PORT}" =~ ^[0-9]+$ && "${TURN_MAX_PORT}" =~ ^[0-9]+$ ]]; then
  echo "TURN_MIN_PORT and TURN_MAX_PORT must be numeric." >&2
  exit 1
fi

if (( TURN_MIN_PORT < 1024 || TURN_MAX_PORT > 65535 || TURN_MIN_PORT > TURN_MAX_PORT )); then
  echo "Invalid TURN relay range: ${TURN_MIN_PORT}-${TURN_MAX_PORT}" >&2
  exit 1
fi

for cmd in nginx certbot openssl install sed; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Required command not found: ${cmd}" >&2
    exit 1
  fi
done

if [[ -e "${NGINX_CONF}" ]] && ! grep -q '^# Managed by xmpp-portainer-stack' "${NGINX_CONF}"; then
  echo "Refusing to overwrite unmanaged nginx config: ${NGINX_CONF}" >&2
  echo "Move it away, merge nginx/xmpp.conf.template manually, or set NGINX_CONF to another path." >&2
  exit 1
fi

mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge"
chmod 0755 "${ACME_WEBROOT}" "${ACME_WEBROOT}/.well-known" "${ACME_WEBROOT}/.well-known/acme-challenge"
mkdir -p "$(dirname -- "${NGINX_CONF}")"

render_template() {
  local src="$1"
  local dst="$2"

  sed \
    -e "s|__XMPP_DOMAIN__|${XMPP_DOMAIN}|g" \
    -e "s|__LE_CERT_NAME__|${LE_CERT_NAME}|g" \
    -e "s|__ACME_WEBROOT__|${ACME_WEBROOT}|g" \
    "${src}" > "${dst}"
}

reload_nginx() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet nginx; then
      systemctl reload nginx
    else
      systemctl start nginx
    fi
  else
    if [[ -r /run/nginx.pid ]]; then
      nginx -s reload
    else
      nginx
    fi
  fi
}

install_nginx_config() {
  local rendered="$1"
  local backup=""

  if [[ -e "${NGINX_CONF}" ]]; then
    backup="$(mktemp)"
    cp -a "${NGINX_CONF}" "${backup}"
  fi

  install -m 0644 -T "${rendered}" "${NGINX_CONF}"

  if ! nginx -t; then
    echo "nginx configuration test failed; restoring previous configuration." >&2
    if [[ -n "${backup}" ]]; then
      cp -a "${backup}" "${NGINX_CONF}"
      rm -f "${backup}"
    else
      rm -f "${NGINX_CONF}"
    fi
    nginx -t || true
    exit 1
  fi

  if [[ -n "${backup}" ]]; then
    rm -f "${backup}"
  fi
  reload_nginx
}

CERT_DIR="/etc/letsencrypt/live/${LE_CERT_NAME}"
CERT_FILE="${CERT_DIR}/fullchain.pem"
KEY_FILE="${CERT_DIR}/privkey.pem"

cert_has_required_names() {
  [[ -r "${CERT_FILE}" && -r "${KEY_FILE}" ]] || return 1

  local sans
  sans="$(openssl x509 -in "${CERT_FILE}" -noout -ext subjectAltName 2>/dev/null || true)"

  for name in \
    "${XMPP_DOMAIN}" \
    "conference.${XMPP_DOMAIN}" \
    "share.${XMPP_DOMAIN}"; do
    grep -Fq "DNS:${name}" <<<"${sans}" || return 1
  done
}

cert_is_fresh() {
  [[ -r "${CERT_FILE}" && -r "${KEY_FILE}" ]] || return 1
  openssl x509 -in "${CERT_FILE}" -noout -checkend 86400 >/dev/null 2>&1
}

TMP_HTTP="$(mktemp)"
TMP_FINAL="$(mktemp)"
trap 'rm -f "${TMP_HTTP:-}" "${TMP_FINAL:-}"' EXIT

if cert_has_required_names && cert_is_fresh; then
  echo "Existing certificate ${LE_CERT_NAME} covers all required names and is valid."
else
  echo "Installing temporary HTTP nginx configuration for ACME..."
  render_template "${ROOT_DIR}/nginx/xmpp-http.conf.template" "${TMP_HTTP}"
  install_nginx_config "${TMP_HTTP}"

  certbot_args=(
    certonly
    --webroot
    --webroot-path "${ACME_WEBROOT}"
    --cert-name "${LE_CERT_NAME}"
    --domain "${XMPP_DOMAIN}"
    --domain "conference.${XMPP_DOMAIN}"
    --domain "share.${XMPP_DOMAIN}"
    --email "${LE_EMAIL}"
    --agree-tos
    --non-interactive
  )

  if [[ -r "${CERT_FILE}" ]]; then
    if cert_has_required_names; then
      certbot_args+=(--force-renewal)
    else
      certbot_args+=(--expand)
    fi
  fi

  echo "Requesting/updating Let's Encrypt certificate ${LE_CERT_NAME}..."
  certbot "${certbot_args[@]}"

  if ! cert_has_required_names || ! cert_is_fresh; then
    echo "The resulting certificate is missing a required SAN or is not currently valid." >&2
    exit 1
  fi
fi

echo "Installing full nginx reverse proxy configuration..."
render_template "${ROOT_DIR}/nginx/xmpp.conf.template" "${TMP_FINAL}"
install_nginx_config "${TMP_FINAL}"

export CERT_SOURCE_DIR TURN_MIN_PORT TURN_MAX_PORT
bash "${ROOT_DIR}/scripts/sync-certs.sh" "${ENV_FILE}"

HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
HOOK_FILE="${HOOK_DIR}/xmpp-portainer-stack.sh"
mkdir -p "${HOOK_DIR}"

{
  echo '#!/usr/bin/env bash'
  printf 'if [[ -n "${RENEWED_LINEAGE:-}" && "${RENEWED_LINEAGE}" != %q ]]; then exit 0; fi\n' "${CERT_DIR}"
  printf 'exec bash %q %q\n' "${ROOT_DIR}/scripts/sync-certs.sh" "${ENV_FILE}"
} > "${HOOK_FILE}"
chmod 0755 "${HOOK_FILE}"

echo
echo "Host preparation complete."
echo "nginx config:      ${NGINX_CONF}"
echo "certificate:       ${CERT_DIR}"
echo "Prosody cert copy: ${CERT_SOURCE_DIR}"
echo "certbot hook:      ${HOOK_FILE}"
echo
echo "Next: deploy docker-compose.yml in Portainer or run:"
echo "  cd ${ROOT_DIR} && docker compose up -d"
echo
echo "After Prosody starts, verify:"
echo "  docker exec xmpp-prosody prosodyctl check config"
echo "  docker exec xmpp-prosody prosodyctl check certs"
echo "  docker exec xmpp-prosody prosodyctl check turn"
