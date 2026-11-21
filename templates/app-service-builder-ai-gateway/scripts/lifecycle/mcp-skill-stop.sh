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
  local current="" state=""
  state="$("$PS_COMMAND" -p "$1" -o state= 2>/dev/null | tr -d '[:space:]')" || return 1
  [[ -n "$state" && "$state" != Z* ]] || return 1
  current="$(process_started_at "$1")"
  [[ -n "$current" && "$current" == "$2" ]]
}

process_pgid() {
  "$PS_COMMAND" -o pgid= -p "$1" 2>/dev/null | tr -d '[:space:]'
}

pgroup_live_pids() {
  "$PS_COMMAND" -axo pid=,pgid=,state= 2>/dev/null |
    awk -v g="$1" '$2 == g && $3 !~ /^Z/ { print $1 }'
}

kill_process_group() {
  local pgid="$1" members="" member=""
  members="$(pgroup_live_pids "$pgid")"
  while read -r member; do
    [[ "$member" =~ ^[0-9]+$ ]] || continue
    if is_protected_pid "$member"; then
      echo "Refusing to stop protected process-group member PID $member." >&2
      return 1
    fi
  done <<<"$members"

  "$KILL_COMMAND" -TERM -- -"$pgid" 2>/dev/null ||
    "$KILL_COMMAND" -TERM -"$pgid" 2>/dev/null ||
    "$KILL_COMMAND" -TERM "$pgid" 2>/dev/null || true

  for _ in {1..25}; do
    if [[ -z "$(pgroup_live_pids "$pgid")" ]]; then
      return 0
    fi
    "$KILL_COMMAND" -TERM -- -"$pgid" 2>/dev/null ||
      "$KILL_COMMAND" -TERM -"$pgid" 2>/dev/null || true
    "$SLEEP_COMMAND" 0.1
  done

  if [[ -n "$(pgroup_live_pids "$pgid")" ]]; then
    "$KILL_COMMAND" -KILL -- -"$pgid" 2>/dev/null ||
      "$KILL_COMMAND" -9 -"$pgid" 2>/dev/null ||
      "$KILL_COMMAND" -KILL "$pgid" 2>/dev/null || true
  fi

  for _ in {1..10}; do
    if [[ -z "$(pgroup_live_pids "$pgid")" ]]; then
      return 0
    fi
    "$SLEEP_COMMAND" 0.1
  done

  [[ -z "$(pgroup_live_pids "$pgid")" ]]
}

collect_descendants() {
  local parent="$1" child="" child_start="" children=""
  children="$("$PGREP_COMMAND" -P "$parent" 2>/dev/null || true)"
  while read -r child; do
    [[ "$child" =~ ^[0-9]+$ ]] || continue
    case "$TREE_SEEN_PIDS" in
      *" $child "*) continue ;;
    esac
    if is_protected_pid "$child"; then
      echo "Refusing to stop protected descendant PID $child." >&2
      return 1
    fi
    child_start="$(process_started_at "$child")"
    [[ -n "$child_start" ]] || continue
    TREE_SEEN_PIDS="${TREE_SEEN_PIDS}${child} "
    TREE_ENTRIES="${TREE_ENTRIES}${child}"$'\t'"${child_start}"$'\n'
    collect_descendants "$child" || return 1
  done <<<"$children"
  return 0
}

any_tree_alive() {
  local entry_pid="" entry_start=""
  while IFS=$'\t' read -r entry_pid entry_start; do
    [[ -n "$entry_pid" ]] || continue
    if process_matches "$entry_pid" "$entry_start"; then
      return 0
    fi
  done <<<"$TREE_ENTRIES"
  return 1
}

kill_tree() {
  local pid="$1" expected_start="$2" caller_pgid="" target_pgid="" entry_pid="" entry_start=""
  process_matches "$pid" "$expected_start" || return 0

  caller_pgid="$(process_pgid "$$")"
  target_pgid="$(process_pgid "$pid")"
  if [[ -n "$target_pgid" && "$target_pgid" == "$pid" && "$target_pgid" != "$caller_pgid" ]]; then
    kill_process_group "$pid"
    return $?
  fi

  TREE_SEEN_PIDS=" $pid "
  TREE_ENTRIES="${pid}"$'\t'"${expected_start}"$'\n'
  collect_descendants "$pid" || return 1

  # Signal supervisor first, then snapshot any newly spawned children before signaling descendants.
  "$KILL_COMMAND" -TERM "$pid" 2>/dev/null || true
  collect_descendants "$pid" || return 1

  while IFS=$'\t' read -r entry_pid entry_start; do
    [[ -n "$entry_pid" && "$entry_pid" != "$pid" ]] || continue
    if process_matches "$entry_pid" "$entry_start"; then
      "$KILL_COMMAND" -TERM "$entry_pid" 2>/dev/null || true
      collect_descendants "$entry_pid" || return 1
    fi
  done <<<"$TREE_ENTRIES"

  # Signal any late descendants discovered during the pass above.
  while IFS=$'\t' read -r entry_pid entry_start; do
    [[ -n "$entry_pid" && "$entry_pid" != "$pid" ]] || continue
    if process_matches "$entry_pid" "$entry_start"; then
      "$KILL_COMMAND" -TERM "$entry_pid" 2>/dev/null || true
    fi
  done <<<"$TREE_ENTRIES"

  for _ in {1..25}; do
    any_tree_alive || return 0
    "$SLEEP_COMMAND" 0.1
  done

  while IFS=$'\t' read -r entry_pid entry_start; do
    [[ -n "$entry_pid" ]] || continue
    if process_matches "$entry_pid" "$entry_start"; then
      collect_descendants "$entry_pid" || return 1
      "$KILL_COMMAND" -KILL "$entry_pid" 2>/dev/null || true
    fi
  done <<<"$TREE_ENTRIES"

  while IFS=$'\t' read -r entry_pid entry_start; do
    [[ -n "$entry_pid" ]] || continue
    if process_matches "$entry_pid" "$entry_start"; then
      "$KILL_COMMAND" -KILL "$entry_pid" 2>/dev/null || true
    fi
  done <<<"$TREE_ENTRIES"

  for _ in {1..10}; do
    any_tree_alive || return 0
    "$SLEEP_COMMAND" 0.1
  done
  ! any_tree_alive
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
