#!/usr/bin/env bash
set -euo pipefail

# codex-accounts.sh — manage multiple Codex CLI accounts
# Storage layout:
#   Auths:  ~/codex-data/<account>.auth.json
#   State:  ~/.codex-switch/state   (CURRENT=..., PREVIOUS=...)

CODENAME="codex"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${HOME}/.codex"
AUTH_FILE="${CODEX_HOME}/auth.json"
DATA_DIR="${HOME}/codex-data"
STATE_DIR="${HOME}/.codex-switch"
STATE_FILE="${STATE_DIR}/state"
USAGE_FILE="${STATE_DIR}/usage.json"
USAGE_REFRESH_FILE="${STATE_DIR}/usage-refresh.json"
USAGE_AUTO_REFRESH_TIMEOUT_SECONDS=3
USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS=8
USAGE_REFRESH_COOLDOWN_SECONDS=30

# ------------- utils -------------
die() { echo "[ERR] $*" >&2; exit 1; }
note() { echo "[*] $*"; }
ok()  { echo "[OK] $*"; }

is_help_flag() {
  local arg="${1:-}"
  [[ "$arg" == "--help" || "$arg" == "-h" || "$arg" == "help" ]]
}

ensure_dirs() {
  mkdir -p "$DATA_DIR" "$STATE_DIR" "$CODEX_HOME"
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

latest_rate_limits_json() {
  python3 - "$CODEX_HOME" "${1:-0}" <<'PY'
import glob
import json
import os
import sys

codex_home = sys.argv[1]
min_mtime = float(sys.argv[2] or 0)
patterns = [
    os.path.join(codex_home, "sessions", "**", "*.jsonl"),
    os.path.join(codex_home, "archived_sessions", "*.jsonl"),
]

paths = []
for pattern in patterns:
    paths.extend(glob.glob(pattern, recursive=True))
paths = [p for p in paths if os.path.isfile(p)]
if min_mtime > 0:
    paths = [p for p in paths if os.path.getmtime(p) >= min_mtime]
paths.sort(key=os.path.getmtime, reverse=True)

def build_snapshot(event):
    payload = event.get("payload") or {}
    rate_limits = payload.get("rate_limits") or {}
    primary = rate_limits.get("primary") or {}
    secondary = rate_limits.get("secondary") or {}
    primary_used = primary.get("used_percent")
    secondary_used = secondary.get("used_percent")
    if primary_used is None and secondary_used is None:
        return None
    return {
        "last_seen_at": event.get("timestamp"),
        "current_remaining_percent": None if primary_used is None else max(0.0, 100.0 - float(primary_used)),
        "weekly_remaining_percent": None if secondary_used is None else max(0.0, 100.0 - float(secondary_used)),
        "current_window_minutes": primary.get("window_minutes"),
        "weekly_window_minutes": secondary.get("window_minutes"),
        "current_resets_at": primary.get("resets_at"),
        "weekly_resets_at": secondary.get("resets_at"),
    }

for path in paths[:50]:
    latest = None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                if '"type":"token_count"' not in line and '"type": "token_count"' not in line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                payload = event.get("payload") or {}
                if payload.get("type") != "token_count":
                    continue
                snapshot = build_snapshot(event)
                if snapshot is not None:
                    latest = snapshot
    except OSError:
        continue

    if latest is not None:
        print(json.dumps(latest, separators=(",", ":")))
        sys.exit(0)

sys.exit(1)
PY
}

auth_file_mtime() {
  python3 - "$AUTH_FILE" <<'PY'
import os
import sys

path = sys.argv[1]
if not os.path.exists(path):
    print("0")
else:
    print(f"{os.path.getmtime(path):.6f}")
PY
}

mark_usage_fresh() {
  local name="$1"
  local auth_mtime="$2"

  python3 - "$USAGE_REFRESH_FILE" "$name" "$auth_mtime" <<'PY'
import json
import os
import sys
import time

path, name, auth_mtime = sys.argv[1], sys.argv[2], sys.argv[3]
data = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle) or {}
    except (OSError, json.JSONDecodeError):
        data = {}

data[name] = {
    "fresh_auth_mtime": auth_mtime,
    "refreshed_at": time.time(),
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
PY
}

rename_usage_refresh_state() {
  local old_name="$1"
  local new_name="$2"

  python3 - "$USAGE_REFRESH_FILE" "$old_name" "$new_name" <<'PY'
import json
import os
import sys

path, old_name, new_name = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.exists(path):
    sys.exit(0)

try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, json.JSONDecodeError):
    sys.exit(0)

if old_name not in data:
    sys.exit(0)

data[new_name] = data.pop(old_name)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
PY
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
  local timeout_seconds="${1:-$USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS}"
  python3 \
    "$SCRIPT_DIR/scripts/fetch_codex_rate_limits.py" \
    "$AUTH_FILE" \
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

write_usage_snapshot() {
  local name="$1"
  local snapshot_json="$2"

  python3 - "$USAGE_FILE" "$name" "$snapshot_json" <<'PY'
import json
import os
import sys

path, name, snapshot_raw = sys.argv[1], sys.argv[2], sys.argv[3]
snapshot = json.loads(snapshot_raw)
data = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        data = {}

current = data.get(name) or {}
if snapshot.get("last_seen_at", "") >= current.get("last_seen_at", ""):
    data[name] = snapshot

with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
PY
}

refresh_usage_cache_for_current_account() {
  local name="$1"
  [[ -z "${name:-}" ]] && return 0
  [[ -f "$AUTH_FILE" ]] || return 0

  local min_mtime
  min_mtime="$(auth_file_mtime)"

  local snapshot_json
  if snapshot_json="$(latest_rate_limits_json "$min_mtime" 2>/dev/null)"; then
    write_usage_snapshot "$name" "$snapshot_json" >/dev/null 2>&1 || true
  fi
}

rename_usage_snapshot() {
  local old_name="$1"
  local new_name="$2"

  python3 - "$USAGE_FILE" "$old_name" "$new_name" <<'PY'
import json
import os
import sys

path, old_name, new_name = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.exists(path):
    sys.exit(0)

try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, json.JSONDecodeError):
    sys.exit(0)

if old_name not in data:
    sys.exit(0)

data[new_name] = data.pop(old_name)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
PY
}

