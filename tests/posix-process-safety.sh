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
