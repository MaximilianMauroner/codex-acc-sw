#!/usr/bin/env bash
set -euo pipefail

# codex-accounts.sh — manage multiple Codex CLI accounts
# Storage layout:
#   Auths:  ~/.codex/accounts/<account>.auth.json
#   State:  ~/.codex/switch/state   (CURRENT=..., PREVIOUS=...)

CODENAME="codex"
SCRIPT_PATH="$(
  python3 - "${BASH_SOURCE[0]}" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
CODEX_HOME="${HOME}/.codex"
AUTH_FILE="${CODEX_HOME}/auth.json"
DATA_DIR="${CODEX_HOME}/accounts"
STATE_DIR="${CODEX_HOME}/switch"
STATE_FILE="${STATE_DIR}/state"
USAGE_AUTO_REFRESH_TIMEOUT_SECONDS=3
USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS=8

# ------------- utils -------------
die() { echo "[ERR] $*" >&2; exit 1; }
note() { echo "[*] $*"; }
ok()  { echo "[OK] $*"; }

is_help_flag() {
  local arg="${1:-}"
  [[ "$arg" == "--help" || "$arg" == "-h" || "$arg" == "help" ]]
}

ensure_dirs() {
  mkdir -p "$CODEX_HOME" "$DATA_DIR" "$STATE_DIR"
}

load_state() {
  CURRENT=""; PREVIOUS=""
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
  fi
}

save_state() {
  local cur="$1" prev="$2"
  printf "CURRENT=%q\nPREVIOUS=%q\n" "$cur" "$prev" > "$STATE_FILE"
}

account_id_for_auth_path() {
  local path="$1"
  python3 - "$path" <<'PY'
import json
import os
import sys

path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)

try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, json.JSONDecodeError):
    sys.exit(0)

account_id = ((data.get("tokens") or {}).get("account_id") or "").strip()
if account_id:
    print(account_id)
PY
}