usage_freshness_label() {
  local name="$1"
  local is_active="${2:-0}"

  if [[ "$is_active" != "1" ]]; then
    echo "cached"
    return 0
  fi

  local auth_mtime
  auth_mtime="$(auth_file_mtime)"

  python3 - "$USAGE_REFRESH_FILE" "$name" "$auth_mtime" "$USAGE_REFRESH_COOLDOWN_SECONDS" <<'PY'
import json
import os
import sys
import time

path, name, auth_mtime, cooldown = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
if not os.path.exists(path):
    print("cached")
    sys.exit(0)

try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle) or {}
except (OSError, json.JSONDecodeError):
    print("cached")
    sys.exit(0)

entry = data.get(name) or {}
same_auth = str(entry.get("fresh_auth_mtime", "")) == str(auth_mtime)
refreshed_at = float(entry.get("refreshed_at", 0) or 0)
if same_auth and (time.time() - refreshed_at < cooldown):
    print("fresh")
else:
    print("cached")
PY
}

format_usage_suffix() {
  local name="$1"
  local freshness="${2:-}"

  python3 - "$USAGE_FILE" "$name" "$freshness" <<'PY'
import json
import os
import sys

path, name, freshness = sys.argv[1], sys.argv[2], sys.argv[3]
entry = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            entry = (json.load(handle) or {}).get(name) or {}
    except (OSError, json.JSONDecodeError):
        entry = {}

def fmt(value):
    if value is None:
        return "n/a"
    value = float(value)
    if value.is_integer():
        return f"{int(value)}%"
    return f"{value:.1f}%"

parts = [
    f"current: {fmt(entry.get('current_remaining_percent'))}",
    f"weekly: {fmt(entry.get('weekly_remaining_percent'))}",
]

last_seen = entry.get("last_seen_at")
if last_seen:
    parts.append(f"last seen: {last_seen}")

if freshness:
    parts.append(freshness)

print(" | ".join(parts))
PY
}

