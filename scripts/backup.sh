#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${1:-${ROOT_DIR}/.env}"

if [[ ! -r "${ENV_FILE}" ]]; then
  echo "Cannot read ${ENV_FILE}." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

BACKUP_DIR="${BACKUP_DIR:-/var/backups/xmpp-portainer-stack}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_FILE="${BACKUP_DIR}/xmpp-portainer-stack-${TIMESTAMP}.tar.gz"
TMP_DIR="$(mktemp -d)"
PROSODY_WAS_RUNNING=0

cleanup() {
  local status=$?
  rm -rf "${TMP_DIR}"
  if (( PROSODY_WAS_RUNNING == 1 )); then
    docker start xmpp-prosody >/dev/null 2>&1 || true
  fi
  exit "${status}"
}
trap cleanup EXIT INT TERM

for cmd in docker tar install date; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Required command not found: ${cmd}" >&2
    exit 1
  fi
done

if ! docker info >/dev/null 2>&1; then
  echo "Cannot access Docker daemon." >&2
  exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' xmpp-db 2>/dev/null || true)" != "true" ]]; then
  echo "xmpp-db must be running to create a backup." >&2
  exit 1
fi

if ! docker inspect xmpp-prosody >/dev/null 2>&1; then
  echo "xmpp-prosody container does not exist." >&2
  exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' xmpp-prosody 2>/dev/null || true)" == "true" ]]; then
  PROSODY_WAS_RUNNING=1
fi

install -d -m 0700 "${BACKUP_DIR}"
chmod 0700 "${TMP_DIR}"

{
  echo "created_utc=${TIMESTAMP}"
  echo "domain=${XMPP_DOMAIN:-unknown}"
  echo "prosody_image=$(docker inspect -f '{{.Config.Image}}' xmpp-prosody 2>/dev/null || true)"
  echo "prosody_image_id=$(docker inspect -f '{{.Image}}' xmpp-prosody 2>/dev/null || true)"
  echo "postgres_image=$(docker inspect -f '{{.Config.Image}}' xmpp-db 2>/dev/null || true)"
  echo "coturn_image=$(docker inspect -f '{{.Config.Image}}' xmpp-turn 2>/dev/null || true)"
} > "${TMP_DIR}/metadata.txt"

install -m 0600 -T "${ENV_FILE}" "${TMP_DIR}/deployment.env"

if (( PROSODY_WAS_RUNNING == 1 )); then
  echo "Stopping Prosody briefly for a consistent database/data snapshot..."
  docker stop -t 30 xmpp-prosody >/dev/null
fi

echo "Dumping PostgreSQL..."
docker exec xmpp-db pg_dump -U prosody -d prosody -Fc > "${TMP_DIR}/database.dump"

if [[ ! -s "${TMP_DIR}/database.dump" ]]; then
  echo "PostgreSQL dump is empty." >&2
  exit 1
fi

echo "Copying /var/lib/prosody..."
mkdir -p "${TMP_DIR}/prosody-data"
docker cp xmpp-prosody:/var/lib/prosody/. "${TMP_DIR}/prosody-data/"
tar -C "${TMP_DIR}/prosody-data" -czf "${TMP_DIR}/prosody-data.tar.gz" .
rm -rf "${TMP_DIR}/prosody-data"

if (( PROSODY_WAS_RUNNING == 1 )); then
  docker start xmpp-prosody >/dev/null
  PROSODY_WAS_RUNNING=0
fi

tar -C "${TMP_DIR}" -czf "${BACKUP_FILE}" \
  metadata.txt deployment.env database.dump prosody-data.tar.gz
chmod 0600 "${BACKUP_FILE}"

echo "Backup created: ${BACKUP_FILE}"
echo "WARNING: the archive contains .env secrets; keep it private (mode 0600)."
