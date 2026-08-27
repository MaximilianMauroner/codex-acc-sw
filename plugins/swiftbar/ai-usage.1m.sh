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
  local lock_dir="$1"
  rm -f "$lock_dir/pid"
  rmdir "$lock_dir" 2>/dev/null || true
}

acquire_refresh_lock() {
  local lock_dir="$1"
  local owner_pid stale_dir current_pid
  current_pid="$(/bin/sh -c 'printf "%s\n" "$PPID"')"

  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$current_pid" > "$lock_dir/pid"
    return 0
  fi

  owner_pid="$(<"$lock_dir/pid" 2>/dev/null || true)"
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
    return 1
  fi

  stale_dir="${lock_dir}.stale.${current_pid}"
  if ! mv "$lock_dir" "$stale_dir" 2>/dev/null; then
    return 1
  fi
  rm -f "$stale_dir/pid"
  rmdir "$stale_dir" 2>/dev/null || true

  mkdir "$lock_dir" 2>/dev/null || return 1
  printf '%s\n' "$current_pid" > "$lock_dir/pid"
}

refresh_cache_in_background() {
  local lock_dir="${RUNTIME_DIR}/refresh.lock"
  local output_tmp

  if ! acquire_refresh_lock "$lock_dir"; then
    return 0
  fi

  trap "release_refresh_lock $(printf '%q' "$lock_dir")" EXIT
  output_tmp="$(mktemp "${RUNTIME_DIR}/widget.XXXXXX")"
  if SWIFTBAR_PLUGIN_REFRESH_REASON="${SWIFTBAR_PLUGIN_REFRESH_REASON:-scheduled}" \
    "$COMMAND" widget --format swiftbar >"$output_tmp" 2>/dev/null; then
    chmod 600 "$output_tmp"
    mv -f "$output_tmp" "$LIVE_OUTPUT"
  else
    rm -f "$output_tmp"
  fi
}

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
