#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
child=""
cleanup() {
  if [[ -z "$child" && -n "${app:-}" && -f "$app/.dev-run/processes.posix.tsv" ]]; then
    if ! bash "$app/scripts/dev-stop.sh"; then
      echo "Fixture cleanup needs manual review: $app" >&2
      return 1
    fi
  fi
  if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null; then
    kill "$child"
    wait "$child" 2>/dev/null || true
  fi
  rm -rf -- "$test_root"
}
trap cleanup EXIT

for name in empty-starter-app app-service-builder-vite app-service-builder-ai-gateway sandboxes-minimal sandbox-gateway-minimal dealership-e2e shared/dealer; do
  app="$test_root/$name"
  mkdir -p "$app/scripts"
  cp "$root/templates/$name/scripts/dev-stop.sh" "$app/scripts/dev-stop.sh"
  bash "$app/scripts/dev-stop.sh" >/dev/null
  mkdir -p "$app/.dev-run"
  state="$app/.dev-run/processes.posix.tsv"
  sleep 300 &
  child=$!
  started_at="$(ps -p "$child" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$started_at" ]]

  printf 'fixture\t4321\t%s\t\n' "$child" >"$state"
  if bash "$app/scripts/dev-stop.sh" >"$app/output" 2>&1; then
    echo "$name accepted a PID without a start identity" >&2
    exit 1
  fi
  grep -q 'no recorded start identity' "$app/output"
  kill -0 "$child"
  [[ -f "$state" ]]

  printf 'fixture\t4321\t%s\t%s\n' "$child" 'Sat Jan 1 00:00:00 2000' >"$state"
  bash "$app/scripts/dev-stop.sh" >"$app/output" 2>&1
  grep -q 'PID was reused' "$app/output"
  kill -0 "$child"

  self_start="$(ps -p "$$" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf 'fixture\t4321\t%s\t%s\n' "$$" "$self_start" >"$state"
  if bash "$app/scripts/dev-stop.sh" >"$app/output" 2>&1; then
    echo "$name accepted an ancestor process" >&2
    exit 1
  fi
  grep -q 'refusing to stop' "$app/output"
  [[ -f "$state" ]]

  printf 'fixture\t4321\t%s\t%s\n' "$child" "$started_at" >"$state"
  bash "$app/scripts/dev-stop.sh" >"$app/output" 2>&1
  wait "$child" 2>/dev/null || true
  child=""
  [[ ! -f "$state" ]]
  echo "$name: process identity checks passed"
done

app="$test_root/vite-start"
mkdir -p "$app/scripts" "$app/bin" "$app/node_modules/vite" "$app/node_modules/.bin" "$app/dist"
cp "$root/templates/app-service-builder-vite/scripts/dev-start.sh.template" "$app/scripts/dev-start.sh"
cp "$root/templates/app-service-builder-vite/scripts/dev-stop.sh" "$app/scripts/dev-stop.sh"
printf 'load_app_ports() { :; }\n' >"$app/scripts/load-ports.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$app/bin/npm"
cat >"$app/node_modules/.bin/vite" <<'EOF'
#!/usr/bin/env bash
exec python3 "$FIXTURE_SERVER"
EOF
cat >"$app/server.py" <<'EOF'
import http.server
import json
import os

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"index": os.environ.get("UV_INDEX_URL"), "offline": os.environ.get("UV_OFFLINE")}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass

http.server.HTTPServer(("127.0.0.1", int(os.environ["WEB_PORT"])), Handler).serve_forever()
EOF
chmod +x "$app/bin/npm" "$app/node_modules/.bin/vite" "$app/scripts/dev-stop.sh"
printf 'fixture\n' >"$app/dist/index.html"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export PATH="$app/bin:$PATH" WEB_PORT="$port" FIXTURE_SERVER="$app/server.py"
export PIP_INDEX_URL="https://packages.example.test/simple" UV_INDEX_URL="https://other.example.test/simple" UV_OFFLINE="1"
bash "$app/scripts/dev-start.sh" >"$app/start-output" 2>&1
child="$(awk -F '\t' '$1 == "web" {print $3}' "$app/.dev-run/processes.posix.tsv")"
[[ -n "$child" ]]
curl -fsS "http://127.0.0.1:$port/" | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p == {"index":"https://packages.example.test/simple","offline":"1"}'
bash "$app/scripts/dev-stop.sh" >"$app/stop-output" 2>&1
if kill -0 "$child" 2>/dev/null; then
  echo "Vite fixture process remains after stop" >&2
  exit 1
