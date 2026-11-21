load_app_ports() {
  local file="$1/.azure-app-platform/ports.env" key value seen="|" used="|"
  [[ -f "$file" ]] || return 0
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    value="${value%$'\r'}"
    [[ -n "$key" ]] || continue
    case "$key" in
      AGENT_PORT|WEB_PORT|SKILL_PORT|INVENTORY_SEARCH_PORT|TRADE_IN_VALUE_PORT|RATE_SHEET_PORT|DEAL_DOC_PORT|AZURITE_BLOB_PORT|AZURITE_QUEUE_PORT|AZURITE_TABLE_PORT) ;;
      SKILL_*_PORT)
        if [[ ! "$key" =~ ^SKILL_[A-Z0-9_]+_PORT$ ]]; then
          echo "Invalid port settings key in .azure-app-platform/ports.env" >&2
          return 1
        fi
        ;;
      *) echo "Invalid port settings key in .azure-app-platform/ports.env" >&2; return 1 ;;
    esac
    if [[ ! "$value" =~ ^[0-9]{4,5}$ ]] || ((10#$value < 1024 || 10#$value > 65535)); then
      echo "Port settings must be integers from 1024 to 65535." >&2
      return 1
    fi
    value="$((10#$value))"
    if [[ "$seen" == *"|$key|"* || "$used" == *"|$value|"* ]]; then
      echo "Duplicate port settings are not allowed." >&2
      return 1
    fi
    seen="$seen$key|"
    used="$used$value|"
    export "$key=$value"
  done <"$file"
}

skill_port_env_name() {
  local raw="$1" normalized
  normalized="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]+/_/g; s/^_+//; s/_+$//')"
  printf 'SKILL_%s_PORT' "$normalized"
}

skill_port_for_name() {
  local skill_name="$1" index="${2:-0}" single_skill="${3:-1}" env_name candidate
  env_name="$(skill_port_env_name "$skill_name")"
  candidate="${!env_name:-}"
  if [[ -z "$candidate" && "$single_skill" == "1" && "$index" == "0" ]]; then
    candidate="${SKILL_PORT:-}"
  fi
  if [[ -z "$candidate" ]]; then
    candidate="$((7071 + index))"
  fi
  if [[ ! "$candidate" =~ ^[0-9]{4,5}$ ]] || ((10#$candidate < 1024 || 10#$candidate > 65535)); then
    echo "$env_name must be an integer from 1024 to 65535." >&2
    return 1
  fi
  printf '%s' "$((10#$candidate))"
}
