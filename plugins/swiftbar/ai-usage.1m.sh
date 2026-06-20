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

refresh_cache_in_background() {
  local lock_dir="${TMPDIR:-/tmp}/codex-account-switch-widget-refresh.lock"

  if ! mkdir "$lock_dir" 2>/dev/null; then
    return 0
  fi

  trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
  "$COMMAND" widget --refresh-cache >/dev/null 2>&1 || true
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