fi
child=""
[[ ! -f "$app/.dev-run/processes.posix.tsv" ]]
echo "app-service-builder-vite: local start and stop passed"

app="$test_root/builder-unhealthy"
mkdir -p "$app/scripts" "$app/bin" "$app/src/agent/.venv"
cp "$root/templates/app-service-builder-ai-gateway/scripts/dev-start.sh.template" "$app/scripts/dev-start.sh"
cp "$root/templates/app-service-builder-ai-gateway/scripts/dev-stop.sh" "$app/scripts/dev-stop.sh"
printf 'load_app_ports() { :; }\n' >"$app/scripts/load-ports.sh"
printf '# fixture\n' >"$app/src/agent/main.py"
cat >"$app/bin/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "sync" ]]; then
  printf 'synced\n' >"$SYNC_MARKER"
  exit 0
fi
if [[ "$2" == "main.py" ]]; then
  exec python3 "$AGENT_SERVER"
fi
printf 'started\n' >"$WEB_MARKER"
exec python3 "$WEB_SERVER"
EOF
cat >"$app/agent.py" <<'EOF'
import http.server, os
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(503)
        self.end_headers()
    def log_message(self, *_args):
        pass
http.server.HTTPServer(("127.0.0.1", int(os.environ["AGENT_PORT"])), Handler).serve_forever()
EOF
cat >"$app/web.py" <<'EOF'
import http.server, os
http.server.HTTPServer(("127.0.0.1", int(os.environ["WEB_PORT"])), http.server.SimpleHTTPRequestHandler).serve_forever()
EOF
chmod +x "$app/bin/uv" "$app/scripts/dev-stop.sh"
read -r agent_port web_port < <(python3 -c 'import socket; a=socket.socket(); b=socket.socket(); a.bind(("127.0.0.1",0)); b.bind(("127.0.0.1",0)); print(a.getsockname()[1],b.getsockname()[1]); a.close(); b.close()')
export PATH="$app/bin:$PATH" AGENT_PORT="$agent_port" WEB_PORT="$web_port"
export SYNC_MARKER="$app/synced" WEB_MARKER="$app/web-started" AGENT_SERVER="$app/agent.py" WEB_SERVER="$app/web.py"
if bash "$app/scripts/dev-start.sh" >"$app/start-output" 2>&1; then
  echo "An unhealthy agent allowed Builder startup to succeed" >&2
  exit 1
fi
grep -q "Backend agent did not become ready" "$app/start-output"
[[ -f "$SYNC_MARKER" && ! -f "$WEB_MARKER" && ! -f "$app/.dev-run/processes.posix.tsv" ]]
if curl -sS -o /dev/null "http://127.0.0.1:$agent_port/healthz" 2>/dev/null; then
  echo "The unhealthy fixture agent is still running" >&2
  exit 1
fi
echo "app-service-builder-ai-gateway: unhealthy agent blocks startup"

for name in empty-starter-app app-service-builder-vite app-service-builder-ai-gateway; do
  app="$test_root/$name-zombie"
  mkdir -p "$app/scripts" "$app/.dev-run"
  cp "$root/templates/$name/scripts/dev-stop.sh" "$app/scripts/dev-stop.sh"
  chmod +x "$app/scripts/dev-stop.sh"
  python3 -c '
import os, sys, time
child_pid = os.fork()
if child_pid == 0:
    os._exit(0)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"{child_pid}\n")
time.sleep(300)
' "$app/zombie.pid" &
  child=$!
  for _ in {1..40}; do
    [[ -s "$app/zombie.pid" ]] && break
    sleep 0.05
  done
  zombie_pid="$(cat "$app/zombie.pid")"
  for _ in {1..40}; do
    z_state="$(ps -p "$zombie_pid" -o state= 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$z_state" == Z* ]] && break
    sleep 0.05
  done
  started_at="$(ps -p "$child" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf 'fixture\t4321\t%s\t%s\n' "$child" "$started_at" >"$app/.dev-run/processes.posix.tsv"
  "$app/scripts/dev-stop.sh" >"$app/zombie-stop-output" 2>&1
  wait "$child" 2>/dev/null || true
  child=""
  [[ ! -f "$app/.dev-run/processes.posix.tsv" ]]
  echo "$name: zombie descendant under live parent stopped cleanly"
done

