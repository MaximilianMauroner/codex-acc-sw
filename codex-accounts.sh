#!/usr/bin/env bash
set -euo pipefail

# codex-accounts.sh — manage multiple Codex CLI accounts
# Storage layout:
#   Auths:  ~/.codex/accounts/<account>.auth.json
#   State:  ~/.codex/switch/state   (CURRENT=..., PREVIOUS=...)

CODENAME="codex"
COMMAND_NAME="codex-account-switch"
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
CONFIG_FILE="${STATE_DIR}/config"
USAGE_CACHE_DIR="${STATE_DIR}/usage-cache"
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
  mkdir -p \
    "$CODEX_HOME" \
    "$DATA_DIR" \
    "$STATE_DIR" \
    "$USAGE_CACHE_DIR/codex" \
    "$USAGE_CACHE_DIR/claude"
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

load_config() {
  DISPLAY_RESET_STYLE="human"
  DISPLAY_SHOW_CLAUDE="1"

  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" || true
  fi

  case "${DISPLAY_RESET_STYLE:-}" in
    human|normal) ;;
    *) DISPLAY_RESET_STYLE="human" ;;
  esac

  case "${DISPLAY_SHOW_CLAUDE:-}" in
    0|1) ;;
    *) DISPLAY_SHOW_CLAUDE="1" ;;
  esac
}

save_config() {
  printf "DISPLAY_RESET_STYLE=%q\nDISPLAY_SHOW_CLAUDE=%q\n" \
    "$DISPLAY_RESET_STYLE" "$DISPLAY_SHOW_CLAUDE" > "$CONFIG_FILE"
}

normalize_toggle() {
  local value="${1:-}"
  case "$value" in
    1|on|true|yes|y) echo 1 ;;
    0|off|false|no|n) echo 0 ;;
    *) return 1 ;;
  esac
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

