#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMMAND="$ROOT/codex-accounts.sh"
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for command in save add switch rename remove; do
  output="$(HOME="$TEST_HOME" bash "$COMMAND" "$command" --help 2>&1)" || \
    fail "$command --help exited unsuccessfully"
  [[ "$output" == Usage:* ]] || fail "$command --help did not print usage"
done

if HOME="$TEST_HOME" bash "$COMMAND" save .hidden >"$TEST_HOME/hidden.out" 2>&1; then
  fail "a leading-dot account name was accepted"
fi
grep -q "cannot start with '.'" "$TEST_HOME/hidden.out" || \
  fail "leading-dot rejection did not explain the restriction"

if HOME="$TEST_HOME" bash "$COMMAND" refresh >"$TEST_HOME/refresh.out" 2>&1; then
  fail "refresh unexpectedly succeeded without an active account"
fi
grep -q "No active account found" "$TEST_HOME/refresh.out" || \
  fail "refresh did not reach cmd_refresh"

write_claude_metadata() {
  local account_uuid="$1"
  local display_name="$2"
  cat >"$TEST_HOME/.claude.json" <<EOF
{"oauthAccount":{"accountUuid":"$account_uuid","organizationUuid":"org-1","displayName":"$display_name","hasExtraUsageEnabled":false}}
EOF
}

claude_identity() {
  HOME="$TEST_HOME" bash "$COMMAND" widget --cached --format json | python3 -c '
import json, sys
items = json.load(sys.stdin)["accounts"]
print(next(item["account_identity"] for item in items if item["provider"] == "claude"))
'
}

write_claude_metadata account-1 "First name"
identity_one="$(claude_identity)"
write_claude_metadata account-1 "Changed name"
identity_two="$(claude_identity)"
write_claude_metadata account-2 "Changed owner"
identity_three="$(claude_identity)"

[[ "$identity_one" =~ ^[0-9a-f]{64}$ ]] || fail "Claude identity is not a SHA-256 digest"
[[ "$identity_one" == "$identity_two" ]] || fail "mutable Claude metadata changed the identity"
[[ "$identity_one" != "$identity_three" ]] || fail "a different Claude owner reused the identity"

FAKE_BIN="$TEST_HOME/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
touch "$TEST_HOME/security-started"
sleep 1
exit 1
EOF
chmod 755 "$FAKE_BIN/security"

HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" bash "$COMMAND" widget --format json >"$TEST_HOME/live.out" 2>&1 &
widget_pid=$!
for _ in {1..100}; do
  [[ -f "$TEST_HOME/security-started" ]] && break
  sleep 0.01
done
[[ -f "$TEST_HOME/security-started" ]] || fail "fake Keychain reader did not start"
[[ ! -d "$TEST_HOME/.codex/switch/auth-store.lock" ]] || \
  fail "live widget held the auth-store lock during Keychain work"
wait "$widget_pid"

echo "shell regressions passed"
