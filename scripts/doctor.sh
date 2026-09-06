#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${1:-${ROOT_DIR}/.env}"

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

ok() {
  OK_COUNT=$((OK_COUNT + 1))
  printf 'OK    %s\n' "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf 'WARN  %s\n' "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL  %s\n' "$*"
}

if [[ ! -r "${ENV_FILE}" ]]; then
  echo "Cannot read ${ENV_FILE}." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

XMPP_ADMIN_USER="${XMPP_ADMIN_USER:-admin}"
ADMIN_HTTP_USER="${ADMIN_HTTP_USER:-admin}"
ADMIN_HTPASSWD_FILE="${ADMIN_HTPASSWD_FILE:-/etc/nginx/.htpasswd-xmpp-admin}"
TURN_SECRET_FILE="${TURN_SECRET_FILE:-/var/lib/xmpp-portainer-stack/turn-secret}"
TURN_CONFIG_FILE="${TURN_CONFIG_FILE:-/var/lib/xmpp-portainer-stack/turnserver.conf}"
TURN_MIN_PORT="${TURN_MIN_PORT:-49160}"
TURN_MAX_PORT="${TURN_MAX_PORT:-49200}"

printf 'XMPP Portainer Stack doctor\n'
printf 'Domain: %s\n\n' "${XMPP_DOMAIN:-<unset>}"

for var in XMPP_DOMAIN XMPP_ADMIN_PASSWORD ADMIN_HTTP_PASSWORD POSTGRES_PASSWORD LE_CERT_NAME LE_EMAIL TURN_SECRET TURN_LISTEN_IP TURN_RELAY_IP TURN_EXTERNAL_IP; do
  if [[ -n "${!var:-}" && "${!var}" != "CHANGE_ME" ]]; then
    ok "environment: ${var}"
  else
    fail "environment: ${var} is missing or unchanged"
  fi
done

for cmd in docker nginx openssl getent; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    ok "command: ${cmd}"
  else
    fail "command not found: ${cmd}"
  fi
done

if command -v htpasswd >/dev/null 2>&1; then
  ok "command: htpasswd"
else
  warn "htpasswd not installed; setup-host.sh needs apache2-utils on Debian/Ubuntu"
fi

if [[ -n "${XMPP_DOMAIN:-}" ]]; then
  for host in "${XMPP_DOMAIN}" "conference.${XMPP_DOMAIN}" "share.${XMPP_DOMAIN}" "turn.${XMPP_DOMAIN}"; do
    addresses="$(getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
    if [[ -z "${addresses}" ]]; then
      fail "DNS: ${host} has no IPv4 address"
    elif [[ -n "${TURN_EXTERNAL_IP:-}" ]] && grep -qw -- "${TURN_EXTERNAL_IP}" <<<"${addresses}"; then
      ok "DNS: ${host} -> ${TURN_EXTERNAL_IP}"
    else
      warn "DNS: ${host} -> ${addresses}(expected public IP ${TURN_EXTERNAL_IP:-unknown})"
    fi
  done
fi

CERT_FILE="/etc/letsencrypt/live/${LE_CERT_NAME:-missing}/fullchain.pem"
if [[ -r "${CERT_FILE}" ]]; then
  if openssl x509 -in "${CERT_FILE}" -noout -checkend 1209600 >/dev/null 2>&1; then
    ok "certificate is valid for at least 14 more days"
  else
    warn "certificate expires within 14 days or is invalid"
  fi

  sans="$(openssl x509 -in "${CERT_FILE}" -noout -ext subjectAltName 2>/dev/null || true)"
  for host in "${XMPP_DOMAIN:-}" "conference.${XMPP_DOMAIN:-}" "share.${XMPP_DOMAIN:-}"; do
    if [[ -n "${host}" ]] && grep -Fq "DNS:${host}" <<<"${sans}"; then
      ok "certificate SAN: ${host}"
    else
      fail "certificate SAN missing: ${host}"
    fi
  done
else
  fail "certificate not readable: ${CERT_FILE}"
fi

if nginx -t >/tmp/xmpp-stack-nginx-doctor.log 2>&1; then
  ok "nginx configuration"
else
  fail "nginx configuration test"
  sed 's/^/      /' /tmp/xmpp-stack-nginx-doctor.log
fi
rm -f /tmp/xmpp-stack-nginx-doctor.log

if [[ -r "${ADMIN_HTPASSWD_FILE}" ]] && grep -q "^${ADMIN_HTTP_USER}:" "${ADMIN_HTPASSWD_FILE}"; then
  ok "nginx Basic Auth file contains ${ADMIN_HTTP_USER}"
else
  fail "nginx Basic Auth file missing/unreadable or user absent: ${ADMIN_HTPASSWD_FILE}"
fi

if [[ -r "${TURN_SECRET_FILE}" ]] && [[ "$(tr -d '\r\n' < "${TURN_SECRET_FILE}")" == "${TURN_SECRET:-}" ]]; then
  ok "staged TURN secret matches .env"
else
  fail "staged TURN secret missing or does not match: ${TURN_SECRET_FILE}"