account_identity_for_auth_path() {
  local account_id
  account_id="$(account_id_for_auth_path "$1")"
  [[ -n "${account_id:-}" ]] || return 0
  printf '%s' "$account_id" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
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
  elif [[ -f "$AUTH_FILE" ]]; then
    # A live auth that cannot be positively matched must not inherit stale state.
    # Otherwise an automatic usage refresh could overwrite CURRENT's saved auth.
    return 0
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

fetch_live_usage_result_json() {
  local auth_path="${1:-$AUTH_FILE}"
  local timeout_seconds="${2:-$USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS}"
  local snapshot_json error_file error_json status message
  error_file="$(mktemp)"
  if snapshot_json="$(fetch_live_usage_snapshot "$auth_path" "$timeout_seconds" 2>"$error_file")"; then
    rm -f "$error_file"
    python3 - "$snapshot_json" <<'PY'
import json
import sys

print(json.dumps({"status": "ok", "message": "", "snapshot": json.loads(sys.argv[1])}, separators=(",", ":")))
PY
    return 0
  fi

  error_json="$(<"$error_file")"
  rm -f "$error_file"
  status="$(json_field_value "$error_json" "status")"
  message="$(json_field_value "$error_json" "message")"
  [[ -n "${status:-}" ]] || status="fetch_failed"
  [[ -n "${message:-}" ]] || message="Codex usage could not be fetched."
  python3 - "$status" "$message" <<'PY'
import json
import sys

print(json.dumps({"status": sys.argv[1], "message": sys.argv[2], "snapshot": None}, separators=(",", ":")))
PY
}

fetch_claude_status_json() {
  local timeout_seconds="${1:-$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS}"
  local credential_service="${CODEX_ACCOUNT_SWITCH_CLAUDE_CREDENTIAL_SERVICE:-Claude Code-credentials}"

  python3 - "$timeout_seconds" "$credential_service" <<'PY'
import datetime as dt
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

timeout_seconds = float(sys.argv[1])
credential_service = sys.argv[2]
usage_url = "https://api.anthropic.com/api/oauth/usage"


def now_iso():
    return (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def emit(status, message, snapshot=None):
    print(
        json.dumps(
            {
                "status": status,
                "message": message,
                "snapshot": snapshot,
            },
            separators=(",", ":"),
        )
    )
    return 0 if status == "ok" else 1


if shutil.which("security") is None:
    raise SystemExit(
        emit("missing_security", "macOS security command is not available.")
    )

try:
    completed = subprocess.run(
        ["security", "find-generic-password", "-s", credential_service, "-w"],
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(emit("network_error", "Timed out reading Claude credentials."))

if completed.returncode != 0 or not completed.stdout.strip():
    raise SystemExit(
        emit(
            "missing_credentials",
            "Claude Code credentials were not found. Open Claude Code and sign in.",
        )
    )

try:
    credentials = json.loads(completed.stdout)
except json.JSONDecodeError:
    raise SystemExit(
        emit("missing_token", "Claude Code credentials could not be parsed.")
    )

access_token = (
    (credentials.get("claudeAiOauth") or {}).get("accessToken") or ""
).strip()
if not access_token:
    raise SystemExit(
        emit("missing_token", "Claude Code access token is missing. Sign in again.")
    )

request = urllib.request.Request(
    usage_url,
    headers={
        "Accept": "application/json",
        "Authorization": f"Bearer {access_token}",
        "anthropic-beta": "oauth-2025-04-20",
    },
)

try:
    with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
        payload = json.loads(response.read().decode("utf-8"))
except urllib.error.HTTPError as exc:
    if exc.code in (401, 403):
        raise SystemExit(
            emit("unauthorized", "Claude Code login expired. Sign in again.")
        )
    raise SystemExit(
        emit("network_error", f"Claude usage API returned HTTP {exc.code}.")
    )
except urllib.error.URLError as exc:
    raise SystemExit(emit("network_error", f"Claude usage API unavailable: {exc.reason}"))
except TimeoutError:
    raise SystemExit(emit("network_error", "Claude usage API request timed out."))
except json.JSONDecodeError:
    raise SystemExit(
        emit("invalid_response", "Claude usage API returned invalid JSON.")
    )

if payload.get("error"):
    raise SystemExit(
        emit("invalid_response", "Claude usage API returned an error payload.")
    )

five_hour = payload.get("five_hour") or {}
seven_day = payload.get("seven_day") or {}
five_hour_util = five_hour.get("utilization")
seven_day_util = seven_day.get("utilization")

if five_hour_util is None and seven_day_util is None:
    raise SystemExit(
        emit("invalid_response", "Claude usage payload has no utilization data.")
    )

snapshot = {
    "last_seen_at": now_iso(),
    "plan_type": None,
    "current_remaining_percent": None
    if five_hour_util is None
    else round(max(0.0, 100.0 - float(five_hour_util)), 1),
    "weekly_remaining_percent": None
    if seven_day_util is None
    else round(max(0.0, 100.0 - float(seven_day_util)), 1),
    "current_window_minutes": 300.0,
    "weekly_window_minutes": 10080.0,
    "current_resets_at": five_hour.get("resets_at"),
    "weekly_resets_at": seven_day.get("resets_at"),
}

raise SystemExit(emit("ok", "", snapshot))
PY
}

fetch_claude_snapshot() {
  local timeout_seconds="${1:-$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS}"
  local result_json
  result_json="$(fetch_claude_status_json "$timeout_seconds")" || return 1

  python3 - "$result_json" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
if data.get("status") != "ok" or not data.get("snapshot"):
    sys.exit(1)
print(json.dumps(data["snapshot"], separators=(",", ":")))
PY
}

print_divider() {
  local label="${1:-}"
  local width="${2:-52}"
  python3 -c "
label = '$label'
width = $width
if label:
    prefix = '── ' + label + ' '
    print(prefix + '─' * max(0, width - len(prefix)))
else:
    print('─' * width)
"
}

sync_active_auth_to_saved_account() {
  local name="$1"
  local dest
  dest="$(auth_path_for "$name")"
  [[ -f "$AUTH_FILE" ]] || return 0
  [[ -f "$dest" ]] || return 0

  local live_account_id saved_account_id
  live_account_id="$(account_id_for_auth_path "$AUTH_FILE")"
  saved_account_id="$(account_id_for_auth_path "$dest")"
  [[ -n "${live_account_id:-}" ]] || return 1
  [[ -n "${saved_account_id:-}" ]] || return 1
  [[ "$live_account_id" == "$saved_account_id" ]] || return 1

  cp "$AUTH_FILE" "$dest"
  chmod 600 "$dest"
}

format_usage_snapshot_json() {
  local snapshot_json="$1"
  local is_active="${2:-0}"
  local account_name="${3:-}"
  local max_name_len="${4:-0}"
  load_config

  python3 - \
    "$snapshot_json" \
    "$is_active" \
    "$account_name" \
    "$max_name_len" \
    "$DISPLAY_RESET_STYLE" <<'PY'
import datetime as dt
import json
import sys

snapshot = json.loads(sys.argv[1])
is_active = sys.argv[2] == "1"
account_name = sys.argv[3]
max_name_len = int(sys.argv[4])
reset_style = sys.argv[5]


RESET  = "\033[0m"
RED    = "\033[31m"
YELLOW = "\033[33m"
GREEN  = "\033[32m"


def fmt_pct(value):
    """Always returns 4 visible chars: number right-padded to 3 + '%'."""
    if value is None:
        return " n/a"
    return str(round(float(value))).rjust(3) + "%"


def week_color(weekly_remaining):
    if weekly_remaining is None:
        return ""
    pct = float(weekly_remaining)
    if pct == 0:
        return RED
    if pct <= 10:
        return YELLOW
    if pct > 60:
        return GREEN
    return ""


def fmt_ts(value):
    if not value:
        return None
    parsed = None
    if isinstance(value, (int, float)):
        parsed = dt.datetime.fromtimestamp(float(value), tz=dt.timezone.utc)
    elif isinstance(value, str):
        try:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            try:
                parsed = dt.datetime.fromtimestamp(float(value), tz=dt.timezone.utc)
            except ValueError:
                return value
    if parsed is None:
        return None
    return parsed.astimezone().strftime("%b %d, %Y %H:%M")


def fmt_relative_reset(value, hide_minutes_if_days=False):
    if not value:
        return None
    parsed = None
    if isinstance(value, (int, float)):
        parsed = dt.datetime.fromtimestamp(float(value), tz=dt.timezone.utc)
    elif isinstance(value, str):
        try:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            try:
                parsed = dt.datetime.fromtimestamp(float(value), tz=dt.timezone.utc)
            except ValueError:
                return None
    if parsed is None:
        return None
    now = dt.datetime.now(dt.timezone.utc)
    remaining_seconds = max(0, int((parsed - now).total_seconds()))
    if remaining_seconds < 60:
        return "<1m"
    days, remainder = divmod(remaining_seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, _ = divmod(remainder, 60)
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours or days:
        parts.append(f"{hours}h")
    if not (hide_minutes_if_days and days):
        parts.append(f"{minutes}m")
    return "".join(parts)


plan_type = snapshot.get("plan_type")
is_free_plan = plan_type == "free"

marker = "* " if is_active else "  "
name = account_name.ljust(max_name_len)

if is_free_plan:
    print(f"{marker}{name}  free plan")
    sys.exit(0)

weekly_remaining = snapshot.get("weekly_remaining_percent")
window_remaining = snapshot.get("current_remaining_percent")

def colored_pct(value):
    raw = fmt_pct(value)
    c = week_color(value)
    return f"{c}{raw}{RESET}" if c else raw

window_pct = colored_pct(window_remaining)
week_pct   = colored_pct(weekly_remaining)

current_reset_value = snapshot.get("current_resets_at")
weekly_reset_value = snapshot.get("weekly_resets_at")

if reset_style == "human":
    current_reset = fmt_relative_reset(current_reset_value) or "n/a"
    weekly_reset = fmt_relative_reset(weekly_reset_value, hide_minutes_if_days=True) or "n/a"
else:
    current_reset = fmt_ts(current_reset_value) or "n/a"
    weekly_reset = fmt_ts(weekly_reset_value) or "n/a"

suffix_parts = []
if snapshot.get("stale"):
    suffix_parts.append("stale")
if snapshot.get("status_label"):
    suffix_parts.append(str(snapshot["status_label"]))
suffix = "  " + " / ".join(suffix_parts) if suffix_parts else ""
print(f"{marker}{name}  5h: {window_pct}  week: {week_pct}  reset: {current_reset.ljust(5)} / {weekly_reset.ljust(5)}{suffix}")
PY
}

read_usage_cache_snapshot_json() {
  local cache_path="$1"
  [[ -f "$cache_path" ]] || return 1

  python3 - "$cache_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
print(json.dumps(data, separators=(",", ":")))
PY
}

snapshot_with_display_metadata_json() {
  local snapshot_json="$1"
  local stale="${2:-0}"
  local status_label="${3:-}"

  python3 - "$snapshot_json" "$stale" "$status_label" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
if sys.argv[2] == "1":
    data["stale"] = True
if sys.argv[3]:
    data["status_label"] = sys.argv[3]
print(json.dumps(data, separators=(",", ":")))
PY
}

status_label_for() {
  local status="${1:-}"
  python3 - "$status" <<'PY'
import sys

status = sys.argv[1]
labels = {
    "fetch_failed": "fetch failed",
    "invalid_response": "invalid response",
    "login_expired": "login expired",
    "missing_credentials": "login needed",
    "missing_security": "security command missing",
    "missing_token": "login needed",
    "network_error": "network error",
    "no_cache": "checking usage",
    "unauthorized": "login needed",
}
print(labels.get(status, status.replace("_", " ") if status else "error"))
PY
}

format_cached_usage_snapshot() {
  local name="$1"
  local is_active="${2:-0}"
  local max_name_len="${3:-${#name}}"
  local cache_path
  cache_path="$(usage_cache_path_for "$name")"

  local snapshot_json
  snapshot_json="$(read_usage_cache_snapshot_json "$cache_path")" || return 1
  snapshot_json="$(snapshot_with_display_metadata_json "$snapshot_json" "1")" || return 1

  format_usage_snapshot_json "$snapshot_json" "$is_active" "$name" "$max_name_len"
}

fetch_and_format_usage_for_auth_path() {
  local name="$1"
  local auth_path="$2"
  local timeout_seconds="${3:-$USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS}"
  local is_active="${4:-0}"
  local max_name_len="${5:-${#name}}"

  local result_json snapshot_json status message
  result_json="$(fetch_live_usage_result_json "$auth_path" "$timeout_seconds")"
  status="$(json_field_value "$result_json" "status")"
  if [[ "$status" != "ok" ]]; then
    if format_cached_usage_snapshot "$name" "$is_active" "$max_name_len"; then
      return 0
    fi

    local marker="  "
    [[ "$is_active" == "1" ]] && marker="* "
    message="$(status_label_for "$status")"
    printf "%s%-*s  %s\n" "$marker" "$max_name_len" "$name" "$message"
    return 1
  fi

  snapshot_json="$(json_snapshot_value "$result_json")"

  write_usage_cache_snapshot "$(usage_cache_path_for "$name")" "$snapshot_json"

  if [[ "$auth_path" == "$AUTH_FILE" ]]; then
    sync_active_auth_to_saved_account "$name" >/dev/null 2>&1 || true
  fi

  format_usage_snapshot_json "$snapshot_json" "$is_active" "$name" "$max_name_len"
}

display_usage_for_saved_account() {
  local name="$1"
  local timeout_seconds="${2:-$USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS}"
  local active_current="${3:-}"
  local max_name_len="${4:-${#name}}"

  local auth_path is_active=0
  if [[ -n "${active_current:-}" && "$name" == "$active_current" ]]; then
    auth_path="$AUTH_FILE"
    is_active=1
  else
    auth_path="$(auth_path_for "$name")"
  fi

  fetch_and_format_usage_for_auth_path "$name" "$auth_path" "$timeout_seconds" "$is_active" "$max_name_len"
}

auth_path_for() {
  local name="$1"
  echo "${DATA_DIR}/${name}.auth.json"
}

usage_cache_path_for() {
  local name="$1"
  local key
  key="$(printf '%s' "$name" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
  echo "${USAGE_CACHE_DIR}/codex/${key}.json"
}

claude_usage_cache_path() {
  echo "${USAGE_CACHE_DIR}/claude/usage.json"
}

write_usage_cache_snapshot() {
  local cache_path="$1"
  local snapshot_json="$2"
  local cache_dir tmp
  cache_dir="$(dirname -- "$cache_path")"
  mkdir -p "$cache_dir"
  tmp="$(mktemp "${cache_dir}/.usage.XXXXXX")"
  printf '%s\n' "$snapshot_json" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$cache_path"
}

json_field_value() {
  local json_value="$1"
  local field_name="$2"

  python3 - "$json_value" "$field_name" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(0)
value = data.get(sys.argv[2], "")
if value is None:
    value = ""
print(value)
PY
}

json_snapshot_value() {
  local json_value="$1"

  python3 - "$json_value" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(1)
snapshot = data.get("snapshot")
if not snapshot:
    sys.exit(1)
print(json.dumps(snapshot, separators=(",", ":")))
PY
}

append_widget_state_line() {
  local provider="$1"
  local name="$2"
  local is_active="${3:-0}"
  local status="${4:-ok}"
  local message="${5:-}"
  local stale="${6:-0}"
  local snapshot_json="${7:-}"
  local account_identity="${8:-}"

  python3 - \
    "$provider" \
    "$name" \
    "$is_active" \
    "$status" \
    "$message" \
    "$stale" \
    "$snapshot_json" \
    "$account_identity" <<'PY'
import json
import sys

provider, name, is_active, status, message, stale, snapshot_raw, account_identity = sys.argv[1:]
snapshot = None
if snapshot_raw:
    try:
        snapshot = json.loads(snapshot_raw)
    except json.JSONDecodeError:
        snapshot = None

print(
    json.dumps(
        {
            "provider": provider,
            "name": name,
            "account_identity": account_identity or None,
            "is_active": is_active == "1",
            "status": status,
            "message": message,
            "stale": stale == "1",
            "snapshot": snapshot,
        },
        separators=(",", ":"),
    )
)
PY
}

collect_codex_widget_lines() {
  local timeout_seconds="${1:-$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS}"
  local active_current="${2:-}"
  local mode="${3:-live}"

  shopt -s nullglob
  local f base auth_path is_active account_identity result_json status message snapshot_json cached_snapshot_json cache_path
  for f in "$DATA_DIR"/*.auth.json; do
    base="$(basename "$f")"
    base="${base%.auth.json}"
    auth_path="$(auth_path_for "$base")"
    is_active=0

    if [[ -n "${active_current:-}" && "$base" == "$active_current" ]]; then
      auth_path="$AUTH_FILE"
      is_active=1
    fi
    account_identity="$(account_identity_for_auth_path "$auth_path")"

    cache_path="$(usage_cache_path_for "$base")"
    if [[ "$mode" == "cached" ]]; then
      if cached_snapshot_json="$(read_usage_cache_snapshot_json "$cache_path" 2>/dev/null)"; then
        append_widget_state_line "codex" "$base" "$is_active" "ok" "" "0" "$cached_snapshot_json" "$account_identity"
      else
        append_widget_state_line \
          "codex" \
          "$base" \
          "$is_active" \
          "no_cache" \
          "No cached Codex usage yet. A background refresh is running." \
          "0" \
          "" \
          "$account_identity"
      fi
      continue
    fi

    result_json="$(fetch_live_usage_result_json "$auth_path" "$timeout_seconds")"
    status="$(json_field_value "$result_json" "status")"
    message="$(json_field_value "$result_json" "message")"
    if [[ "$status" == "ok" ]]; then
      snapshot_json="$(json_snapshot_value "$result_json")"
      write_usage_cache_snapshot "$(usage_cache_path_for "$base")" "$snapshot_json"
      if [[ "$auth_path" == "$AUTH_FILE" ]]; then
        sync_active_auth_to_saved_account "$base" >/dev/null 2>&1 || true
      fi
      append_widget_state_line "codex" "$base" "$is_active" "ok" "" "0" "$snapshot_json" "$account_identity"
      continue
    fi

    if cached_snapshot_json="$(read_usage_cache_snapshot_json "$cache_path" 2>/dev/null)"; then
      append_widget_state_line \
        "codex" \
        "$base" \
        "$is_active" \
        "$status" \
        "$message Showing cached data." \
        "1" \
        "$cached_snapshot_json" \
        "$account_identity"
    else
      append_widget_state_line \
        "codex" \
        "$base" \
        "$is_active" \
        "$status" \
        "$message" \
        "0" \
        "" \
        "$account_identity"
    fi
  done
}

collect_claude_widget_line() {
  local timeout_seconds="${1:-$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS}"
  local mode="${2:-live}"
  local result_json status message snapshot_json cached_snapshot_json cache_path

  cache_path="$(claude_usage_cache_path)"
  if [[ "$mode" == "cached" ]]; then
    if cached_snapshot_json="$(read_usage_cache_snapshot_json "$cache_path" 2>/dev/null)"; then
      append_widget_state_line "claude" "claude" "0" "ok" "" "0" "$cached_snapshot_json"
    else
      append_widget_state_line \
        "claude" \
        "claude" \
        "0" \
        "no_cache" \
        "No cached Claude usage yet. A background refresh is running." \
        "0"
    fi
    return 0
  fi

  if result_json="$(fetch_claude_status_json "$timeout_seconds" 2>/dev/null)"; then
    snapshot_json="$(json_snapshot_value "$result_json")" || return 0
    write_usage_cache_snapshot "$(claude_usage_cache_path)" "$snapshot_json"
    append_widget_state_line "claude" "claude" "0" "ok" "" "0" "$snapshot_json"
    return 0
  fi

  status="$(json_field_value "$result_json" "status")"
  message="$(json_field_value "$result_json" "message")"
  [[ -n "${status:-}" ]] || status="network_error"
  [[ -n "${message:-}" ]] || message="Claude usage could not be fetched."

  if cached_snapshot_json="$(read_usage_cache_snapshot_json "$cache_path" 2>/dev/null)"; then
    append_widget_state_line "claude" "claude" "0" "$status" "$message" "1" "$cached_snapshot_json"
  else
    append_widget_state_line "claude" "claude" "0" "$status" "$message" "0"
  fi
}

state_snapshot_for_display_json() {
  local state_json="$1"

  python3 - "$state_json" <<'PY'
import json
import sys

labels = {
    "fetch_failed": "fetch failed",
    "invalid_response": "invalid response",
    "login_expired": "login expired",
    "missing_credentials": "login needed",
    "missing_security": "security command missing",
    "missing_token": "login needed",
    "network_error": "network error",
    "no_cache": "checking usage",
    "unauthorized": "login needed",
}

state = json.loads(sys.argv[1])
snapshot = state.get("snapshot")
if not snapshot:
    sys.exit(1)
snapshot = dict(snapshot)
if state.get("stale"):
    snapshot["stale"] = True
status = state.get("status")
if status and status != "ok":
    snapshot["status_label"] = labels.get(status, status.replace("_", " "))
print(json.dumps(snapshot, separators=(",", ":")))
PY
}

format_usage_state_json() {
  local state_json="$1"
  local max_name_len="${2:-6}"
  local name is_active status label snapshot_json

  name="$(json_field_value "$state_json" "name")"
  is_active="$(json_field_value "$state_json" "is_active")"
  status="$(json_field_value "$state_json" "status")"

  if snapshot_json="$(state_snapshot_for_display_json "$state_json" 2>/dev/null)"; then
    if [[ "$is_active" == "True" || "$is_active" == "true" ]]; then
      format_usage_snapshot_json "$snapshot_json" "1" "$name" "$max_name_len"
    else
      format_usage_snapshot_json "$snapshot_json" "0" "$name" "$max_name_len"
    fi
    return 0
  fi

  label="$(status_label_for "$status")"
  printf "  %-*s  %s\n" "$max_name_len" "$name" "$label"
}

build_widget_snapshot_json() {
  local timeout_seconds="${1:-$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS}"
  local mode="${2:-live}"
  local active_current tmp status

  ensure_dirs
  load_state
  load_config
  active_current="$(resolved_current_account_name)"
  tmp="$(mktemp)"

  {
    collect_codex_widget_lines "$timeout_seconds" "$active_current" "$mode"
    if [[ "$DISPLAY_SHOW_CLAUDE" == "1" ]]; then
      collect_claude_widget_line "$timeout_seconds" "$mode"
    fi
  } > "$tmp"

  if python3 - "$tmp" "$active_current" "$mode" <<'PY'
import datetime as dt
import json
import sys

path = sys.argv[1]
active_current = sys.argv[2]
mode = sys.argv[3]

items = []
with open(path, "r", encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        items.append(json.loads(line))

payload = {
    "generated_at": (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    ),
    "mode": mode,
    "active_codex_account": active_current or None,
    "accounts": items,
}
print(json.dumps(payload, separators=(",", ":")))
PY
  then
    status=0
  else
    status=$?
  fi
  rm -f "$tmp"
  return "$status"
}

format_widget_swiftbar_json() {
  local widget_json="$1"

  python3 - "$widget_json" <<'PY'
import datetime as dt
import json
import os
import sys

data = json.loads(sys.argv[1])
items = data.get("accounts") or []
mode = data.get("mode") or "live"
refresh_reason = os.environ.get("SWIFTBAR_PLUGIN_REFRESH_REASON") or ""
login_statuses = {
    "login_expired",
    "missing_credentials",
    "missing_token",
    "unauthorized",
}
status_labels = {
    "fetch_failed": "fetch failed",
    "invalid_response": "invalid response",
    "login_expired": "login expired",
    "missing_credentials": "login needed",
    "missing_security": "security command missing",
    "missing_token": "login needed",
    "network_error": "network error",
    "no_cache": "checking usage",
    "unauthorized": "login needed",
}

CLAUDE_ICON = "iVBORw0KGgoAAAANSUhEUgAAAA4AAAAOCAYAAAAfSC3RAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAADqADAAQAAAABAAAADgAAAAC98Dn6AAACH0lEQVQoFXVRO2iTURQ+5940iW0qDoq0W6MQa8Vgq+JSEQrFB4pi8gtSJ5cuXUzyBxRECgq2jraLiuAk6ZAq2KF1cFEHBVtoTOLiGqnRqtE2Nf89fjexJUU8cF/nnO9x7yVqinzauVt0ndfrqXwi3ldMxa+vn5tX1XxgoQoxH8mnYoM2z1qdE6V67b6YOL29kHSG7N5GHVh0YwMF90zn8sqPW8h9YtZuvUqyk4QWUWsnX+ssaXq4kBxs2wCC+iZzcH5bIHRQjFxlpoH3Ceco1g4iM08UfITmAxjXondmf24Af1Wrx4X4BazNwUMXVHJK0w2Y7cQ4ycxnhejJntuZMQuywY2lMRfSjkPCE1AKkUhAmFaYuJVIlla93/uCxt/haYqykgCj2RUhDw1fjDHLSLIiPQrKnibS7yBqgeo39L01LE99TPIKwN3CElKad0AxQCy1ZjMiUsZVsiD7APWv7MmbzVbdeATfMY7kLgDDUAw2VCUL8DOo9aPeLyRlny3MjJwIhIPto3iEYSMCmww38hLW+kAShVIEoM8LH+WyM5XxLKb+j+EtWy9i111dq9knRwhuSs+xmQNoEldZBUlpfxc/zsXjftuxyWo+GTumtH5gKmuHua0lhXLJq5j7OqQW8Z/3jPA7zeSPjGWm64qWwQYrPUy12qnuiWwZlIcMU6lncqriiXeJSfXuHc/MWFCj+z9zIX1hOnfl/F/r/zb9ATsgx8Yrel7sAAAAAElFTkSuQmCC"
CODEX_ICON = "iVBORw0KGgoAAAANSUhEUgAAAA4AAAAOCAYAAAAfSC3RAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAADqADAAQAAAABAAAADgAAAAC98Dn6AAABV0lEQVQoFcWSMUvDUBSFk/RVGtGmGaQuDqKzIvgDBHETEdwEBZ3EUZ3dXBwd1MHFof9AENzFSYuDP0DXDk2qQ0NI4nfaEmKxrl54uefce857j5tnW4Xwfd+DnmdZtmXbtgHfd7vdk0ql8tVut8OC1LKLBGMDvl2ssUnGJjapxToNw/BafWdIlBa5sEyDPOU4zpXneQc9rg8xXqvVGmg2+3T0VycHQVDv7YbpFtMuxRcss2B/tNWy4jiuOxy9inBtILwjH/9lUs8Y4zqY9jjpWQXwURRFD/Cm+G9B752rfmg4kxjWJaI4Vi6XXeCP0aunoB+laXooaCCPGDfUIF8wuQXyijihf/opQG2GdNnpdF7FS1ztyXXdafCyCsQOogkBTE2W/mOaJMkNpjfVFfkDqFar8wgWqRnyGWtOAnwt8D4vR4PLIzfmlT4oMe0lTIZTNKhoqP8P9BsTUYh1tCDg5gAAAABJRU5ErkJggg=="


def provider_icon_params(provider):
    if provider == "claude":
        return {"image": CLAUDE_ICON, "imageWidth": "14", "imageHeight": "14"}
    if provider == "codex":
        return {"templateImage": CODEX_ICON, "imageWidth": "14", "imageHeight": "14"}
    return {}


def clean(value):
    return str(value).replace("|", "/").replace("\n", " ").strip()


def fmt_pct(value):
    if value is None:
        return "n/a"
    return f"{round(float(value))}%"


def fmt_reset(value, hide_minutes_if_days=False):
    if not value:
        return "n/a"
    parsed = None
    if isinstance(value, (int, float)):
        parsed = dt.datetime.fromtimestamp(float(value), tz=dt.timezone.utc)
    elif isinstance(value, str):
        try:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            try:
                parsed = dt.datetime.fromtimestamp(float(value), tz=dt.timezone.utc)
            except ValueError:
                return clean(value)
    if parsed is None:
        return "n/a"
    remaining_seconds = max(
        0, int((parsed - dt.datetime.now(dt.timezone.utc)).total_seconds())
    )
    if remaining_seconds < 60:
        return "<1m"
    days, remainder = divmod(remaining_seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, _ = divmod(remainder, 60)
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours or days:
        parts.append(f"{hours}h")
    if not (hide_minutes_if_days and days):
        parts.append(f"{minutes}m")
    return "".join(parts)


def fmt_checked_at(value):
    if not value:
        return "checked just now"
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return f"checked {clean(value)}"
    seconds = max(0, int((dt.datetime.now(dt.timezone.utc) - parsed).total_seconds()))
    if seconds < 20:
        return "checked just now"
    if seconds < 60:
        return f"checked {seconds}s ago"
    minutes = seconds // 60
    if minutes < 60:
        return f"checked {minutes}m ago"
    hours = minutes // 60
    return f"checked {hours}h ago"


def parsed_dt(value):
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def newest_snapshot_time():
    candidates = []
    for item in items:
        snapshot = item.get("snapshot") or {}
        parsed = parsed_dt(snapshot.get("last_seen_at"))
        if parsed is not None:
            candidates.append(parsed)
    return max(candidates) if candidates else parsed_dt(data.get("generated_at"))


def fmt_local_time(parsed):
    if not parsed:
        return "unknown"
    return parsed.astimezone().strftime("%H:%M")


def fmt_age(parsed):
    if not parsed:
        return "unknown age"
    seconds = seconds_since(parsed)
    if seconds < 20:
        return "just now"
    if seconds < 60:
        return f"{seconds}s ago"
    minutes = seconds // 60
    if minutes < 60:
        return f"{minutes}m ago"
    hours = minutes // 60
    return f"{hours}h ago"


def seconds_since(parsed):
    if not parsed:
        return 10**9
    return max(0, int((dt.datetime.now(dt.timezone.utc) - parsed).total_seconds()))


def refresh_label(reason):
    if mode == "cached":
        return "checking now"
    labels = {
        "open": "refreshed on open",
        "manual": "manual refresh",
        "scheduled": "scheduled refresh",
    }
    return labels.get(reason, "latest snapshot")


def as_float(value):
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def fmt_duration_seconds(value, hide_minutes_if_days=False):
    seconds = max(0, int(value))
    if seconds < 60:
        return "<1m"
    days, remainder = divmod(seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, _ = divmod(remainder, 60)
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours or days:
        parts.append(f"{hours}h")
    if not (hide_minutes_if_days and days):
        parts.append(f"{minutes}m")
    return "".join(parts) if parts else "<1m"


def pct_color(value):
    if value is None:
        return ""
    pct = float(value)
    if pct == 0:
        return "red"
    if pct <= 10:
        return "orange"
    if pct > 60:
        return "green"
    return ""


def limiting_remaining(snapshot):
    values = [
        as_float(snapshot.get("current_remaining_percent")),
        as_float(snapshot.get("weekly_remaining_percent")),
    ]
    values = [value for value in values if value is not None]
    if not values:
        return None
    return min(values)


PACE_RANKS = {
    "critical": 4,
    "watch": 3,
    "steady": 2,
    "learning": 1,
    "unknown": 0,
    "free": 0,
}


def pace_for(snapshot, period):
    short_label = "5h" if period == "current" else "week"
    remaining_key = (
        "current_remaining_percent"
        if period == "current"
        else "weekly_remaining_percent"
    )
    reset_key = "current_resets_at" if period == "current" else "weekly_resets_at"
    window_key = (
        "current_window_minutes"
        if period == "current"
        else "weekly_window_minutes"
    )

    if not snapshot:
        return {
            "severity": "unknown",
            "color": "gray",
            "rank": PACE_RANKS["unknown"],
            "detail": f"{short_label} learning",
        }
    if snapshot.get("plan_type") == "free":
        return {
            "severity": "free",
            "color": "gray",
            "rank": PACE_RANKS["free"],
            "detail": f"{short_label} free plan",
        }

    remaining = as_float(snapshot.get(remaining_key))
    reset_at = parsed_dt(snapshot.get(reset_key))
    seen_at = parsed_dt(snapshot.get("last_seen_at")) or dt.datetime.now(dt.timezone.utc)
    window_minutes = as_float(snapshot.get(window_key))
    if window_minutes is None:
        window_minutes = 300.0 if period == "current" else 10080.0

    if remaining is None or reset_at is None or not window_minutes:
        return {
            "severity": "unknown",
            "color": "gray",
            "rank": PACE_RANKS["unknown"],
            "detail": f"{short_label} learning",
        }

    if remaining <= 0:
        return {
            "severity": "critical",
            "color": "red",
            "rank": PACE_RANKS["critical"],
            "detail": f"{short_label} empty",
            "projected_remaining": 0.0,
        }

    seconds_to_reset = max(0, (reset_at - seen_at).total_seconds())
    window_seconds = max(1.0, window_minutes * 60.0)
    elapsed_seconds = max(0.0, window_seconds - seconds_to_reset)
    used_percent = max(0.0, 100.0 - remaining)

    min_elapsed = 10 * 60 if period == "current" else 60 * 60
    if elapsed_seconds < min_elapsed:
        return {
            "severity": "learning",
            "color": "gray",
            "rank": PACE_RANKS["learning"],
            "detail": f"{short_label} learning",
        }

    if used_percent < 0.5:
        return {
            "severity": "steady",
            "color": "green",
            "rank": PACE_RANKS["steady"],
            "detail": f"{short_label} idle",
            "projected_remaining": remaining,
        }

    burn_per_second = used_percent / elapsed_seconds
    projected_remaining = remaining - (burn_per_second * seconds_to_reset)
    projected_display = max(0, round(projected_remaining))

    if burn_per_second > 0:
        seconds_until_empty = remaining / burn_per_second
    else:
        seconds_until_empty = None

    if seconds_until_empty is not None and seconds_until_empty < seconds_to_reset:
        early_by = seconds_to_reset - seconds_until_empty
        return {
            "severity": "critical",
            "color": "red",
            "rank": PACE_RANKS["critical"],
            "detail": (
                f"{short_label} fast, empty "
                f"{fmt_duration_seconds(early_by, period == 'weekly')} early"
            ),
            "projected_remaining": projected_remaining,
        }

    if projected_remaining < 12:
        return {
            "severity": "watch",
            "color": "orange",
            "rank": PACE_RANKS["watch"],
            "detail": f"{short_label} tight, {projected_display}% at reset",
            "projected_remaining": projected_remaining,
        }

    return {
        "severity": "steady",
        "color": "green",
        "rank": PACE_RANKS["steady"],
        "detail": f"{short_label} steady, {projected_display}% at reset",
        "projected_remaining": projected_remaining,
    }


def pace_for_snapshot(snapshot):
    if not snapshot:
        return {
            "severity": "unknown",
            "color": "gray",
            "rank": PACE_RANKS["unknown"],
            "detail": "learning pace",
        }
    paces = [
        pace_for(snapshot, "current"),
        pace_for(snapshot, "weekly"),
    ]
    paces = [
        pace
        for pace in paces
        if pace.get("severity") not in ("unknown", "free")
    ]
    if not paces:
        return {
            "severity": "unknown",
            "color": "gray",
            "rank": PACE_RANKS["unknown"],
            "detail": "learning pace",
        }
    return max(paces, key=lambda pace: pace.get("rank", 0))


def pace_summary(snapshot):
    if not snapshot:
        return "Pace: learning"
    if snapshot.get("plan_type") == "free":
        return "Pace: free plan"
    details = []
    for period in ("current", "weekly"):
        pace = pace_for(snapshot, period)
        if pace.get("severity") not in ("unknown", "free"):
            details.append(pace.get("detail"))
    if not details:
        return "Pace: learning"
    return "Pace: " + "; ".join(details)


def pace_color_for_snapshot(snapshot):
    pace = pace_for_snapshot(snapshot)
    return pace.get("color") or pct_color(
        (snapshot or {}).get("current_remaining_percent")
    )


def snapshot_for(provider):
    matches = [item for item in items if item.get("provider") == provider]
    if provider == "codex":
        active = [item for item in matches if item.get("is_active")]
        matches = active + [item for item in matches if not item.get("is_active")]
    for item in matches:
        if item.get("snapshot"):
            return item.get("snapshot")
    return None


def item_for(provider):
    matches = [item for item in items if item.get("provider") == provider]
    if provider == "codex":
        active = [item for item in matches if item.get("is_active")]
        matches = active + [item for item in matches if not item.get("is_active")]
    return matches[0] if matches else None


def short(provider, label):
    item = item_for(provider)
    snapshot = item.get("snapshot") if item else None
    if not snapshot:
        return f"{label} n/a"
    if snapshot.get("plan_type") == "free":
        return f"{label} free"
    return f"{label} {fmt_pct(limiting_remaining(snapshot))}"


def menu_line(label, color=""):
    label = clean(label)
    if color:
        print(f"{label} | color={color}")
    else:
        print(label)


def menu_item(label, color="", **params):
    label = clean(label)
    parts = []
    if color:
        parts.append(f"color={color}")
    for key, value in params.items():
        if value is None or value == "":
            continue
        parts.append(f"{key}={clean(value)}")
    if parts:
        print(f"{label} | {' '.join(parts)}")
    else:
        print(label)


def attention_item(item):
    if not item:
        return False
    if item.get("provider") == "claude":
        return item.get("status") not in ("ok", None)
    if item.get("provider") == "codex" and item.get("is_active"):
        return item.get("status") not in ("ok", None)
    return False


active_codex = item_for("codex")
claude_item = item_for("claude")
attention_items = [item for item in (active_codex, claude_item) if attention_item(item)]
has_login_issue = any(item.get("status") in login_statuses for item in attention_items)
has_error = bool(attention_items)
has_stale = any(item.get("stale") for item in items)
newest_seen_at = newest_snapshot_time()
data_is_old = seconds_since(newest_seen_at) > 120
has_no_cache = any(item.get("status") == "no_cache" for item in items)


def item_pace(item):
    if not item or not item.get("snapshot"):
        return {
            "severity": "unknown",
            "color": "gray",
            "rank": PACE_RANKS["unknown"],
            "detail": "learning pace",
        }
    return pace_for_snapshot(item.get("snapshot"))


def title_candidates():
    return [
        item
        for item in (active_codex, claude_item)
        if item and item.get("snapshot")
    ]


def worst_title_item():
    candidates = title_candidates()
    if not candidates:
        return None
    return max(
        candidates,
        key=lambda item: (
            item_pace(item).get("rank", 0),
            -(as_float((item.get("snapshot") or {}).get("current_remaining_percent")) or 100),
        ),
    )


def title_pace_summary():
    parts = []
    for label, item in (("Codex", active_codex), ("Claude", claude_item)):
        if item and item.get("snapshot"):
            parts.append(f"{label} {item_pace(item).get('detail', 'learning pace')}")
    return "; ".join(parts) if parts else "Pace learning"


worst_title = worst_title_item()
title_pace = item_pace(worst_title)
title_color = title_pace.get("color") or ""
if title_pace.get("severity") in ("unknown", "learning") and (has_stale or data_is_old):
    title_color = "gray"

def title_provider():
    for item in attention_items:
        provider = item.get("provider")
        if provider in ("codex", "claude"):
            return provider
    if worst_title:
        provider = worst_title.get("provider")
        if provider in ("codex", "claude"):
            return provider
    return "codex"


title_icon = provider_icon_params(title_provider())

if has_login_issue:
    menu_item("AI login", "red", **title_icon)
elif has_error:
    menu_item("AI needs attention", "orange", **title_icon)
else:
    menu_item(
        f"{short('codex', 'Cdx')} · {short('claude', 'Cla')}",
        title_color,
        tooltip=(
            f"{title_pace_summary()}. "
            f"Data {fmt_age(newest_seen_at)}, {refresh_label(refresh_reason)}"
        ),
        **title_icon,
    )

print("---")
menu_item(
    f"Data: {fmt_local_time(newest_seen_at)} · {fmt_age(newest_seen_at)} · {refresh_label(refresh_reason)}",
    "orange" if has_no_cache or data_is_old else "gray",
    size="11",
    sfimage="arrow.clockwise" if mode == "cached" else ("checkmark.circle" if not has_error else "exclamationmark.triangle"),
)
menu_item(
    f"Refresh now...",
    "gray",
    refresh="true",
    sfimage="arrow.clockwise",
    tooltip="Shows cached data immediately, then warms the next snapshot in the background.",
)

print("---")
codex_items = [item for item in items if item.get("provider") == "codex"]
menu_item(
    f"Codex accounts ({len(codex_items)})",
    "gray",
    **provider_icon_params("codex"),
)
if not codex_items:
    menu_item("No Codex accounts saved", "gray")
for item in codex_items:
    snapshot = item.get("snapshot")
    status = item.get("status")
    if not snapshot:
        status_color = "orange" if status == "no_cache" else "red"
        menu_item(
            f"{item.get('name', 'codex')}: {status_labels.get(status, 'error')}",
            status_color,
        )
        if item.get("message"):
            menu_item(f"--{item.get('message')}", "gray", size="11")
        continue
    name = item.get("name", "codex")
    prefix = "* " if item.get("is_active") else "  "
    badges = []
    if item.get("stale"):
        badges.append("stale")
    if status and status != "ok":
        badges.append(status_labels.get(status, status.replace("_", " ")))
    suffix = f"  {' / '.join(badges)}" if badges else ""
    if snapshot.get("plan_type") == "free":
        line = f"{prefix}{name.ljust(12)} free plan{suffix}"
        row_color = "orange" if item.get("stale") or status != "ok" else "gray"
    else:
        current_remaining = snapshot.get("current_remaining_percent")
        weekly_remaining = snapshot.get("weekly_remaining_percent")
        pace = pace_for_snapshot(snapshot)
        line = (
            f"{prefix}{name.ljust(12)} "
            f"5h {fmt_pct(current_remaining).rjust(4)}   "
            f"week {fmt_pct(weekly_remaining).rjust(4)}"
            f"{suffix}"
        )
        row_color = (
            "orange"
            if item.get("stale") or status != "ok"
            else pace.get("color") or pct_color(current_remaining)
        )
    menu_item(
        line,
        row_color,
        font="Menlo",
        tooltip=(
            f"5h reset {fmt_reset(snapshot.get('current_resets_at'))}, "
            f"weekly reset {fmt_reset(snapshot.get('weekly_resets_at'), True)}, "
            f"{pace_summary(snapshot)}"
        ),
    )
    if snapshot.get("plan_type") != "free":
        menu_item(f"--{pace_summary(snapshot)}", row_color, size="11")
        menu_item(f"--5h reset: {fmt_reset(snapshot.get('current_resets_at'))}", "gray", size="11")
        menu_item(f"--Weekly reset: {fmt_reset(snapshot.get('weekly_resets_at'), True)}", "gray", size="11")
    if item.get("stale"):
        menu_item("--Showing last successful snapshot", "orange", size="11")
    if status and status != "ok" and item.get("message"):
        menu_item(f"--{item.get('message')}", "gray", size="11")

print("---")
claude_items = [item for item in items if item.get("provider") == "claude"]
menu_item("Claude", "gray", **provider_icon_params("claude"))
for item in claude_items:
    snapshot = item.get("snapshot")
    status = item.get("status")
    if not snapshot:
        message = item.get("message") or status_labels.get(status, "error")
        status_color = "orange" if status == "no_cache" else "red"
        menu_item(
            f"claude: {status_labels.get(status, 'error')}",
            status_color,
        )
        menu_item(f"--{message}", "gray", size="11")
        continue
    badges = []
    if item.get("stale"):
        badges.append("stale")
    if status and status != "ok":
        badges.append(status_labels.get(status, status.replace("_", " ")))
    suffix = f"  {' / '.join(badges)}" if badges else ""
    current_remaining = snapshot.get("current_remaining_percent")
    weekly_remaining = snapshot.get("weekly_remaining_percent")
    pace = pace_for_snapshot(snapshot)
    line = (
        f"claude        "
        f"5h {fmt_pct(current_remaining).rjust(4)}   "
        f"week {fmt_pct(weekly_remaining).rjust(4)}"
        f"{suffix}"
    )
    menu_item(
        line,
        (
            "orange"
            if item.get("stale") or status != "ok"
            else pace.get("color") or pct_color(current_remaining)
        ),
        font="Menlo",
        tooltip=(
            f"5h reset {fmt_reset(snapshot.get('current_resets_at'))}, "
            f"weekly reset {fmt_reset(snapshot.get('weekly_resets_at'), True)}, "
            f"{pace_summary(snapshot)}"
        ),
    )
    menu_item(
        f"--{pace_summary(snapshot)}",
        "orange" if item.get("stale") or status != "ok" else pace.get("color"),
        size="11",
    )
    menu_item(f"--5h reset: {fmt_reset(snapshot.get('current_resets_at'))}", "gray", size="11")
    menu_item(f"--Weekly reset: {fmt_reset(snapshot.get('weekly_resets_at'), True)}", "gray", size="11")
    if item.get("stale"):
        menu_item("--Showing last successful snapshot", "orange", size="11")
    if status and status != "ok" and item.get("message"):
        menu_item(f"--{item.get('message')}", "gray", size="11")

plugin_path = os.environ.get("SWIFTBAR_PLUGINS_PATH", "")
if plugin_path:
    print("---")
    menu_item("Open SwiftBar plugin folder", "gray", bash="/usr/bin/open", param1=plugin_path, terminal="false")
PY
}

format_widget_text_json() {
  local widget_json="$1"

  python3 - "$widget_json" <<'PY'
import datetime as dt
import json
import sys

data = json.loads(sys.argv[1])
items = data.get("accounts") or []
labels = {
    "fetch_failed": "fetch failed",
    "invalid_response": "invalid response",
    "login_expired": "login expired",
    "missing_credentials": "login needed",
    "missing_security": "security command missing",
    "missing_token": "login needed",
    "network_error": "network error",
    "no_cache": "checking usage",
    "unauthorized": "login needed",
}


def fmt_pct(value):
    if value is None:
        return "n/a"
    return f"{round(float(value))}%"


def fmt_reset(value, hide_minutes_if_days=False):
    if not value:
        return "n/a"
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return str(value)
    seconds = max(0, int((parsed - dt.datetime.now(dt.timezone.utc)).total_seconds()))
    if seconds < 60:
        return "<1m"
    days, remainder = divmod(seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, _ = divmod(remainder, 60)
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours or days:
        parts.append(f"{hours}h")
    if not (hide_minutes_if_days and days):
        parts.append(f"{minutes}m")
    return "".join(parts)


for provider in ("codex", "claude"):
    print(provider)
    provider_items = [item for item in items if item.get("provider") == provider]
    if not provider_items:
        print("  (none)")
    for item in provider_items:
        snapshot = item.get("snapshot")
        status = item.get("status")
        prefix = "* " if item.get("is_active") else "  "
        if not snapshot:
            print(f"{prefix}{item.get('name')}: {labels.get(status, 'error')}")
            continue
        badges = []
        if item.get("stale"):
            badges.append("stale")
        if status and status != "ok":
            badges.append(labels.get(status, status.replace("_", " ")))
        suffix = f"  ({', '.join(badges)})" if badges else ""
        if snapshot.get("plan_type") == "free":
            print(f"{prefix}{item.get('name')}  free plan{suffix}")
        else:
            print(
                f"{prefix}{item.get('name')}  "
                f"5h {fmt_pct(snapshot.get('current_remaining_percent'))}  "
                f"week {fmt_pct(snapshot.get('weekly_remaining_percent'))}  "
                f"reset {fmt_reset(snapshot.get('current_resets_at'))} / "
                f"{fmt_reset(snapshot.get('weekly_resets_at'), True)}"
                f"{suffix}"
            )
PY
}

saved_account_exists() {
  local name="$1"
  [[ -f "$(auth_path_for "$name")" ]]
}

auth_files_match() {
  local left="$1"
  local right="$2"
  [[ -f "$left" && -f "$right" ]] || return 1

  local left_account_id right_account_id
  left_account_id="$(account_id_for_auth_path "$left")"
  right_account_id="$(account_id_for_auth_path "$right")"
  if [[ -n "${left_account_id:-}" && -n "${right_account_id:-}" ]]; then
    [[ "$left_account_id" == "$right_account_id" ]]
    return
  fi

  # This helper is used only for explicit/manual backup operations. Legacy auth
  # files without account IDs may be overwritten only when content is identical.
  cmp -s "$left" "$right"
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
  if [[ -f "$dest" ]] && ! auth_files_match "$AUTH_FILE" "$dest"; then
    die "A different saved account named '${name}' already exists. Choose a new name or rename/remove the existing account first."
  fi

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

  die "No saved account named '${name}'. Use '${COMMAND_NAME} list' to see options."
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

ensure_active_auth_saved_or_prompt() {
  local reserved_name="${1:-}"
  [[ -f "$AUTH_FILE" ]] || return 0

  load_state
  local detected
  detected="$(current_account_name_from_auth)"
  if [[ -n "${detected:-}" ]]; then
    CURRENT="$detected"
    save_state "$CURRENT" "${PREVIOUS:-}"
    return 0
  fi

  local named
  named="$(prompt_account_name)"
  if [[ -n "${reserved_name:-}" && "$named" == "$reserved_name" ]]; then
    die "'${reserved_name}' is reserved for the new login. Save the current account under a different name first."
  fi
  backup_current_to "$named"
  PREVIOUS=""
  CURRENT="$named"
  save_state "$CURRENT" "$PREVIOUS"
}

# ------------- commands -------------
cmd_list() {
  ensure_dirs
  load_state
  load_config
  local active_current
  active_current="$(resolved_current_account_name)"

  shopt -s nullglob
  local names=()
  local f base
  for f in "$DATA_DIR"/*.auth.json; do
    base="$(basename "$f")"
    names+=("${base%.auth.json}")
  done

  # Compute max name length across all rows (including "claude" if shown)
  local max_name_len=0
  for base in "${names[@]}"; do
    [[ ${#base} -gt $max_name_len ]] && max_name_len=${#base}
  done
  if [[ "$DISPLAY_SHOW_CLAUDE" == "1" && 6 -gt $max_name_len ]]; then
    max_name_len=6
  fi

  local line_width=$((46 + max_name_len))

  # Codex section
  if [[ "$DISPLAY_SHOW_CLAUDE" == "1" ]]; then
    print_divider "codex" "$line_width"
  fi

  if [[ ${#names[@]} -eq 0 ]]; then
    echo "(no accounts saved yet)"
  else
    for base in "${names[@]}"; do
      display_usage_for_saved_account "$base" "$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS" "$active_current" "$max_name_len" || true
    done
  fi

  # Claude section
  if [[ "$DISPLAY_SHOW_CLAUDE" == "1" ]]; then
    print_divider "claude" "$line_width"
    local claude_state
    claude_state="$(collect_claude_widget_line "$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS")"
    format_usage_state_json "$claude_state" "$max_name_len"
  fi
}

cmd_current() {
  load_state
  local active_current
  active_current="$(resolved_current_account_name)"
  if [[ -n "${active_current:-}" ]]; then
    display_usage_for_saved_account "$active_current" "$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS" "$active_current" "${#active_current}" || true
  else
    echo "  (unknown — no state recorded yet)"
  fi
}

cmd_save() {
  # Save only the currently logged-in account auth under a name.
  if is_help_flag "${1:-}"; then
    cat <<EOF
Usage: ${COMMAND_NAME} save [NAME]

Save the current ~/.codex/auth.json into ${DATA_DIR}/NAME.auth.json.
If NAME is omitted, you will be prompted.
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
Usage: ${COMMAND_NAME} add NAME

Backs up the current auth if needed, removes ~/.codex/auth.json,
then lets you run '${CODENAME} login' for the new account.
EOF
    return
  fi

  ensure_dirs

  local newname="${1:-}"
  [[ -z "$newname" ]] && die "Usage: ${COMMAND_NAME} add NAME"
  [[ ! -f "$(auth_path_for "$newname")" ]] || die "A saved account named '${newname}' already exists. Use a different name or rename/remove the existing account first."

  ensure_active_auth_saved_or_prompt "$newname"

  if [[ -f "$AUTH_FILE" ]]; then
    note "Removing current auth.json to prepare login for '${newname}'..."
    rm -f "$AUTH_FILE"
  fi

  ok "Ready. Now run: ${CODENAME} login  (to authenticate '${newname}')"
  echo "After login completes, run: ${COMMAND_NAME} save ${newname}   (to store the new account)"
}

cmd_switch() {
  # Switch to a saved account by swapping only auth.json.
  if is_help_flag "${1:-}"; then
    cat <<EOF
Usage: ${COMMAND_NAME} switch NAME

Backs up the current ~/.codex/auth.json first, then replaces it with
the saved auth for <account-name>.
EOF
    return
  fi

  local target="${1:-}"
  [[ -z "$target" ]] && die "Usage: ${COMMAND_NAME} switch NAME"

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
  display_usage_for_saved_account "$CURRENT" "$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS" "$CURRENT" "${#CURRENT}" || true
}

cmd_refresh() {
  if is_help_flag "${1:-}"; then
    cat <<EOF
Usage: ${COMMAND_NAME} refresh

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

  if display_usage_for_saved_account "$active_current" "$USAGE_MANUAL_REFRESH_TIMEOUT_SECONDS" "$active_current" "${#active_current}"; then
    return
  fi

  return 1
}

cmd_widget() {
  if is_help_flag "${1:-}"; then
    cat <<EOF
Usage: ${COMMAND_NAME} widget [--format swiftbar|json|text] [--timeout SECONDS]

Render a unified Codex + Claude usage snapshot for menu-bar widgets.
The swiftbar format is intended for SwiftBar/xbar-style plugins.
Use --cached for instant cache-only output, or --refresh-cache to warm caches.
EOF
    return
  fi

  ensure_dirs

  local output_format="swiftbar"
  local timeout_seconds="$USAGE_AUTO_REFRESH_TIMEOUT_SECONDS"
  local mode="live"
  local refresh_cache_only="0"

  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --format)
        shift
        [[ $# -gt 0 ]] || die "--format requires swiftbar, json, or text"
        output_format="$1"
        ;;
      --timeout)
        shift
        [[ $# -gt 0 ]] || die "--timeout requires a number of seconds"
        timeout_seconds="$1"
        ;;
      --cached)
        mode="cached"
        ;;
      --refresh-cache)
        refresh_cache_only="1"
        ;;
      --json)
        output_format="json"
        ;;
      --text)
        output_format="text"
        ;;
      --swiftbar)
        output_format="swiftbar"
        ;;
      *)
        die "Unknown widget option: $1"
        ;;
    esac
    shift
  done

  case "$output_format" in
    swiftbar|json|text) ;;
    *) die "--format must be swiftbar, json, or text" ;;
  esac

  [[ "$timeout_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--timeout must be numeric"

  local widget_json
  widget_json="$(build_widget_snapshot_json "$timeout_seconds" "$mode")"

  if [[ "$refresh_cache_only" == "1" ]]; then
    return 0
  fi

  case "$output_format" in
    swiftbar) format_widget_swiftbar_json "$widget_json" ;;
    json) printf '%s\n' "$widget_json" ;;
    text) format_widget_text_json "$widget_json" ;;
  esac
}

cmd_rename() {
  if is_help_flag "${1:-}"; then
    cat <<EOF
Usage: ${COMMAND_NAME} rename OLD_NAME NEW_NAME

Rename a saved account from <old-name> to <new-name>.
Also updates current/previous state if needed.
EOF
    return
  fi

  ensure_dirs

  local old_name="${1:-}"
  local new_name="${2:-}"
  [[ -z "$old_name" || -z "$new_name" ]] && die "Usage: ${COMMAND_NAME} rename OLD_NAME NEW_NAME"
  [[ "$old_name" == "$new_name" ]] && die "Old name and new name are the same."

  local old_path new_path
  old_path="$(auth_path_for "$old_name")"
  new_path="$(auth_path_for "$new_name")"

  [[ -f "$old_path" ]] || die "No saved account named '${old_name}'. Use '${COMMAND_NAME} list' to see options."
  [[ ! -f "$new_path" ]] || die "A saved account named '${new_name}' already exists."

  mv "$old_path" "$new_path"

  local old_cache new_cache
  old_cache="$(usage_cache_path_for "$old_name")"
  new_cache="$(usage_cache_path_for "$new_name")"
  if [[ -f "$old_cache" ]]; then
    mkdir -p "$(dirname -- "$new_cache")"
    mv -f "$old_cache" "$new_cache"
  fi

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

cmd_remove() {
  if is_help_flag "${1:-}"; then
    cat <<EOF
Usage: ${COMMAND_NAME} remove NAME

Remove a saved account from ${DATA_DIR}.
The currently active account cannot be removed until you switch away from it.
EOF
    return
  fi

  ensure_dirs
  load_state

  local name="${1:-}"
  [[ -z "$name" ]] && die "Usage: ${COMMAND_NAME} remove NAME"

  local active_current
  active_current="$(resolved_current_account_name)"
  if [[ -n "${active_current:-}" && "$name" == "$active_current" ]]; then
    die "Cannot remove the active account '${name}'. Switch to another account first."
  fi

  local target_path
  target_path="$(auth_path_for "$name")"
  [[ -f "$target_path" ]] || die "No saved account named '${name}'. Use '${COMMAND_NAME} list' to see options."

  rm -f "$target_path" "$(usage_cache_path_for "$name")"

  if [[ "${CURRENT:-}" == "$name" ]]; then
    CURRENT=""
  fi
  if [[ "${PREVIOUS:-}" == "$name" ]]; then
    PREVIOUS=""
  fi
  save_state "${CURRENT:-}" "${PREVIOUS:-}"

  ok "Removed '${name}'."
}

cmd_configure() {
  ensure_dirs
  load_config

  if [[ $# -eq 0 ]] || is_help_flag "${1:-}"; then
    cat <<EOF
Usage: ${COMMAND_NAME} configure
       ${COMMAND_NAME} configure reset <human|normal>
       ${COMMAND_NAME} configure show <claude> <on|off>

Current config
  reset style:  ${DISPLAY_RESET_STYLE}
  show claude:  ${DISPLAY_SHOW_CLAUDE}

Notes
  - reset 'human' shows relative values like 4h59m / 2d1h.
  - reset 'normal' shows absolute timestamps like Apr 25, 2026 20:27.
  - show claude: displays Claude Code usage above the codex accounts (macOS only).
EOF
    return
  fi

  local subcmd="${1:-}"
  case "$subcmd" in
    reset)
      local style="${2:-}"
      case "$style" in
        human|normal)
          DISPLAY_RESET_STYLE="$style"
          save_config
          ok "Reset style set to '${style}'."
          ;;
        *)
          die "Usage: ${COMMAND_NAME} configure reset <human|normal>"
          ;;
      esac
      ;;
    show)
      local field="${2:-}"
      local raw_value="${3:-}"
      local value
      value="$(normalize_toggle "$raw_value")" || die "Usage: ${COMMAND_NAME} configure show <claude> <on|off>"
      case "$field" in
        claude) DISPLAY_SHOW_CLAUDE="$value" ;;
        *) die "Usage: ${COMMAND_NAME} configure show <claude> <on|off>" ;;
      esac
      save_config
      ok "Set '${field}' to '${raw_value}'."
      ;;
    *)
      die "Unknown configure command. See '${COMMAND_NAME} configure --help'."
      ;;
  esac
}

cmd_help() {
  cat <<EOF
Codex Account Switcher

Swap between saved Codex accounts and show live usage for each one.

Usage: ${COMMAND_NAME} [COMMAND]
       ${COMMAND_NAME} ACCOUNT_NAME

Commands:
  status       Show all accounts with live usage (alias: list)
  current      Show the active account with live usage
  widget       Render Codex + Claude usage for a menu-bar widget
  configure    Configure display style and optional fields
  save [NAME]  Save the current login under a name
  add <NAME>   Prepare to log into a new account
  switch <NAME>
               Switch to a saved account
  rename <OLD_NAME> <NEW_NAME>
               Rename a saved account
  remove <NAME>
               Remove a saved account
  help         Show this help

Arguments:
  <ACCOUNT_NAME>  Shortcut for 'switch <ACCOUNT_NAME>' when the account exists

Display:
  Default output is compact: window, week, and next reset.
  Free-tier accounts show as 'free plan' by default.

Storage:
  Active auth: ~/.codex/auth.json
  Saved auths: ${DATA_DIR}/<name>.auth.json

Notes:
  Usage is fetched live whenever it is shown.
  status reads each saved account from its saved auth file.
  current and account switching read the active account from ~/.codex/auth.json.
EOF
}

# ------------- main -------------
main() {
  ensure_dirs

  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    status|list) cmd_list "$@";;
    current) cmd_current "$@";;
    widget) cmd_widget "$@";;
    configure|config) cmd_configure "$@";;
    save)    cmd_save "$@";;
    add)     cmd_add "$@";;
    switch)  cmd_switch "$@";;
    rename)  cmd_rename "$@";;
    remove|rm|delete) cmd_remove "$@";;
    help|--help|-h) cmd_help;;
    *)
      if saved_account_exists "$cmd"; then
        cmd_switch "$cmd" "$@"
      else
        die "Unknown command or saved account: $cmd. See '${COMMAND_NAME} help'."
      fi
      ;;
  esac
}

main "$@"