app="$test_root/mcp-lifecycle-posix"
mkdir -p "$app/scripts/lifecycle" "$app/bin" "$app/src/skills/text-insights" "$app/.azure-app-platform"
cp "$root/templates/shared/load-ports.sh" "$app/scripts/load-ports.sh"
cp "$root/templates/shared/lifecycle/mcp-skill-start.sh" "$app/scripts/lifecycle/mcp-skill-start.sh"
cp "$root/templates/shared/lifecycle/mcp-skill-stop.sh" "$app/scripts/lifecycle/mcp-skill-stop.sh"
chmod +x "$app/scripts/lifecycle/mcp-skill-start.sh" "$app/scripts/lifecycle/mcp-skill-stop.sh"
printf '{"version":"2.0"}\n' >"$app/src/skills/text-insights/host.json"
printf '{"IsEncrypted":false,"Values":{"FUNCTIONS_WORKER_RUNTIME":"python"}}\n' >"$app/src/skills/text-insights/local.settings.json.example"
printf '[project]\nname = "mcp-test"\nversion = "0.1.0"\n' >"$app/src/skills/text-insights/pyproject.toml"
cat >"$app/mcp-server.py" <<'EOF'
import http.server, json, os, sys
port = int(sys.argv[1])
if os.fork() == 0:
    os._exit(0)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        msg = {"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2025-03-26"}}
        self.wfile.write(f"event: message\ndata: {json.dumps(msg)}\n\n".encode())
    def log_message(self, *_args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
EOF
cat >"$app/bin/func" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$app/bin/uv" <<'EOF'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last="$arg"; done
exec python3 "$MCP_FIXTURE_SERVER" "$last"
EOF
chmod +x "$app/bin/func" "$app/bin/uv"
mcp_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
printf 'SKILL_TEXT_INSIGHTS_PORT=%s\n' "$mcp_port" >"$app/.azure-app-platform/ports.env"
(
  set -euo pipefail
  . "$app/scripts/load-ports.sh"
  load_app_ports "$app"
  resolved="$(skill_port_for_name text-insights 0 1)"
  [[ "$resolved" == "$mcp_port" ]]
  PATH="$app/bin:$PATH" MCP_FIXTURE_SERVER="$app/mcp-server.py" \
    "$app/scripts/lifecycle/mcp-skill-start.sh" \
    --name text-insights \
    --path "$app/src/skills/text-insights" \
    --port "$resolved" \
    --run-dir "$app/.dev-run"
  [[ -f "$app/src/skills/text-insights/local.settings.json" ]]
  "$app/scripts/lifecycle/mcp-skill-stop.sh" --run-dir "$app/.dev-run"
  [[ ! -f "$app/.dev-run/processes.posix.tsv" ]]
)
echo "mcp-skill-start/stop: SSE MCP readiness, zombie child cleanup, and SKILL_<NAME>_PORT override passed"

for name in dealership-e2e shared/dealer; do
  app="$test_root/${name//\//-}-skill-order"
  mkdir -p "$app/scripts" "$app/bin"
  cp "$root/templates/$name/scripts/dev-start.sh" "$app/scripts/dev-start.sh"
  cp "$root/templates/$name/scripts/dev-stop.sh" "$app/scripts/dev-stop.sh"
  printf 'load_app_ports() { :; }\n' >"$app/scripts/load-ports.sh"
  cat >"$app/bin/azurite" <<'EOF'
#!/usr/bin/env bash
exec node "$AZURITE_FIXTURE" "$@"
EOF
  cat >"$app/azurite.cjs" <<'EOF'
const net = require("node:net");
for (const flag of ["--blobPort", "--queuePort", "--tablePort"]) {
  const port = Number(process.argv[process.argv.indexOf(flag) + 1]);
  net.createServer().listen(port, "127.0.0.1");
}
EOF
  cat >"$app/bin/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${PWD##*/}" == "inventory-search" ]]; then
  attempts=0
  [[ ! -f "$FIRST_SKILL_ATTEMPTS" ]] || read -r attempts <"$FIRST_SKILL_ATTEMPTS"
  attempts=$((attempts + 1))
  printf '%s\n' "$attempts" >"$FIRST_SKILL_ATTEMPTS"
  if [[ "$SKILL_FAILURE" == "ordinary" || "$attempts" == "1" ]]; then
    : >"$FIRST_SKILL_STARTED"
    while [[ ! -f "$RELEASE_FIRST_SKILL" ]]; do sleep 0.05; done
    if [[ "$SKILL_FAILURE" == "provider" ]]; then
      echo "Value cannot be null. (Parameter 'provider')" >&2
    else
      echo "fixture skill failed" >&2
    fi
    exit 17
  fi
