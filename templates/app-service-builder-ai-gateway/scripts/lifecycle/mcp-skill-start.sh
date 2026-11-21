#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME=""
SKILL_PATH=""
SKILL_PORT=""
RUN_DIR=""
FORCE_CLEAN="${FORCE_CLEAN:-0}"

usage() {
  echo "Usage: mcp-skill-start.sh --name <name> --path <dir> --port <port> --run-dir <dir> [--clean]"
}

while (($#)); do
  case "$1" in
    --name)
      SKILL_NAME="${2:-}"
      shift
      ;;
    --path)
      SKILL_PATH="${2:-}"
      shift
      ;;
    --port)
      SKILL_PORT="${2:-}"
      shift
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
      shift
      ;;
    --clean|-Clean)
      FORCE_CLEAN=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "$SKILL_NAME" || -z "$SKILL_PATH" || -z "$SKILL_PORT" || -z "$RUN_DIR" ]]; then
  echo "Missing required arguments for mcp-skill-start.sh." >&2
  usage >&2
  exit 2
fi

if [[ ! "$SKILL_PORT" =~ ^[0-9]{4,5}$ ]] || ((10#$SKILL_PORT < 1024 || 10#$SKILL_PORT > 65535)); then
  echo "Skill port must be an integer from 1024 to 65535." >&2
  exit 1
fi
SKILL_PORT="$((10#$SKILL_PORT))"

if [[ ! -d "$SKILL_PATH" ]]; then
  echo "[$SKILL_NAME] MCP skill directory does not exist: $SKILL_PATH" >&2
  exit 1
fi

for candidate_bin in \
  "/opt/homebrew/bin" \
  "/usr/local/bin" \
  "$HOME/.local/bin" \
  "$HOME/.azure-functions"; do
  if [[ -n "$candidate_bin" && -d "$candidate_bin" && ":$PATH:" != *":$candidate_bin:"* ]]; then
    export PATH="$candidate_bin:$PATH"
  fi
done

command -v uv >/dev/null 2>&1 || {
  echo "[$SKILL_NAME] uv is required to start MCP Hosted Skills. Install uv and retry." >&2
  exit 1
}
command -v func >/dev/null 2>&1 || {
  echo "[$SKILL_NAME] Azure Functions Core Tools ('func') is required to start MCP Hosted Skills. Install Azure Functions Core Tools v4 and retry." >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "[$SKILL_NAME] curl is required to probe MCP readiness." >&2
  exit 1
}

index_url="${PIP_INDEX_URL:-${UV_INDEX_URL:-${UV_DEFAULT_INDEX:-}}}"
if [[ -z "$index_url" ]] && command -v pip3 >/dev/null 2>&1; then
  index_url="$(pip3 config get global.index-url 2>/dev/null || true)"
fi
if [[ -n "$index_url" ]]; then
  export PIP_INDEX_URL="$index_url" UV_INDEX_URL="$index_url" UV_DEFAULT_INDEX="$index_url"
fi

mkdir -p "$RUN_DIR"
STATE_FILE="$RUN_DIR/processes.posix.tsv"
[[ -f "$STATE_FILE" ]] || : >"$STATE_FILE"

if (echo >/dev/tcp/127.0.0.1/"$SKILL_PORT") >/dev/null 2>&1; then
  echo "[$SKILL_NAME] cannot start: port $SKILL_PORT is already in use." >&2
  exit 1
fi

if [[ ! -f "$SKILL_PATH/local.settings.json" && -f "$SKILL_PATH/local.settings.json.example" ]]; then
  cp "$SKILL_PATH/local.settings.json.example" "$SKILL_PATH/local.settings.json"
fi

if [[ "$FORCE_CLEAN" == "1" && -d "$SKILL_PATH/.venv" ]]; then
  rm -rf "$SKILL_PATH/.venv"
fi

SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_INIT_PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"app-platform-readiness","version":"0.1.0"}}}'
MCP_URL="http://127.0.0.1:$SKILL_PORT/runtime/webhooks/mcp"

