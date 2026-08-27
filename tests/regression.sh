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

legacy_claim_token="$(python3 - <<'PY'
import base64
import json

def part(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

print(f"{part({'alg': 'none'})}.{part({'sub': 'legacy-owner-1'})}.x")
PY
)"
cat >"$TEST_HOME/.codex/accounts/legacy.auth.json" <<EOF
{"tokens":{"id_token":"$legacy_claim_token"}}
EOF
legacy_identity="$(HOME="$TEST_HOME" bash "$COMMAND" widget --cached --format json | python3 -c '
import json, sys
items = json.load(sys.stdin)["accounts"]
print(next(item["account_identity"] for item in items if item["name"] == "legacy"))
')"
[[ "$legacy_identity" =~ ^[0-9a-f]{64}$ ]] || fail "stable legacy token claim did not produce a hashed identity"
[[ "$legacy_identity" != *legacy-owner-1* ]] || fail "legacy owner claim leaked into widget output"

read -r subject_only_token explicit_account_token <<EOF
$(python3 - <<'PY'
import base64
import json

def part(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

header = part({"alg": "none"})
print(
    f"{header}.{part({'sub': 'legacy-owner-1'})}.x "
    f"{header}.{part({'account_id': 'explicit-owner-1'})}.x"
)
PY
)
EOF
cat >"$TEST_HOME/.codex/accounts/legacy.auth.json" <<EOF
{"tokens":{"id_token":"$subject_only_token","access_token":"$explicit_account_token"}}
EOF
explicit_claim_identity="$(HOME="$TEST_HOME" bash "$COMMAND" widget --cached --format json | python3 -c '
import json, sys
items = json.load(sys.stdin)["accounts"]
print(next(item["account_identity"] for item in items if item["name"] == "legacy"))
')"
expected_explicit_identity="$(printf explicit-owner-1 | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
[[ "$explicit_claim_identity" == "$expected_explicit_identity" ]] || \
  fail "explicit account claim did not take precedence over a subject claim from another token"

cp "$TEST_HOME/.codex/accounts/legacy.auth.json" "$TEST_HOME/.codex/auth.json"
cache_key="$(printf legacy | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
cat >"$TEST_HOME/.codex/switch/usage-cache/codex/$cache_key.json" <<EOF
{"last_seen_at":"2026-08-27T00:00:00Z","current_remaining_percent":42,"current_window_minutes":300}
EOF
if HOME="$TEST_HOME" bash "$COMMAND" refresh >"$TEST_HOME/stale-refresh.out" 2>&1; then
  fail "manual refresh reported success after a live failure"
fi
grep -q '42%' "$TEST_HOME/stale-refresh.out" || fail "manual refresh did not display stale cached usage"

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

write_claude_metadata "" "Organization only"
organization_only_identity="$(claude_identity)"
[[ "$organization_only_identity" == "None" ]] || fail "organization-only Claude evidence produced a history identity"

write_claude_metadata account-1 "First name"
identity_one="$(claude_identity)"
write_claude_metadata account-1 "Changed name"
identity_two="$(claude_identity)"
write_claude_metadata account-2 "Changed owner"
identity_three="$(claude_identity)"

[[ "$identity_one" =~ ^[0-9a-f]{64}$ ]] || fail "Claude identity is not a SHA-256 digest"
[[ "$identity_one" == "$identity_two" ]] || fail "mutable Claude metadata changed the identity"
[[ "$identity_one" != "$identity_three" ]] || fail "a different Claude owner reused the identity"

claude_cache="$TEST_HOME/.codex/switch/usage-cache/claude/usage.json"
metadata_alias="$(printf 'Claude Code-credentials:account_id:%s' account-2 | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
organization_alias="$(printf 'Claude Code-credentials:organization_id:%s' org-1 | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
stored_identity="$(printf 'stored-live-owner' | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
cat >"$claude_cache" <<EOF
{"account_identity":"$stored_identity","account_alias_hashes":["$metadata_alias"],"organization_alias_hashes":["$organization_alias"],"snapshot":{"last_seen_at":"2026-08-27T00:00:00Z","current_remaining_percent":50}}
EOF
cached_identity="$(claude_identity)"
[[ "$cached_identity" == "$stored_identity" ]] || fail "cached Claude row did not retain its authoritative live identity"

write_claude_metadata account-3 "Another owner"
claude_identity >/dev/null
[[ ! -f "$claude_cache" ]] || fail "Claude cache survived an owner mismatch"

write_claude_metadata "" "Organization only"
cat >"$claude_cache" <<EOF
{"account_identity":"$stored_identity","account_alias_hashes":[],"organization_alias_hashes":["$organization_alias"],"snapshot":{"last_seen_at":"2026-08-27T00:00:00Z","current_remaining_percent":50}}
EOF
claude_identity >/dev/null
[[ ! -f "$claude_cache" ]] || fail "organization-only Claude cache envelope survived validation"

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
deadline=$((SECONDS + 5))
while (( SECONDS < deadline )); do
  [[ -f "$TEST_HOME/security-started" ]] && break
  if ! kill -0 "$widget_pid" 2>/dev/null; then
    wait "$widget_pid" || true
    fail "live widget exited before the Keychain fixture started"
  fi
  sleep 0.01
done
[[ -f "$TEST_HOME/security-started" ]] || fail "fake Keychain reader did not start"
[[ ! -d "$TEST_HOME/.codex/switch/auth-store.lock" ]] || \
  fail "live widget held the auth-store lock during Keychain work"
wait "$widget_pid"

TEMP_ROOT="$TEST_HOME/widget-tmp"
mkdir -p "$TEMP_ROOT"
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
touch "$TEST_HOME/security-started-term"
sleep 1
exit 1
EOF
chmod 755 "$FAKE_BIN/security"
HOME="$TEST_HOME" TMPDIR="$TEMP_ROOT" PATH="$FAKE_BIN:$PATH" bash "$COMMAND" widget --format json >"$TEST_HOME/term.out" 2>&1 &
widget_pid=$!
deadline=$((SECONDS + 5))
while (( SECONDS < deadline )); do
  [[ -f "$TEST_HOME/security-started-term" ]] && break
  if ! kill -0 "$widget_pid" 2>/dev/null; then
    wait "$widget_pid" || true
    fail "cleanup fixture exited before Keychain work"
  fi
  sleep 0.01
done
[[ -f "$TEST_HOME/security-started-term" ]] || fail "cleanup fixture did not reach Keychain work"
kill -TERM "$widget_pid"
wait "$widget_pid" || true
if find "$TEMP_ROOT" -mindepth 1 -print -quit | grep -q .; then
  fail "widget temporary files survived TERM"
fi

HOME="$TEST_HOME" bash "$COMMAND" configure show claude off >/dev/null
rm -f "$TEST_HOME/.codex/auth.json"
cat >"$TEST_HOME/.codex/accounts/inactive.auth.json" <<EOF
{"tokens":{"account_id":"inactive-account"}}
EOF
swiftbar_output="$(HOME="$TEST_HOME" bash "$COMMAND" widget --cached --format swiftbar)"
swiftbar_title="${swiftbar_output%%$'\n'*}"
[[ "$swiftbar_title" == "AI usage"* ]] || fail "SwiftBar title fell back to an inactive Codex account"
if grep -Eq '^Claude( |$)' <<<"$swiftbar_output"; then
  fail "SwiftBar rendered a Claude section without a Claude row"
fi

echo "shell regressions passed"
