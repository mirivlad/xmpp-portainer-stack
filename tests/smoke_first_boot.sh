#!/usr/bin/env bash
# Isolated first-boot test with synthetic TLS fixtures. Never opens public ports.
set -euo pipefail
cd "$(dirname "$0")/.."
project="xmpp-ci-${GITHUB_RUN_ID:-local}"
test_container="${project}-prosody"
certdir="$(mktemp -d)"
cleanup() {
  docker rm -f "$test_container" >/dev/null 2>&1 || true
  docker compose -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true
  docker volume rm "${project}_caddy_data" >/dev/null 2>&1 || true
  rm -rf "$certdir"
}
trap cleanup EXIT

# Reuse the repo's versioned public assets, never call Let's Encrypt in CI.
export ASSETS_REF="${ASSETS_REF:-main}"
docker compose -p "$project" run --rm --no-deps bootstrap
docker compose -p "$project" up -d --no-deps db
state=""
for _ in $(seq 1 60); do
  state="$(docker inspect -f '{{.State.Health.Status}}' "${project}-db-1" 2>/dev/null || true)"
  [[ "$state" == healthy ]] && break
  sleep 2
done
[[ "$state" == healthy ]] || { echo "PostgreSQL did not become healthy"; exit 1; }

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$certdir/tls.key" -out "$certdir/tls.crt" \
  -subj "/CN=xmpp.example.org" \
  -addext "subjectAltName=DNS:xmpp.example.org,DNS:conference.xmpp.example.org,DNS:share.xmpp.example.org" \
  >/dev/null 2>&1
docker volume create "${project}_caddy_data" >/dev/null
docker run --rm --network none -v "$certdir:/src:ro" -v "${project}_caddy_data:/data" \
  alpine:3.22 sh -ec '
    for host in xmpp.example.org conference.xmpp.example.org share.xmpp.example.org; do
      dir="/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$host"
      mkdir -p "$dir"
      cp /src/tls.crt "$dir/$host.crt"
      cp /src/tls.key "$dir/$host.key"
    done
  '

docker compose -p "$project" run -d --no-deps --name "$test_container" prosody
health=""
for _ in $(seq 1 100); do
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$test_container" 2>/dev/null || true)"
  [[ "$health" == healthy ]] && break
  [[ "$(docker inspect -f '{{.State.Status}}' "$test_container" 2>/dev/null || true)" == exited ]] && break
  sleep 3
done
if [[ "$health" != healthy ]]; then
  docker logs --tail 100 "$test_container" || true
  echo "Prosody failed first-boot healthcheck" >&2
  exit 1
fi
docker exec "$test_container" sh -ec '
  test -r /var/lib/prosody/custom_plugins/share/lua/5.4/mod_admin_web2.lua
  test -r /var/lib/prosody/custom_plugins/share/lua/5.4/mod_register_web.lua
  wget -q -O /tmp/registration.html --header="Host: xmpp.example.org" http://127.0.0.1:5280/register/
  grep -Fq "name=\"username\"" /tmp/registration.html
  grep -Fq "name=\"captcha_reply\"" /tmp/registration.html
'
echo "First-boot Prosody, SQL, synthetic TLS, modules and registration form: OK"