fi
port="${@: -1}"
exec node -e 'require("node:net").createServer().listen(Number(process.argv[1]), "127.0.0.1")' "$port"
EOF
  chmod +x "$app/bin/azurite" "$app/bin/uv" "$app/scripts/dev-stop.sh"
  for skill in inventory-search trade-in-value rate-sheet deal-doc; do
    mkdir -p "$app/src/skills/$skill"
    printf '{"Values":{"AZURE_FUNCTIONS_AGENTS_PROVIDER":"foundry"}}\n' \
      >"$app/src/skills/$skill/local.settings.json"
  done
  read -r WEB_PORT AGENT_PORT INVENTORY_SEARCH_PORT TRADE_IN_VALUE_PORT RATE_SHEET_PORT \
    DEAL_DOC_PORT AZURITE_BLOB_PORT AZURITE_QUEUE_PORT AZURITE_TABLE_PORT < <(python3 -c '
import socket
sockets = [socket.socket() for _ in range(9)]
for sock in sockets:
    sock.bind(("127.0.0.1", 0))
print(*(sock.getsockname()[1] for sock in sockets))
for sock in sockets:
    sock.close()
')
  export PATH="$app/bin:$PATH" WEB_PORT AGENT_PORT INVENTORY_SEARCH_PORT TRADE_IN_VALUE_PORT \
    RATE_SHEET_PORT DEAL_DOC_PORT AZURITE_BLOB_PORT AZURITE_QUEUE_PORT AZURITE_TABLE_PORT
  export AZURITE_FIXTURE="$app/azurite.cjs" FIRST_SKILL_STARTED="$app/first-started" \
    RELEASE_FIRST_SKILL="$app/release-first" FIRST_SKILL_ATTEMPTS="$app/inventory-attempts"
  for SKILL_FAILURE in ordinary provider; do
    export SKILL_FAILURE
    rm -f "$FIRST_SKILL_STARTED" "$RELEASE_FIRST_SKILL" "$FIRST_SKILL_ATTEMPTS"
    bash "$app/scripts/dev-start.sh" --skip-agent --skip-web >"$app/start-output" 2>&1 &
    child=$!
    deadline=$((SECONDS + 30))
    until [[ -f "$FIRST_SKILL_STARTED" ]] &&
      [[ -f "$app/.dev-run/processes.posix.tsv" ]] &&
      awk -F '\t' '$1 == "inventory-search" && $3 != "" && $4 != "" { found=1 } END { exit !found }' \
        "$app/.dev-run/processes.posix.tsv"; do
      if ! kill -0 "$child" 2>/dev/null || ((SECONDS >= deadline)); then
        echo "$name did not start the first skill" >&2
        exit 1
      fi
      sleep 0.05
    done
    : >"$RELEASE_FIRST_SKILL"
    result=0
    wait "$child" || result=$?
    child=""
    if [[ "$SKILL_FAILURE" == "ordinary" ]]; then
      if ((result == 0)); then
        echo "$name accepted a failed first skill" >&2
        exit 1
      fi
      grep -q 'fixture skill failed' "$app/.dev-run/logs/inventory-search.err.log"
      if [[ -e "$app/.dev-run/logs/trade-in-value.out.log" ]]; then
        echo "$name started a later skill before the first was ready" >&2
        exit 1
      fi
    else
      if ((result != 0)); then
        cat "$app/start-output" >&2
        echo "$name did not recover from the transient provider error" >&2
        exit 1
      fi
      [[ "$(cat "$FIRST_SKILL_ATTEMPTS")" == "2" ]]
      grep -q 'provider error. Retrying once.' "$app/start-output"
      bash "$app/scripts/dev-stop.sh" >"$app/stop-output" 2>&1
    fi
    [[ ! -f "$app/.dev-run/processes.posix.tsv" ]]
    python3 -c '
import socket, sys
for port in map(int, sys.argv[1:]):
    with socket.socket() as sock:
        sock.settimeout(1)
        if sock.connect_ex(("127.0.0.1", port)) == 0:
            raise SystemExit(f"fixture listener {port} is still running")
' "$AZURITE_BLOB_PORT" "$AZURITE_QUEUE_PORT" "$AZURITE_TABLE_PORT"
  done
  echo "$name: startup failures stop safely and transient provider errors retry once"
done