fi

if [[ -r "${TURN_CONFIG_FILE}" ]] && grep -Fq "realm=turn.${XMPP_DOMAIN:-}" "${TURN_CONFIG_FILE}"; then
  ok "coturn configuration staged"
else
  fail "coturn configuration missing or wrong realm: ${TURN_CONFIG_FILE}"
fi

if command -v stat >/dev/null 2>&1; then
  for secret_path in "${TURN_SECRET_FILE}" "${TURN_CONFIG_FILE}"; do
    mode="$(stat -c '%a' "${secret_path}" 2>/dev/null || true)"
    if [[ "${mode}" == "600" ]]; then
      ok "permissions ${secret_path}: 0600"
    elif [[ -n "${mode}" ]]; then
      warn "permissions ${secret_path}: ${mode}, expected 0600"
    fi
  done
fi

if docker info >/dev/null 2>&1; then
  ok "Docker daemon access"
else
  fail "cannot access Docker daemon"
fi

check_container() {
  local name="$1"
  local state
  state="$(docker inspect -f '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${name}" 2>/dev/null || true)"

  case "${state}" in
    "true healthy") ok "container ${name}: running/healthy" ;;
    "true no-healthcheck") ok "container ${name}: running" ;;
    "true starting") warn "container ${name}: healthcheck still starting" ;;
    "true unhealthy") fail "container ${name}: unhealthy" ;;
    "") fail "container ${name}: not found" ;;
    *) fail "container ${name}: ${state}" ;;
  esac
}

check_container xmpp-db
check_container xmpp-prosody
check_container xmpp-turn

if [[ -n "${TURN_SECRET:-}" ]]; then
  docker_metadata="$(docker inspect xmpp-prosody xmpp-turn 2>/dev/null || true)"
  if grep -Fq -- "${TURN_SECRET}" <<<"${docker_metadata}"; then
    fail "TURN secret is exposed in persistent Docker container metadata"
  else
    ok "TURN secret is absent from Docker container metadata"
  fi
fi

if docker exec xmpp-db pg_isready -U prosody -d prosody >/dev/null 2>&1; then
  ok "PostgreSQL accepts connections"
else
  fail "PostgreSQL is not ready"
fi

run_prosody_check() {
  local check_name="$1"
  local output
  if output="$(docker exec xmpp-prosody prosodyctl check "${check_name}" 2>&1)"; then
    ok "Prosody check ${check_name}"
  else
    fail "Prosody check ${check_name}"
    printf '%s\n' "${output}" | tail -n 12 | sed 's/^/      /'
  fi
}

for check_name in config certs dns turn features; do
  run_prosody_check "${check_name}"
done

if command -v timeout >/dev/null 2>&1 && timeout 2 bash -c '</dev/tcp/127.0.0.1/5222' >/dev/null 2>&1; then
  ok "local TCP 5222 is reachable"
else
  fail "local TCP 5222 is not reachable"
fi

if command -v timeout >/dev/null 2>&1 && timeout 2 bash -c '</dev/tcp/127.0.0.1/5269' >/dev/null 2>&1; then
  ok "local TCP 5269 is reachable"
else
  fail "local TCP 5269 is not reachable"
fi

if command -v timeout >/dev/null 2>&1 && timeout 2 bash -c '</dev/tcp/127.0.0.1/5280' >/dev/null 2>&1; then
  ok "Prosody HTTP 127.0.0.1:5280 is reachable"
else
  fail "Prosody HTTP 127.0.0.1:5280 is not reachable"
fi

if command -v ss >/dev/null 2>&1; then
  if ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq '(^|:)3478$'; then
    ok "TURN UDP 3478 is listening"
  else
    fail "TURN UDP 3478 is not listening"
  fi

  if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)3478$'; then
    ok "TURN TCP 3478 is listening"
  else
    fail "TURN TCP 3478 is not listening"
  fi
else
  warn "ss not found; skipped local TURN listener checks"
fi

if command -v curl >/dev/null 2>&1 && [[ -n "${XMPP_DOMAIN:-}" ]]; then
  admin_status="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 8 "https://${XMPP_DOMAIN}/admin" 2>/dev/null || true)"
  if [[ "${admin_status}" == "401" ]]; then
    ok "HTTPS /admin requires Basic Auth"
  else
    fail "HTTPS /admin returned ${admin_status:-no response}, expected 401 without credentials"
  fi

  register_status="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 8 "https://${XMPP_DOMAIN}/register" 2>/dev/null || true)"
  if [[ "${register_status}" =~ ^(200|301|302|303|307|308)$ ]]; then
    ok "HTTPS /register responds (${register_status})"
  else
    warn "HTTPS /register returned ${register_status:-no response}"
  fi
else
  warn "curl not found; skipped HTTPS endpoint checks"
fi

printf '\nSummary: %d OK / %d WARN / %d FAIL\n' "${OK_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"
printf 'TURN relay range configured: UDP %s-%s (external NAT must be checked from another network).\n' "${TURN_MIN_PORT}" "${TURN_MAX_PORT}"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