current_account_name_from_auth() {
  [[ -f "$AUTH_FILE" ]] || return 0

  local live_account_id
  live_account_id="$(account_id_for_auth_path "$AUTH_FILE")"
  [[ -n "${live_account_id:-}" ]] || return 0

  shopt -s nullglob
  local f base saved_account_id
  for f in "$DATA_DIR"/*.auth.json; do
    base="$(basename "$f")"
    base="${base%.auth.json}"
    saved_account_id="$(account_id_for_auth_path "$f")"
    if [[ -n "${saved_account_id:-}" && "$saved_account_id" == "$live_account_id" ]]; then
      echo "$base"
      return 0
    fi
  done
}

resolved_current_account_name() {
  local detected
  detected="$(current_account_name_from_auth)"
  if [[ -n "${detected:-}" ]]; then
    echo "$detected"
  else
    echo "${CURRENT:-}"
  fi
}

fetch_live_usage_snapshot() {
  local auth_path="${1:-$AUTH_FILE}"
  local timeout_seconds="${2:-$USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS}"
  python3 \
    "$SCRIPT_DIR/scripts/fetch_codex_rate_limits.py" \
    "$auth_path" \
    "$timeout_seconds"
}

sync_active_auth_to_saved_account() {
  local name="$1"
  local dest
  dest="$(auth_path_for "$name")"
  [[ -f "$AUTH_FILE" ]] || return 0
  [[ -f "$dest" ]] || return 0

  cp "$AUTH_FILE" "$dest"
  chmod 600 "$dest"
}

format_usage_snapshot_json() {
  local snapshot_json="$1"
  local status="${2:-live}"

  python3 - "$snapshot_json" "$status" <<'PY'
import datetime as dt
import json
import sys

snapshot = json.loads(sys.argv[1])
status = sys.argv[2]

def fmt(value):
    if value is None:
        return "n/a"
    value = float(value)
    if value.is_integer():
        return f"{int(value)}%"
    return f"{value:.1f}%"

def fmt_ts(value):
    if not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return value
    local_value = parsed.astimezone()
    return local_value.strftime("%b %d, %Y %H:%M")

parts = [
    f"window: {fmt(snapshot.get('current_remaining_percent'))}",
    f"week: {fmt(snapshot.get('weekly_remaining_percent'))}",
]

last_seen = fmt_ts(snapshot.get("last_seen_at"))
if last_seen:
    parts.append(f"updated: {last_seen}")

if status:
    parts.append(status)

print(" | ".join(parts))
PY
}

fetch_and_format_usage_for_auth_path() {
  local name="$1"
  local auth_path="$2"
  local timeout_seconds="${3:-$USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS}"

  local snapshot_json
  if ! snapshot_json="$(fetch_live_usage_snapshot "$auth_path" "$timeout_seconds" 2>/dev/null)"; then
    echo "window: n/a | week: n/a | live fetch failed"
    return 1
  fi

  if [[ "$auth_path" == "$AUTH_FILE" ]]; then
    sync_active_auth_to_saved_account "$name" >/dev/null 2>&1 || true
  fi

  format_usage_snapshot_json "$snapshot_json" "live"
}

display_usage_for_saved_account() {
  local name="$1"
  local timeout_seconds="${2:-$USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS}"
  local active_current="${3:-}"

  local auth_path
  if [[ -n "${active_current:-}" && "$name" == "$active_current" ]]; then
    auth_path="$AUTH_FILE"
  else
    auth_path="$(auth_path_for "$name")"
  fi

  fetch_and_format_usage_for_auth_path "$name" "$auth_path" "$timeout_seconds"
}

auth_path_for() {
  local name="$1"
  echo "${DATA_DIR}/${name}.auth.json"
}

saved_account_exists() {
  local name="$1"
  [[ -f "$(auth_path_for "$name")" ]]
}

assert_auth_present_or_hint() {
  if [[ ! -f "$AUTH_FILE" ]]; then
    die "~/.codex/auth.json not found. You likely haven't logged in yet.
Run: ${CODENAME} login"
  fi
}

prompt_account_name() {
  local ans
  read -r -p "Enter a name for the CURRENT logged-in account (e.g., personal, work): " ans
  [[ -z "${ans:-}" ]] && die "Account name cannot be empty."
  echo "$ans"
}

backup_current_to() {
  # Save only the active auth payload, not the rest of ~/.codex.
  local name="$1"
  local quiet="${2:-0}"
  assert_auth_present_or_hint

  local dest; dest="$(auth_path_for "$name")"
  if [[ "$quiet" != "1" ]]; then
    note "Saving current auth.json to ${dest}..."
  fi
  cp "$AUTH_FILE" "$dest"
  chmod 600 "$dest"
  if [[ "$quiet" != "1" ]]; then
    ok "Saved."
  fi
}

activate_saved_account() {
  local name="$1"
  local quiet="${2:-0}"
  local src; src="$(auth_path_for "$name")"

  if [[ "$quiet" != "1" ]]; then
    note "Activating '${name}'..."
  fi
  mkdir -p "$CODEX_HOME"
  if [[ -f "$src" ]]; then
    cp "$src" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    if [[ "$quiet" != "1" ]]; then
      ok "Activated ${AUTH_FILE}."
    fi
    return
  fi

  die "No saved account named '${name}'. Use '$0 list' to see options."
}

resolve_current_name_or_prompt() {
  # If CURRENT is unknown but auth.json matches a saved account, recover it from disk.
  # Otherwise ask once so we can save the current login under a name.
  load_state
  if [[ -z "${CURRENT:-}" && -f "$AUTH_FILE" ]]; then
    local detected
    detected="$(current_account_name_from_auth)"
    if [[ -n "${detected:-}" ]]; then
      CURRENT="$detected"
      save_state "$CURRENT" "${PREVIOUS:-}"
      return
    fi
    local named; named="$(prompt_account_name)"
    backup_current_to "$named"
    PREVIOUS=""
    CURRENT="$named"
    save_state "$CURRENT" "$PREVIOUS"
  fi
}

# ------------- commands -------------
cmd_list() {
  ensure_dirs
  load_state
  local active_current
  active_current="$(resolved_current_account_name)"

  shopt -s nullglob
  local any=0
  local f base label usage
  for f in "$DATA_DIR"/*.auth.json; do
    any=1
    base="$(basename "$f")"
    base="${base%.auth.json}"
    label=" - ${base}"
    if [[ "${active_current:-}" == "$base" ]]; then
      label="${label} [active]"
    fi
    usage="$(display_usage_for_saved_account "$base" "$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS" "$active_current" || true)"
    echo "${label} | ${usage}"
  done
  if [[ $any -eq 0 ]]; then
    echo "(no accounts saved yet)"
  fi
}

cmd_current() {
  load_state
  local active_current
  active_current="$(resolved_current_account_name)"
  if [[ -n "${active_current:-}" ]]; then
    local usage
    usage="$(display_usage_for_saved_account "$active_current" "$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS" "$active_current" || true)"
    echo "Active:   $active_current | ${usage}"
  else
    echo "Active:   (unknown — no state recorded yet)"
  fi
}

cmd_save() {
  # Save only the currently logged-in account auth under a name.
  if is_help_flag "${1:-}"; then
    cat <<EOF
Usage: $0 save [<name>]

Save the current ~/.codex/auth.json into ${DATA_DIR}/<name>.auth.json.
If <name> is omitted, you'll be prompted.
EOF
    return
  fi

  ensure_dirs
  assert_auth_present_or_hint

  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name="$(prompt_account_name)"
  fi

  load_state
  local prior_current
  prior_current="$(resolved_current_account_name)"

  backup_current_to "$name"

  PREVIOUS="${prior_current:-}"
  CURRENT="$name"
  save_state "$CURRENT" "$PREVIOUS"
}

cmd_add() {
  # Prepare for a new login without touching config, history, logs, or sessions.
  if is_help_flag "${1:-}"; then
    cat <<EOF
Usage: $0 add <new-account-name>

Backs up the current auth if needed, removes ~/.codex/auth.json,
then lets you run '${CODENAME} login' for the new account.
EOF
    return
  fi

  ensure_dirs
  resolve_current_name_or_prompt

  local newname="${1:-}"
  [[ -z "$newname" ]] && die "Usage: $0 add <new-account-name>"

  if [[ -f "$AUTH_FILE" ]]; then
    note "Removing current auth.json to prepare login for '${newname}'..."
    rm -f "$AUTH_FILE"
  fi

  ok "Ready. Now run: ${CODENAME} login  (to authenticate '${newname}')"
  echo "After login completes, run: $0 save ${newname}   (to store the new account)"
}

cmd_switch() {
  # Switch to a saved account by swapping only auth.json.
  if is_help_flag "${1:-}"; then
    cat <<EOF
Usage: $0 switch <account-name>

Backs up the current ~/.codex/auth.json first, then replaces it with
the saved auth for <account-name>.
EOF
    return
  fi

  local target="${1:-}"
  [[ -z "$target" ]] && die "Usage: $0 switch <account-name>"

  ensure_dirs
  resolve_current_name_or_prompt
  local active_current=""

  if [[ -f "$AUTH_FILE" ]]; then
    load_state
    active_current="$(resolved_current_account_name)"
    if [[ -z "${active_current:-}" ]]; then
      active_current="$(prompt_account_name)"
    fi
    backup_current_to "$active_current" 1
  fi

  activate_saved_account "$target" 1

  load_state
  PREVIOUS="${active_current:-${CURRENT:-}}"
  CURRENT="$target"
  save_state "$CURRENT" "$PREVIOUS"
  local usage
  usage="$(display_usage_for_saved_account "$CURRENT" "$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS" "$CURRENT" || true)"
  echo "Switched to ${CURRENT} | ${usage}"
}

cmd_refresh() {
  if is_help_flag "${1:-}"; then
    cat <<EOF
Usage: $0 refresh

Try to fetch a fresh usage snapshot for the currently active account.
EOF
    return
  fi

  ensure_dirs
  load_state

  local active_current
  active_current="$(resolved_current_account_name)"
  [[ -n "${active_current:-}" ]] || die "No active account found."
  assert_auth_present_or_hint

  local usage
  if usage="$(display_usage_for_saved_account "$active_current" "$USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS" "$active_current")"; then
    echo "Refreshed ${active_current} | ${usage}"
    return
  fi

  echo "Refresh failed for ${active_current} | ${usage}"
  return 1
}

cmd_rename() {
  if is_help_flag "${1:-}"; then
    cat <<EOF
Usage: $0 rename <old-name> <new-name>

Rename a saved account from <old-name> to <new-name>.
Also updates current/previous state if needed.
EOF
    return
  fi

  ensure_dirs

  local old_name="${1:-}"
  local new_name="${2:-}"
  [[ -z "$old_name" || -z "$new_name" ]] && die "Usage: $0 rename <old-name> <new-name>"
  [[ "$old_name" == "$new_name" ]] && die "Old name and new name are the same."

  local old_path new_path
  old_path="$(auth_path_for "$old_name")"
  new_path="$(auth_path_for "$new_name")"

  [[ -f "$old_path" ]] || die "No saved account named '${old_name}'. Use '$0 list' to see options."
  [[ ! -f "$new_path" ]] || die "A saved account named '${new_name}' already exists."

  mv "$old_path" "$new_path"

  load_state
  if [[ "${CURRENT:-}" == "$old_name" ]]; then
    CURRENT="$new_name"
  fi
  if [[ "${PREVIOUS:-}" == "$old_name" ]]; then
    PREVIOUS="$new_name"
  fi
  save_state "${CURRENT:-}" "${PREVIOUS:-}"

  ok "Renamed '${old_name}' to '${new_name}'."
}

cmd_help() {
  cat <<EOF
codex-accounts.sh — manage multiple Codex CLI accounts

USAGE
  $0 <name>
      Shortcut for '$0 switch <name>' when <name> matches a saved account.

  $0 list
      Show all saved accounts (from ${DATA_DIR}) with live current/weekly remaining usage.

  $0 current
      Show the active account with live usage.

  $0 refresh
      Try to fetch a fresh usage snapshot for the active account.

  $0 save [<name>]
      Save the current ~/.codex/auth.json into ${DATA_DIR}/<name>.auth.json.
      If <name> is omitted, you'll be prompted.

  $0 add <name>
      Prepare to add a new account:
        - backs up current auth (prompting for its name if unknown),
        - removes ~/.codex/auth.json so you can run 'codex login',
        - after login, run: $0 save <name>

  $0 switch <name>
      Switch to an existing saved account by replacing ~/.codex/auth.json.
      Backs up the current auth first, then activates <name>.

  $0 rename <old-name> <new-name>
      Rename a saved account and update saved state references.

NOTES
  - Only auth.json is saved and restored. Your config, history, sessions, and logs stay in place.
  - Usage values are fetched live from the usage API every time they are shown.
  - list fetches live usage for each saved account using that account's saved auth file.
  - current and switch fetch live usage for the active account using ~/.codex/auth.json.
  - refresh uses a longer timeout for the same live API path.
  - If ~/.codex/auth.json is missing when saving/adding, you'll be prompted to login first.
  - Install Codex if needed:  brew install codex
EOF
}

# ------------- main -------------
main() {
  ensure_dirs

  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    list)    cmd_list "$@";;
    current) cmd_current "$@";;
    refresh) cmd_refresh "$@";;
    save)    cmd_save "$@";;
    add)     cmd_add "$@";;
    switch)  cmd_switch "$@";;
    rename)  cmd_rename "$@";;
    help|--help|-h) cmd_help;;
    *)
      if saved_account_exists "$cmd"; then
        cmd_switch "$cmd" "$@"
      else
        die "Unknown command or saved account: $cmd. See '$0 help'."
      fi
      ;;
  esac
}

main "$@"
