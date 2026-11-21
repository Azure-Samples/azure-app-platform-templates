#!/usr/bin/env bash
set -euo pipefail

for candidate_bin in \
  "/opt/homebrew/bin" \
  "/usr/local/bin" \
  "$HOME/.local/bin" \
  $(ls -d "$HOME/.nvm/versions/node/"*/bin 2>/dev/null | sort -V | tail -n 1); do
  if [[ -n "$candidate_bin" && -d "$candidate_bin" && ":$PATH:" != *":$candidate_bin:"* ]]; then
    export PATH="$candidate_bin:$PATH"
  fi
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$ROOT/.dev-run"
. "$ROOT/scripts/load-ports.sh"
load_app_ports "$ROOT"
WEB_PORT="${WEB_PORT:-3000}"
AGENT_PORT="${AGENT_PORT:-8088}"
RAW_SKILL_NAME="__SKILL_NAME__"
if [[ -z "$RAW_SKILL_NAME" || "$RAW_SKILL_NAME" == "__SKILL"* ]]; then
  SKILL_NAME="text-insights"
else
  SKILL_NAME="$RAW_SKILL_NAME"
fi
SKILL_PORT="$(skill_port_for_name "$SKILL_NAME" 0 1)"
export SKILL_PORT
SKIP_SKILL=0
FORCE_CLEAN="${FORCE_CLEAN:-0}"
while (($#)); do
  case "$1" in
    --skip-skill) SKIP_SKILL=1 ;;
    --clean|-Clean) FORCE_CLEAN=1 ;;
    --help|-h)
      echo "Usage: ./scripts/dev-start.sh [--skip-skill] [--clean]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done
if ! "$ROOT/scripts/dev-stop.sh"; then
  echo "The previous app processes could not be stopped safely." >&2
  exit 1
fi
mkdir -p "$RUN_DIR"
: >"$RUN_DIR/processes.posix.tsv"

record_process() {
  local name="$1" port="$2" pid="$3" started_at
  started_at="$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" || started_at=""
  printf '%s\t%s\t%s\t%s\n' "$name" "$port" "$pid" "$started_at" >>"$RUN_DIR/processes.posix.tsv"
  if [[ -z "$started_at" ]]; then
    echo "Could not record process identity for $name. Verify PID $pid manually." >&2
    return 1
  fi
}

index_url="${PIP_INDEX_URL:-${UV_INDEX_URL:-${UV_DEFAULT_INDEX:-}}}"
if [[ -z "$index_url" ]] && command -v pip3 >/dev/null 2>&1; then
  index_url="$(pip3 config get global.index-url 2>/dev/null || true)"
fi
if [[ -n "$index_url" ]]; then
  export PIP_INDEX_URL="$index_url" UV_INDEX_URL="$index_url" UV_DEFAULT_INDEX="$index_url"
fi

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ROOT/.env"
  set +a
elif [[ -f "$ROOT/src/agent/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ROOT/src/agent/.env"
  set +a
fi

command -v uv >/dev/null || { echo "uv is required." >&2; exit 1; }
command -v npm >/dev/null || { echo "npm is required." >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
if [[ "$FORCE_CLEAN" == "1" ]]; then
  rm -rf "$ROOT/src/agent/.venv" "$ROOT/src/web/node_modules"
fi
if [[ ! -d "$ROOT/src/agent/.venv" || "$FORCE_CLEAN" == "1" ]]; then
  (cd "$ROOT/src/agent" && uv sync)
fi

wait_http() {
  local name="$1" port="$2" route="$3" pid="$4" deadline=$((SECONDS + 30))
  while ((SECONDS < deadline)); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$port$route" >/dev/null 2>&1; then
      echo "[$name] READY on port $port"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[$name] exited before becoming ready on port $port" >&2
      sed -n '1,100p' "$RUN_DIR/$name.log" >&2 || true
      "$ROOT/scripts/dev-stop.sh" || echo "Process cleanup is incomplete." >&2
      exit 1
    fi
    sleep 0.15
  done
  echo "[$name] timed out becoming ready on port $port" >&2
  "$ROOT/scripts/dev-stop.sh" || echo "Process cleanup is incomplete." >&2
  exit 1
}

skill_dir="$ROOT/src/skills/$SKILL_NAME"
if [[ ! -d "$skill_dir" && -d "$ROOT/src/skills/__SKILL__" ]]; then
  skill_dir="$ROOT/src/skills/__SKILL__"
fi
if ((SKIP_SKILL)); then
  echo "Hosted Skill skipped (--skip-skill)."
else
  clean_arg=()
  [[ "$FORCE_CLEAN" == "1" ]] && clean_arg=(--clean)
  if ! "$ROOT/scripts/lifecycle/mcp-skill-start.sh" \
    --name "$SKILL_NAME" \
    --path "$skill_dir" \
    --port "$SKILL_PORT" \
    --run-dir "$RUN_DIR" \
    "${clean_arg[@]}"; then
    "$ROOT/scripts/dev-stop.sh" || echo "Process cleanup is incomplete." >&2
    exit 1
  fi
fi

MCP_SKILL_URL="${MCP_SKILL_URL:-http://127.0.0.1:$SKILL_PORT/runtime/webhooks/mcp}"
(
  cd "$ROOT/src/agent"
  exec env UV_NO_SYNC=1 AGENT_PORT="$AGENT_PORT" SKILL_PORT="$SKILL_PORT" MCP_SKILL_URL="$MCP_SKILL_URL" uv run main.py
) >"$RUN_DIR/agent.log" 2>&1 &
agent_pid=$!
record_process "agent" "$AGENT_PORT" "$agent_pid"
wait_http agent "$AGENT_PORT" "/health" "$agent_pid"

(
  cd "$ROOT/src/web"
  exec env WEB_PORT="$WEB_PORT" AGENT_URL="http://127.0.0.1:$AGENT_PORT" npm run dev
) >"$RUN_DIR/web.log" 2>&1 &
web_pid=$!
record_process "web" "$WEB_PORT" "$web_pid"
wait_http web "$WEB_PORT" "/" "$web_pid"

echo "__APP_NAME__ started: web http://localhost:$WEB_PORT, agent http://localhost:$AGENT_PORT, mcp-skill $MCP_SKILL_URL"
