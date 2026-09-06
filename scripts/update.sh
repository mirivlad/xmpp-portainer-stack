#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${1:-${ROOT_DIR}/.env}"

if [[ ! -r "${ENV_FILE}" ]]; then
  echo "Cannot read ${ENV_FILE}." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose plugin is required." >&2
  exit 1
fi

cd "${ROOT_DIR}"

echo "1/4 Creating pre-update backup..."
bash "${ROOT_DIR}/scripts/backup.sh" "${ENV_FILE}"

echo "2/4 Refreshing generated host files..."
if [[ ${EUID} -eq 0 ]]; then
  bash "${ROOT_DIR}/scripts/setup-host.sh" "${ENV_FILE}"
else
  echo "update.sh needs root for nginx/certificate/TURN staging. Re-run with sudo." >&2
  exit 1
fi

echo "3/4 Pulling current images and recreating services..."
docker compose pull
docker compose up -d --pull always

echo "Waiting for Prosody healthcheck..."
healthy=0
for _ in $(seq 1 90); do
  state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{if .State.Running}}running{{else}}stopped{{end}}{{end}}' xmpp-prosody 2>/dev/null || true)"
  if [[ "${state}" == "healthy" || "${state}" == "running" ]]; then
    healthy=1
    break
  fi
  if [[ "${state}" == "unhealthy" || "${state}" == "stopped" ]]; then
    break
  fi
  sleep 1
done

if (( healthy != 1 )); then
  echo "Prosody did not become healthy. Inspect logs before attempting restore:" >&2
  echo "  docker logs xmpp-prosody" >&2
  exit 1
fi

echo "4/4 Running post-update doctor..."
bash "${ROOT_DIR}/scripts/doctor.sh" "${ENV_FILE}"

echo "Update completed successfully."
