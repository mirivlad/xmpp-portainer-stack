#!/usr/bin/env python3
"""Static checks for self-contained Docker Compose and its shell boot scripts."""
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
result = subprocess.run(
    ["docker", "compose", "config", "--format", "json"],
    check=True,
    capture_output=True,
    text=True,
    cwd=root,
)
services = json.loads(result.stdout)["services"]
assert {"bootstrap", "db", "caddy", "prosody", "turn"} <= set(services)
for name, service in services.items():
    for volume in service.get("volumes", []):
        assert volume["type"] == "volume", (name, volume)

for name in ("bootstrap", "caddy", "prosody"):
    command = services[name]["command"]
    assert isinstance(command, list) and len(command) == 1, name
    shell = "bash" if name == "prosody" else "sh"
    subprocess.run([shell, "-n"], input=command[0], text=True, check=True)

assert {p["published"] for p in services["caddy"]["ports"]} == {"80", "443"}
assert {p["published"] for p in services["prosody"]["ports"]} == {"5222", "5269"}
assert "register_web_template" in services["prosody"]["command"][0]
assert "sync_certs()" in services["prosody"]["command"][0]
assert "raw.githubusercontent.com" in services["bootstrap"]["command"][0]
assert "caddy_data" in [v["source"] for v in services["prosody"]["volumes"]]

for filename in ("register", "success", "simplecaptcha", "hcaptcha", "recaptcha"):
    assert (root / "register-templates" / f"{filename}.html").stat().st_size > 0
assert (root / "deploy/Caddyfile").read_text().count("{$XMPP_DOMAIN}") >= 2
print("Standalone Compose config, bootstrap shells, ports and assets: OK")