refresh_usage_for_active_account() {
  local name="$1"
  local timeout_seconds="${2:-$USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS}"
  [[ -n "${name:-}" ]] || return 1
  [[ -f "$AUTH_FILE" ]] || return 1

  local auth_mtime
  auth_mtime="$(auth_file_mtime)"

  local tmp_snapshot
  tmp_snapshot="$(mktemp "${TMPDIR:-/tmp}/acc-sw-rate-limits.XXXXXX")"

  if ! fetch_live_usage_snapshot "$timeout_seconds" >"$tmp_snapshot" 2>/dev/null; then
    rm -f "$tmp_snapshot"
    return 1
  fi

  local snapshot_json
  snapshot_json="$(cat "$tmp_snapshot")"
  rm -f "$tmp_snapshot"

  write_usage_snapshot "$name" "$snapshot_json" >/dev/null 2>&1 || true
  sync_active_auth_to_saved_account "$name" >/dev/null 2>&1 || true
  mark_usage_fresh "$name" "$auth_mtime" >/dev/null 2>&1 || true
}

refresh_usage_for_active_display() {
  local name="$1"
  [[ -n "${name:-}" ]] || return 0

  refresh_usage_cache_for_current_account "$name"
  refresh_usage_for_active_account "$name" "$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS" >/dev/null 2>&1 || true
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
  refresh_usage_for_active_display "$active_current"

  shopt -s nullglob
  local any=0
  local f base label usage
  for f in "$DATA_DIR"/*.auth.json; do
    any=1
    base="$(basename "$f")"
    base="${base%.auth.json}"
    label=" - ${base}"
    if [[ "${active_current:-}" == "$base" ]]; then
      label="${label} [current]"
    elif [[ "${PREVIOUS:-}" == "$base" ]]; then
      label="${label} [previous]"
    fi
    local freshness="cached"
    if [[ "${active_current:-}" == "$base" ]]; then
      freshness="$(usage_freshness_label "$base" 1)"
    fi
    usage="$(format_usage_suffix "$base" "$freshness")"
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
  refresh_usage_for_active_display "$active_current"
  if [[ -n "${active_current:-}" ]]; then
    local freshness
    freshness="$(usage_freshness_label "$active_current" 1)"
    echo "Current:  $active_current | $(format_usage_suffix "$active_current" "$freshness")"
  else
    echo "Current:  (unknown — no state recorded yet)"
  fi
  if [[ -n "${PREVIOUS:-}" ]]; then
    echo "Previous: $PREVIOUS"
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
  refresh_usage_cache_for_current_account "$CURRENT"
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
    refresh_usage_cache_for_current_account "$active_current"
    backup_current_to "$active_current" 1
  fi

  activate_saved_account "$target" 1

  load_state
  PREVIOUS="${active_current:-${CURRENT:-}}"
  CURRENT="$target"
  save_state "$CURRENT" "$PREVIOUS"
  refresh_usage_for_active_display "$CURRENT"
  echo "Switched to ${CURRENT} | $(format_usage_suffix "$CURRENT" "$(usage_freshness_label "$CURRENT" 1)")"
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

  if refresh_usage_for_active_account "$active_current" "$USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS"; then
    echo "Refreshed ${active_current} | $(format_usage_suffix "$active_current" "fresh")"
    return
  fi

  refresh_usage_cache_for_current_account "$active_current"
  echo "Refresh failed for ${active_current} | $(format_usage_suffix "$active_current" "cached")"
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
  rename_usage_snapshot "$old_name" "$new_name" >/dev/null 2>&1 || true
  rename_usage_refresh_state "$old_name" "$new_name" >/dev/null 2>&1 || true

  ok "Renamed '${old_name}' to '${new_name}'."
}

cmd_help() {
  cat <<EOF
codex-accounts.sh — manage multiple Codex CLI accounts

USAGE
  $0 <name>
      Shortcut for '$0 switch <name>' when <name> matches a saved account.

  $0 list
      Show all saved accounts (from ${DATA_DIR}) with cached current/weekly remaining usage.

  $0 current
      Show current and previous accounts from the state.

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
  - Usage values come from the latest Codex rate-limit snapshot seen locally for each account.
  - switch/current/list do a short best-effort live refresh for the active account, then fall back to cached usage.
  - Run '$0 refresh' when you want a longer explicit live probe for the active account.
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