mcp_response_valid() {
  local raw="$1" line payload
  if [[ "$raw" == *"\"jsonrpc\""* && "$raw" == *"\"result\""* && "$raw" == *"\"protocolVersion\""* ]]; then
    return 0
  fi
  while IFS= read -r line; do
    if [[ "$line" == data:* ]]; then
      payload="${line#data:}"
      if [[ "$payload" == *"\"result\""* && "$payload" == *"\"protocolVersion\""* ]]; then
        return 0
      fi
    fi
  done <<<"$raw"
  return 1
}

remove_pid_record() {
  local target_pid="$1" tmp_file="$STATE_FILE.clean.$$"
  awk -F '\t' -v pid="$target_pid" '$3 != pid' "$STATE_FILE" >"$tmp_file"
  mv "$tmp_file" "$STATE_FILE"
}

for attempt in 1 2; do
  stdout_log="$RUN_DIR/$SKILL_NAME.log"
  stderr_log="$RUN_DIR/$SKILL_NAME.err.log"
  (
    cd "$SKILL_PATH"
    unset VIRTUAL_ENV
    if [[ -f "$SKILL_PATH/pyproject.toml" ]]; then
      exec uv run func start --port "$SKILL_PORT" --no-build
    else
      exec uv run --with-requirements requirements.txt func start --port "$SKILL_PORT" --no-build
    fi
  ) >"$stdout_log" 2>"$stderr_log" &
  skill_pid=$!

  started_at="$(ps -p "$skill_pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" || started_at=""
  printf '%s\t%s\t%s\t%s\n' "$SKILL_NAME" "$SKILL_PORT" "$skill_pid" "$started_at" >>"$STATE_FILE"
  if [[ -z "$started_at" ]]; then
    echo "[$SKILL_NAME] could not record process identity for PID $skill_pid." >&2
    exit 1
  fi

  deadline=$((SECONDS + 90))
  while ((SECONDS < deadline)); do
    if ! kill -0 "$skill_pid" 2>/dev/null; then
      if ((attempt == 1)) && grep -Fq "Value cannot be null. (Parameter 'provider')" "$stderr_log" 2>/dev/null; then
        remove_pid_record "$skill_pid"
        echo "[$SKILL_NAME] Azure Functions Core Tools reported a transient provider error. Retrying once." >&2
        break
      fi
      echo "[$SKILL_NAME] MCP skill exited before becoming ready on port $SKILL_PORT." >&2
      tail -n 40 "$stdout_log" "$stderr_log" >&2 2>/dev/null || true
      "$SCRIPT_SELF_DIR/mcp-skill-stop.sh" --run-dir "$RUN_DIR" --name "$SKILL_NAME" >/dev/null 2>&1 || true
      exit 1
    fi

    resp_file="$RUN_DIR/.mcp-probe-$SKILL_NAME.$$"
    http_code="$(curl -sS -N --max-time 1 -o "$resp_file" -w '%{http_code}' \
      -X POST "$MCP_URL" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      --data "$MCP_INIT_PAYLOAD" 2>/dev/null || true)"
    resp_body=""
    if [[ -f "$resp_file" ]]; then
      resp_body="$(cat "$resp_file" 2>/dev/null || true)"
      rm -f "$resp_file"
    fi

    if [[ "$http_code" == "200" ]] && mcp_response_valid "$resp_body"; then
      echo "[$SKILL_NAME] MCP READY at $MCP_URL"
      exit 0
    fi
    sleep 0.15
  done

  if kill -0 "$skill_pid" 2>/dev/null; then
    echo "[$SKILL_NAME] timed out waiting for MCP initialize at $MCP_URL." >&2
    tail -n 40 "$stdout_log" "$stderr_log" >&2 2>/dev/null || true
    "$SCRIPT_SELF_DIR/mcp-skill-stop.sh" --run-dir "$RUN_DIR" --name "$SKILL_NAME" >/dev/null 2>&1 || true
    exit 1
  fi
done

echo "[$SKILL_NAME] failed to start MCP skill on port $SKILL_PORT." >&2
exit 1
