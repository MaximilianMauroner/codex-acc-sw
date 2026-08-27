#!/usr/bin/env bash
# <xbar.title>AI Usage</xbar.title>
# <xbar.version>v0.1.0</xbar.version>
# <xbar.author>codex-account-switch</xbar.author>
# <xbar.desc>Shows Codex and Claude usage in the macOS menu bar.</xbar.desc>
# <xbar.dependencies>bash,python3,codex-account-switch</xbar.dependencies>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>

set -euo pipefail

resolve_command() {
  if [[ -n "${CODEX_ACCOUNT_SWITCH_BIN:-}" && -x "${CODEX_ACCOUNT_SWITCH_BIN:-}" ]]; then
    echo "$CODEX_ACCOUNT_SWITCH_BIN"
    return 0
  fi

  if command -v codex-account-switch >/dev/null 2>&1; then
    command -v codex-account-switch
    return 0
  fi

  local candidate
  for candidate in \
    "${HOME}/.local/bin/codex-account-switch" \
    "/usr/local/bin/codex-account-switch" \
    "/opt/homebrew/bin/codex-account-switch"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

COMMAND="$(resolve_command || true)"
RUNTIME_DIR="${HOME}/.codex/switch/swiftbar-runtime"
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
LIVE_OUTPUT="${RUNTIME_DIR}/live.swiftbar"

release_refresh_lock() {
  local lock_file="$1"
  local owner_file="$2"
  if [[ -f "$lock_file" && -f "$owner_file" && "$lock_file" -ef "$owner_file" ]]; then
    rm -f "$lock_file"
  fi
  rm -f "$owner_file"
}

acquire_refresh_reclaim_guard() {
  local lock_file="$1"
  local guard_dir="${lock_file}.reclaim"
  local stale_guard
  if mkdir "$guard_dir" 2>/dev/null; then
    return 0
  fi
  if [[ -z "$(find "$guard_dir" -mmin +1 -print -quit 2>/dev/null)" ]]; then
    return 1
  fi
  stale_guard="${guard_dir}.stale.$(/bin/sh -c 'printf "%s" "$PPID"').${RANDOM}"
  mv "$guard_dir" "$stale_guard" 2>/dev/null || return 1
  rmdir "$stale_guard" 2>/dev/null || return 1
  mkdir "$guard_dir" 2>/dev/null
}

release_refresh_reclaim_guard() {
  rmdir "${1}.reclaim" 2>/dev/null || true
}

acquire_refresh_lock() {
  local lock_file="$1"
  local owner_pid owner_name stale_file current_pid
  current_pid="$(/bin/sh -c 'printf "%s\n" "$PPID"')"
  REFRESH_LOCK_OWNER_FILE="$(mktemp "${RUNTIME_DIR}/.refresh-owner.XXXXXX")"
  owner_name="$(basename -- "$REFRESH_LOCK_OWNER_FILE")"
  printf '%s\n%s\n' "$current_pid" "$owner_name" > "$REFRESH_LOCK_OWNER_FILE"
  chmod 600 "$REFRESH_LOCK_OWNER_FILE"

  if [[ -d "$lock_file" ]]; then
    owner_pid="$(sed -n '1p' "$lock_file/pid" 2>/dev/null || true)"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
      rm -f "$REFRESH_LOCK_OWNER_FILE"
      REFRESH_LOCK_OWNER_FILE=""
      return 1
    fi
    if ! acquire_refresh_reclaim_guard "$lock_file"; then
      rm -f "$REFRESH_LOCK_OWNER_FILE"
      REFRESH_LOCK_OWNER_FILE=""
      return 1
    fi
    if [[ ! -d "$lock_file" ]]; then
      release_refresh_reclaim_guard "$lock_file"
      rm -f "$REFRESH_LOCK_OWNER_FILE"
      REFRESH_LOCK_OWNER_FILE=""
      acquire_refresh_lock "$lock_file"
      return
    fi
    owner_pid="$(sed -n '1p' "$lock_file/pid" 2>/dev/null || true)"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
      release_refresh_reclaim_guard "$lock_file"
      rm -f "$REFRESH_LOCK_OWNER_FILE"
      REFRESH_LOCK_OWNER_FILE=""
      return 1
    fi
    stale_file="${lock_file}.stale.${current_pid}.${RANDOM}"
    if ! mv "$lock_file" "$stale_file" 2>/dev/null; then
      release_refresh_reclaim_guard "$lock_file"
      rm -f "$REFRESH_LOCK_OWNER_FILE"
      REFRESH_LOCK_OWNER_FILE=""
      return 1
    fi
    rm -f "$stale_file/pid"
    if ! rmdir "$stale_file" 2>/dev/null; then
      release_refresh_reclaim_guard "$lock_file"
      rm -f "$REFRESH_LOCK_OWNER_FILE"
      REFRESH_LOCK_OWNER_FILE=""
      return 1
    fi
    if ln "$REFRESH_LOCK_OWNER_FILE" "$lock_file" 2>/dev/null; then
      release_refresh_reclaim_guard "$lock_file"
      return 0
    fi
    release_refresh_reclaim_guard "$lock_file"
    rm -f "$REFRESH_LOCK_OWNER_FILE"
    REFRESH_LOCK_OWNER_FILE=""
    return 1
  fi

  if ln "$REFRESH_LOCK_OWNER_FILE" "$lock_file" 2>/dev/null; then
    return 0
  fi

  owner_pid="$(sed -n '1p' "$lock_file" 2>/dev/null || true)"
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
    rm -f "$REFRESH_LOCK_OWNER_FILE"
    REFRESH_LOCK_OWNER_FILE=""
    return 1
  fi

  if ! acquire_refresh_reclaim_guard "$lock_file"; then
    rm -f "$REFRESH_LOCK_OWNER_FILE"
    REFRESH_LOCK_OWNER_FILE=""
    return 1
  fi
  if ln "$REFRESH_LOCK_OWNER_FILE" "$lock_file" 2>/dev/null; then
    release_refresh_reclaim_guard "$lock_file"
    return 0
  fi
  owner_pid="$(sed -n '1p' "$lock_file" 2>/dev/null || true)"
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
    release_refresh_reclaim_guard "$lock_file"
    rm -f "$REFRESH_LOCK_OWNER_FILE"
    REFRESH_LOCK_OWNER_FILE=""
    return 1
  fi

  stale_file="${lock_file}.stale.${current_pid}.${RANDOM}"
  if ! mv "$lock_file" "$stale_file" 2>/dev/null; then
    release_refresh_reclaim_guard "$lock_file"
    rm -f "$REFRESH_LOCK_OWNER_FILE"
    REFRESH_LOCK_OWNER_FILE=""
    return 1
  fi
  owner_name="$(sed -n '2p' "$stale_file" 2>/dev/null || true)"
  rm -f "$stale_file"
  if [[ "$owner_name" == .refresh-owner.* ]]; then
    rm -f "${RUNTIME_DIR}/${owner_name}"
  fi

  if ln "$REFRESH_LOCK_OWNER_FILE" "$lock_file" 2>/dev/null; then
    release_refresh_reclaim_guard "$lock_file"
    return 0
  fi
  release_refresh_reclaim_guard "$lock_file"
  rm -f "$REFRESH_LOCK_OWNER_FILE"
  REFRESH_LOCK_OWNER_FILE=""
  return 1
}

refresh_cache_in_background() {
  local lock_dir="${RUNTIME_DIR}/refresh.lock"
  local output_tmp

  if ! acquire_refresh_lock "$lock_dir"; then
    return 0
  fi

  trap "release_refresh_lock $(printf '%q' "$lock_dir") $(printf '%q' "$REFRESH_LOCK_OWNER_FILE")" EXIT
  output_tmp="$(mktemp "${RUNTIME_DIR}/widget.XXXXXX")"
  if SWIFTBAR_PLUGIN_REFRESH_REASON="${SWIFTBAR_PLUGIN_REFRESH_REASON:-scheduled}" \
    "$COMMAND" widget --format swiftbar >"$output_tmp" 2>/dev/null; then
    chmod 600 "$output_tmp"
    mv -f "$output_tmp" "$LIVE_OUTPUT"
  else
    rm -f "$output_tmp"
  fi
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

if [[ -z "${COMMAND:-}" ]]; then
  echo "AI setup | color=orange"
  echo "---"
  echo "codex-account-switch was not found in PATH | color=red"
  echo "Install it first, or set CODEX_ACCOUNT_SWITCH_BIN in this plugin."
  echo "Refresh | refresh=true"
  exit 0
fi

refresh_cache_in_background >/dev/null 2>&1 &

if [[ -s "$LIVE_OUTPUT" && -n "$(find "$LIVE_OUTPUT" -mmin -3 -print -quit 2>/dev/null)" ]]; then
  cat "$LIVE_OUTPUT"
  exit 0
fi

if ! output="$("$COMMAND" widget --format swiftbar --cached 2>&1)"; then
  echo "AI error | color=red"
  echo "---"
  echo "Widget command failed | color=red"
  printf '%s\n' "$output"
  echo "---"
  echo "Refresh | refresh=true"
  exit 0
fi

printf '%s\n' "$output"
