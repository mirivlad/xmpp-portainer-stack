#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BACKUP_FILE="${1:-}"
ASSUME_YES=0

if [[ -z "${BACKUP_FILE}" ]]; then
  echo "Usage: $0 /path/to/xmpp-portainer-stack-*.tar.gz [--yes]" >&2
  exit 2
fi

if [[ "${2:-}" == "--yes" ]]; then
  ASSUME_YES=1
elif [[ $# -gt 1 ]]; then
  echo "Usage: $0 /path/to/xmpp-portainer-stack-*.tar.gz [--yes]" >&2
  exit 2
fi

if [[ ! -r "${BACKUP_FILE}" ]]; then
  echo "Backup not readable: ${BACKUP_FILE}" >&2
  exit 1
fi

for cmd in docker tar install openssl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Required command not found: ${cmd}" >&2
    exit 1
  fi
done

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose plugin is required." >&2
  exit 1
fi

if (( ASSUME_YES != 1 )); then
  echo "WARNING: this replaces the Prosody database and /var/lib/prosody data."
  read -r -p "Type RESTORE to continue: " answer
  if [[ "${answer}" != "RESTORE" ]]; then
    echo "Restore cancelled."
    exit 1
  fi
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM
chmod 0700 "${TMP_DIR}"

tar -xzf "${BACKUP_FILE}" -C "${TMP_DIR}"

for required in deployment.env database.dump prosody-data.tar.gz metadata.txt; do
  if [[ ! -f "${TMP_DIR}/${required}" ]]; then
    echo "Invalid backup: missing ${required}" >&2
    exit 1
  fi
done

if [[ -e "${ROOT_DIR}/.env" ]]; then
  OLD_ENV_BACKUP="${ROOT_DIR}/.env.before-restore.$(date -u +%Y%m%dT%H%M%SZ)"
  install -m 0600 -T "${ROOT_DIR}/.env" "${OLD_ENV_BACKUP}"
  echo "Saved current environment to ${OLD_ENV_BACKUP}"
fi

install -m 0600 -T "${TMP_DIR}/deployment.env" "${ROOT_DIR}/.env"

set -a
# shellcheck disable=SC1091
source "${ROOT_DIR}/.env"
set +a

: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD missing in backup environment}"
: "${TURN_SECRET:?TURN_SECRET missing in backup environment}"

CERT_SOURCE_DIR="${CERT_SOURCE_DIR:-/var/lib/xmpp-portainer-stack/certs}"
TURN_SECRET_FILE="${TURN_SECRET_FILE:-/var/lib/xmpp-portainer-stack/turn-secret}"

install -d -m 0700 "${CERT_SOURCE_DIR}"
install -d -m 0700 "$(dirname -- "${TURN_SECRET_FILE}")"
printf '%s\n' "${TURN_SECRET}" > "${TURN_SECRET_FILE}"
chmod 0600 "${TURN_SECRET_FILE}"

cd "${ROOT_DIR}"

echo "Starting PostgreSQL for restore..."
docker compose up -d db

ready=0
for _ in $(seq 1 60); do
  if docker exec xmpp-db pg_isready -U prosody -d prosody >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if (( ready != 1 )); then
  echo "PostgreSQL did not become ready." >&2
  exit 1
fi

if docker inspect xmpp-prosody >/dev/null 2>&1; then
  docker stop -t 30 xmpp-prosody >/dev/null 2>&1 || true
fi

echo "Restoring PostgreSQL database..."
docker exec xmpp-db dropdb -U prosody --maintenance-db=postgres --if-exists prosody
docker exec xmpp-db createdb -U prosody -T template0 prosody
cat "${TMP_DIR}/database.dump" | docker exec -i xmpp-db pg_restore -U prosody -d prosody --no-owner --no-privileges

escaped_password="${POSTGRES_PASSWORD//\'/\'\'}"
printf "ALTER ROLE prosody WITH PASSWORD '%s';\n" "${escaped_password}" | \
  docker exec -i xmpp-db psql -U prosody -d postgres -v ON_ERROR_STOP=1 >/dev/null

echo "Preparing Prosody data volume..."
docker compose create --force-recreate prosody >/dev/null
mkdir -p "${TMP_DIR}/prosody-data"
tar -xzf "${TMP_DIR}/prosody-data.tar.gz" -C "${TMP_DIR}/prosody-data"

docker run --rm \
  --volumes-from xmpp-prosody \
  -v "${TMP_DIR}/prosody-data:/restore:ro" \
  --entrypoint /bin/bash \
  prosodyim/prosody:latest \
  -lc 'set -euo pipefail; shopt -s dotglob nullglob; rm -rf /var/lib/prosody/*; cp -a /restore/. /var/lib/prosody/; chown -R prosody:prosody /var/lib/prosody'

echo
echo "Restore completed. Prosody remains stopped until host configuration is rebuilt."
echo "Run:"
echo "  sudo ./scripts/setup-host.sh"
echo "  docker compose up -d --pull always"
echo "  sudo ./scripts/doctor.sh"
