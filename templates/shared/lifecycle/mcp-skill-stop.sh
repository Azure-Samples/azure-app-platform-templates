#!/usr/bin/env bash
set -u

RUN_DIR=""
TARGET_NAME=""
PS_COMMAND="${APP_PLATFORM_PS_COMMAND:-ps}"
PGREP_COMMAND="${APP_PLATFORM_PGREP_COMMAND:-pgrep}"
KILL_COMMAND="${APP_PLATFORM_KILL_COMMAND:-kill}"
SLEEP_COMMAND="${APP_PLATFORM_SLEEP_COMMAND:-sleep}"

while (($#)); do
  case "$1" in
    --run-dir)
      RUN_DIR="${2:-}"
      shift
      ;;
    --name)
      TARGET_NAME="${2:-}"
      shift
      ;;
    --help|-h)
      echo "Usage: mcp-skill-stop.sh --run-dir <dir> [--name <name>]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "$RUN_DIR" ]]; then
  echo "Missing --run-dir for mcp-skill-stop.sh." >&2
  exit 2
fi

STATE_FILE="$RUN_DIR/processes.posix.tsv"
NEXT_STATE="$STATE_FILE.mcp.$$"

[[ -f "$STATE_FILE" ]] || exit 0

process_started_at() {
  "$PS_COMMAND" -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

parent_pid() {
  "$PS_COMMAND" -p "$1" -o ppid= 2>/dev/null | tr -d '[:space:]'
}

is_protected_pid() {
  local candidate="$1" current="$$" parent
  [[ "$candidate" =~ ^[0-9]+$ ]] && ((candidate > 1)) || return 0
  while [[ "$current" =~ ^[0-9]+$ ]] && ((current > 1)); do
    [[ "$candidate" == "$current" ]] && return 0
    parent="$(parent_pid "$current")"
    [[ "$parent" =~ ^[0-9]+$ ]] && [[ "$parent" != "$current" ]] || break
    current="$parent"
  done
  return 1
}

process_matches() {
  local current
  current="$(process_started_at "$1")"
  [[ -n "$current" && "$current" == "$2" ]]
}

kill_tree() {
  local pid="$1" expected_start="$2" child child_start
  process_matches "$pid" "$expected_start" || return 0
  while read -r child; do
    [[ "$child" =~ ^[0-9]+$ ]] || continue
    if is_protected_pid "$child"; then
      echo "Refusing to stop protected descendant PID $child." >&2
      return 1
    fi
    child_start="$(process_started_at "$child")"
    [[ -n "$child_start" ]] || continue
    kill_tree "$child" "$child_start" || return 1
  done < <("$PGREP_COMMAND" -P "$pid" 2>/dev/null || true)

  process_matches "$pid" "$expected_start" || return 0
  "$KILL_COMMAND" "$pid" 2>/dev/null || true
  for _ in {1..20}; do
    process_matches "$pid" "$expected_start" || return 0
    "$SLEEP_COMMAND" 0.1
  done
  process_matches "$pid" "$expected_start" || return 0
  "$KILL_COMMAND" -9 "$pid" 2>/dev/null || true
  for _ in {1..10}; do
    process_matches "$pid" "$expected_start" || return 0
    "$SLEEP_COMMAND" 0.1
  done
  ! process_matches "$pid" "$expected_start"
}

trap 'rm -f "$NEXT_STATE"' EXIT
: >"$NEXT_STATE" || exit 1
failures=0

while IFS=$'\t' read -r name port pid started_at; do
  [[ -n "${name}${port}${pid}${started_at}" ]] || continue
  if [[ -n "$TARGET_NAME" && "$name" != "$TARGET_NAME" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$name" "$port" "$pid" "$started_at" >>"$NEXT_STATE"
    continue
  fi
  if [[ ! "$pid" =~ ^[0-9]+$ ]] || ((10#$pid <= 1)); then
    printf '%s\t%s\t%s\t%s\n' "$name" "$port" "$pid" "$started_at" >>"$NEXT_STATE"
    echo "[$name] invalid tracked PID '$pid'." >&2
    failures=1
    continue
  fi
  current_start="$(process_started_at "$pid")"
  [[ -n "$current_start" ]] || continue
  if [[ -z "$started_at" ]]; then
    printf '%s\t%s\t%s\t\n' "$name" "$port" "$pid" >>"$NEXT_STATE"
    echo "[$name] PID $pid has no recorded start identity." >&2
    failures=1
    continue
  fi
  if [[ "$current_start" != "$started_at" ]]; then
    continue
  fi
  if is_protected_pid "$pid"; then
    printf '%s\t%s\t%s\t%s\n' "$name" "$port" "$pid" "$started_at" >>"$NEXT_STATE"
    echo "[$name] refusing to stop ancestor PID $pid." >&2
    failures=1
    continue
  fi
  if ! kill_tree "$pid" "$started_at"; then
    printf '%s\t%s\t%s\t%s\n' "$name" "$port" "$pid" "$started_at" >>"$NEXT_STATE"
    echo "[$name] failed to stop PID $pid." >&2
    failures=1
  fi
done <"$STATE_FILE"

if [[ -s "$NEXT_STATE" ]]; then
  mv "$NEXT_STATE" "$STATE_FILE"
else
  rm -f "$STATE_FILE" "$NEXT_STATE"
fi
trap - EXIT
exit "$failures"
