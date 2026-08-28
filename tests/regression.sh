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
read -r upgraded_identity upgraded_alias_count <<EOF
$(HOME="$TEST_HOME" bash "$COMMAND" widget --cached --format json | python3 -c '
import json, sys
items = json.load(sys.stdin)["accounts"]
item = next(item for item in items if item["name"] == "legacy")
print(item["account_identity"], len(item["account_identity_aliases"]))
')
EOF
expected_explicit_identity="$(printf explicit-owner-1 | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
[[ "$upgraded_identity" == "$expected_explicit_identity" ]] || \
  fail "a stronger legacy account claim did not become the canonical identity"
[[ "$upgraded_alias_count" == "0" ]] || \
  fail "an unproven stronger claim exposed a subject migration alias"

read -r account_alias_token url_alias_token <<EOF
$(python3 - <<'PY'
import base64
import json

def part(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

header = part({"alg": "none"})
print(
    f"{header}.{part({'chatgpt_account_id': 'explicit-owner-1'})}.x "
    f"{header}.{part({'https://api.openai.com/auth/chatgpt_account_id': 'explicit-owner-1'})}.x"
)
PY
)
EOF
cat >"$TEST_HOME/.codex/accounts/explicit.auth.json" <<EOF
{"tokens":{"id_token":"$account_alias_token","access_token":"$url_alias_token"}}
EOF
normalized_alias_identity="$(HOME="$TEST_HOME" bash "$COMMAND" widget --cached --format json | python3 -c '
import json, sys
items = json.load(sys.stdin)["accounts"]
print(next(item["account_identity"] for item in items if item["name"] == "explicit"))
')"
[[ "$normalized_alias_identity" == "$expected_explicit_identity" ]] || \
  fail "equivalent explicit account claim aliases produced different ownership evidence"

cat >"$TEST_HOME/.codex/accounts/established.auth.json" <<EOF
{"tokens":{"account_id":"established-owner-1","id_token":"$subject_only_token"}}
EOF
read -r established_identity established_alias_count <<EOF
$(HOME="$TEST_HOME" bash "$COMMAND" widget --cached --format json | python3 -c '
import json, sys
items = json.load(sys.stdin)["accounts"]
item = next(item for item in items if item["name"] == "established")
print(item["account_identity"], len(item["account_identity_aliases"]))
')
EOF
expected_established_identity="$(printf established-owner-1 | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
[[ "$established_identity" == "$expected_established_identity" ]] || \
  fail "JWT subject replaced an established top-level account identity"
[[ "$established_alias_count" == "0" ]] || fail "established account exposed an unsafe subject migration alias"

read -r shared_subject_account_a shared_subject_account_b <<EOF
$(python3 - <<'PY'
import base64
import json

def part(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

header = part({"alg": "none"})
print(
    f"{header}.{part({'sub': 'shared-subject', 'account_id': 'shared-account-a'})}.x "
    f"{header}.{part({'sub': 'shared-subject', 'account_id': 'shared-account-b'})}.x"
)
PY
)
EOF
cat >"$TEST_HOME/.codex/accounts/shared-a.auth.json" <<EOF
{"tokens":{"id_token":"$shared_subject_account_a"}}
EOF
cat >"$TEST_HOME/.codex/accounts/shared-b.auth.json" <<EOF
{"tokens":{"id_token":"$shared_subject_account_b"}}
EOF
read -r shared_identity_a shared_identity_b shared_alias_count <<EOF
$(HOME="$TEST_HOME" bash "$COMMAND" widget --cached --format json | python3 -c '
import json, sys
items = {item["name"]: item for item in json.load(sys.stdin)["accounts"]}
a, b = items["shared-a"], items["shared-b"]
print(a["account_identity"], b["account_identity"], len(a["account_identity_aliases"]) + len(b["account_identity_aliases"]))
')
EOF
[[ "$shared_identity_a" != "$shared_identity_b" ]] || fail "different accounts sharing a subject reused one canonical identity"
[[ "$shared_alias_count" == "0" ]] || fail "shared-subject accounts exposed unproven migration aliases"

assert_malformed_auth_is_identityless() {
  local auth_json="$1"
  printf '%s\n' "$auth_json" >"$TEST_HOME/.codex/accounts/malformed.auth.json"
  local identity
  identity="$(HOME="$TEST_HOME" bash "$COMMAND" widget --cached --format json | python3 -c '
import json, sys
items = json.load(sys.stdin)["accounts"]
print(next(item["account_identity"] for item in items if item["name"] == "malformed"))
')" || fail "malformed auth aborted widget collection"
  [[ "$identity" == "None" ]] || fail "malformed auth produced an ownership identity"
}

assert_malformed_auth_is_identityless '[]'
assert_malformed_auth_is_identityless '{"tokens":[]}'
assert_malformed_auth_is_identityless '{"tokens":{"id_token":"e30.W10.x"}}'
rm -f "$TEST_HOME/.codex/accounts/malformed.auth.json"

for malformed_active_auth in '[]' 'false' '{"tokens":[]}' '{"tokens":"bad"}'; do
  printf '%s\n' "$malformed_active_auth" >"$TEST_HOME/.codex/auth.json"
  HOME="$TEST_HOME" bash "$COMMAND" widget --cached --format json >"$TEST_HOME/malformed-active.json" 2>"$TEST_HOME/malformed-active.err" || \
    fail "malformed active auth aborted widget collection"
  [[ ! -s "$TEST_HOME/malformed-active.err" ]] || fail "malformed active auth printed a traceback"
done

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

FAKE_BIN="$TEST_HOME/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 755 "$FAKE_BIN/security"
HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" bash "$COMMAND" widget --format json >"$TEST_HOME/claude-failure.json"
python3 - "$TEST_HOME/claude-failure.json" <<'PY' || fail "Claude credential failure discarded matching metadata cache evidence"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    items = json.load(handle)["accounts"]
claude = next(item for item in items if item["provider"] == "claude")
assert claude["stale"] is True
assert claude["status"] == "missing_credentials"
assert claude["snapshot"]["current_remaining_percent"] == 50
PY
[[ -f "$claude_cache" ]] || fail "Claude credential failure deleted a valid owner-bound cache"

for malformed_credentials in '[]' '42' '{"claudeAiOauth":[]}' '{"claudeAiOauth":"bad"}'; do
  cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$malformed_credentials'
EOF
  chmod 755 "$FAKE_BIN/security"
  HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" bash "$COMMAND" widget --format json >"$TEST_HOME/claude-malformed.json" || \
    fail "malformed Claude credentials aborted the full widget"
  python3 - "$TEST_HOME/claude-malformed.json" <<'PY' || fail "malformed Claude credentials did not stay provider-scoped"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    accounts = json.load(handle)["accounts"]
assert any(account["provider"] == "codex" for account in accounts)
claude = next(account for account in accounts if account["provider"] == "claude")
assert claude["status"] == "missing_token"
PY
done

conflicting_claude_token="$(python3 - <<'PY'
import base64
import json

def part(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

print(f"{part({'alg': 'none'})}.{part({'sub': 'conflicting-token-owner'})}.x")
PY
)"
cat >"$FAKE_BIN/security" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"accountUuid":"conflicting-credential-owner","claudeAiOauth":{"accessToken":"$conflicting_claude_token"}}'
EOF
chmod 755 "$FAKE_BIN/security"
HOME="$TEST_HOME" \
  PATH="$FAKE_BIN:$PATH" \
  CODEX_ACCOUNT_SWITCH_CLAUDE_USAGE_URL="http://127.0.0.1:1/usage" \
  bash "$COMMAND" widget --format json >"$TEST_HOME/claude-conflict.json"
python3 - "$TEST_HOME/claude-conflict.json" <<'PY' || fail "conflicting Claude owner evidence reused metadata cache aliases"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    items = json.load(handle)["accounts"]
claude = next(item for item in items if item["provider"] == "claude")
assert claude["stale"] is False
assert claude["snapshot"] is None
assert claude["status"] == "network_error"
PY
[[ ! -f "$claude_cache" ]] || fail "conflicting Claude owner evidence retained a stale cache"

write_claude_metadata account-3 "Another owner"
claude_identity >/dev/null
[[ ! -f "$claude_cache" ]] || fail "Claude cache survived an owner mismatch"

write_claude_metadata "" "Organization only"
cat >"$claude_cache" <<EOF
{"account_identity":"$stored_identity","account_alias_hashes":[],"organization_alias_hashes":["$organization_alias"],"snapshot":{"last_seen_at":"2026-08-27T00:00:00Z","current_remaining_percent":50}}
EOF
claude_identity >/dev/null
[[ ! -f "$claude_cache" ]] || fail "organization-only Claude cache envelope survived validation"

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

(
  HOME="$TEST_HOME"
  # shellcheck source=../codex-accounts.sh
  source "$COMMAND"
  rotation_dir="$TEST_HOME/rotation-fixture"
  mkdir -p "$rotation_dir"
  cat >"$rotation_dir/saved.auth.json" <<EOF
{"last_refresh":"2026-08-27T00:00:00Z","tokens":{"id_token":"$subject_only_token","refresh_token":"old"}}
EOF
  cat >"$rotation_dir/refreshed.auth.json" <<EOF
{"last_refresh":"2026-08-27T01:00:00Z","tokens":{"id_token":"$subject_only_token","access_token":"$explicit_account_token","refresh_token":"new"}}
EOF
  cp "$rotation_dir/saved.auth.json" "$rotation_dir/baseline.auth.json"
  baseline_digest="$(auth_file_digest "$rotation_dir/baseline.auth.json")"
  copy_newer_matching_auth "$rotation_dir/refreshed.auth.json" "$rotation_dir/saved.auth.json" "$rotation_dir/baseline.auth.json" "$baseline_digest" || \
    fail "matching legacy credential rotation was discarded"
  grep -q '"refresh_token":"new"' "$rotation_dir/saved.auth.json" || \
    fail "matching legacy credential rotation was not reconciled"
  read -r proven_identity proven_alias <<EOF
$(account_identity_evidence_for_auth_path "$rotation_dir/refreshed.auth.json" | python3 -c 'import json,sys; value=json.load(sys.stdin); print(value["account_identity"], value["account_identity_aliases"][0])')
EOF
  [[ "$proven_identity" == "$expected_explicit_identity" ]] || \
    fail "proven legacy rotation emitted the wrong canonical identity"
  [[ "$proven_alias" == "$legacy_identity" ]] || \
    fail "proven legacy rotation emitted the wrong provisional alias"

  unrelated_strong_token="$(python3 - <<'PY'
import base64
import json

def part(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

print(f"{part({'alg': 'none'})}.{part({'sub': 'legacy-owner-1', 'account_id': 'unrelated-owner'})}.x")
PY
)"
  cat >"$rotation_dir/unrelated.auth.json" <<EOF
{"tokens":{"id_token":"$unrelated_strong_token"}}
EOF
  unrelated_alias_count="$(account_identity_evidence_for_auth_path "$rotation_dir/unrelated.auth.json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["account_identity_aliases"]))')"
  [[ "$unrelated_alias_count" == "0" ]] || fail "an unrelated strong account consumed another account's subject lineage"

  cat >"$rotation_dir/saved.auth.json" <<EOF
{"last_refresh":"2026-08-27T00:00:00Z","tokens":{"id_token":"$shared_subject_account_a","refresh_token":"owner-a"}}
EOF
  cat >"$rotation_dir/refreshed.auth.json" <<EOF
{"last_refresh":"2026-08-27T01:00:00Z","tokens":{"id_token":"$shared_subject_account_b","refresh_token":"owner-b"}}
EOF
  if copy_newer_matching_auth "$rotation_dir/refreshed.auth.json" "$rotation_dir/saved.auth.json"; then
    fail "different explicit owners sharing a subject reconciled credentials"
  fi
  grep -q '"refresh_token":"owner-a"' "$rotation_dir/saved.auth.json" || \
    fail "owner mismatch overwrote saved credentials"

  cat >"$rotation_dir/baseline.auth.json" <<EOF
{"last_refresh":"2026-08-27T00:00:00Z","tokens":{"id_token":"$subject_only_token","refresh_token":"baseline"}}
EOF
  cp "$rotation_dir/baseline.auth.json" "$rotation_dir/saved.auth.json"
  changed_baseline_digest="$(auth_file_digest "$rotation_dir/baseline.auth.json")"
  cat >"$rotation_dir/saved.auth.json" <<EOF
{"last_refresh":"2026-08-27T00:30:00Z","tokens":{"id_token":"$subject_only_token","refresh_token":"changed-after-snapshot"}}
EOF
  if copy_newer_matching_auth "$rotation_dir/refreshed.auth.json" "$rotation_dir/saved.auth.json" "$rotation_dir/baseline.auth.json" "$changed_baseline_digest"; then
    fail "legacy rotation overwrote a destination changed after its snapshot"
  fi
  grep -q 'changed-after-snapshot' "$rotation_dir/saved.auth.json" || \
    fail "failed baseline validation changed the destination"

  cp "$rotation_dir/baseline.auth.json" "$rotation_dir/saved.auth.json"
  stale_baseline_digest="$(auth_file_digest "$rotation_dir/baseline.auth.json")"
  cat >"$rotation_dir/baseline.auth.json" <<EOF
{"last_refresh":"2026-08-27T00:00:00Z","tokens":{"id_token":"$subject_only_token","refresh_token":"mutated-baseline"}}
EOF
  if copy_newer_matching_auth "$rotation_dir/refreshed.auth.json" "$rotation_dir/saved.auth.json" "$rotation_dir/baseline.auth.json" "$stale_baseline_digest"; then
    fail "legacy rotation accepted baseline bytes changed after digesting"
  fi
  grep -q '"refresh_token":"baseline"' "$rotation_dir/saved.auth.json" || \
    fail "baseline mutation changed the destination"

  cat >"$rotation_dir/baseline.auth.json" <<EOF
{"last_refresh":"2026-08-27T00:00:00Z","tokens":{"id_token":"$subject_only_token","refresh_token":"old"}}
EOF
  cp "$rotation_dir/baseline.auth.json" "$rotation_dir/saved.auth.json"
  forced_failure_digest="$(auth_file_digest "$rotation_dir/baseline.auth.json")"
  saved_lineage_file="$IDENTITY_LINEAGE_FILE"
  IDENTITY_LINEAGE_FILE="$rotation_dir/lineage-write-failure"
  mkdir "$IDENTITY_LINEAGE_FILE"
  if copy_newer_matching_auth "$rotation_dir/refreshed.auth.json" "$rotation_dir/saved.auth.json" "$rotation_dir/baseline.auth.json" "$forced_failure_digest"; then
    fail "legacy rotation succeeded when lineage publication failed"
  fi
  grep -q '"refresh_token":"old"' "$rotation_dir/saved.auth.json" || \
    fail "lineage publication failure installed refreshed credentials"
  IDENTITY_LINEAGE_FILE="$saved_lineage_file"

)

export CODEX_ACCOUNT_SWITCH_BIN=/bin/true
# shellcheck source=../plugins/swiftbar/ai-usage.1m.sh
original_home="$HOME"
HOME="$TEST_HOME"
source "$ROOT/plugins/swiftbar/ai-usage.1m.sh"
HOME="$original_home"
refresh_lock="$RUNTIME_DIR/refresh.lock"
acquire_refresh_lock "$refresh_lock" || fail "SwiftBar lock fixture could not acquire a fresh lock"
[[ -f "$refresh_lock" && ! -d "$refresh_lock" ]] || fail "SwiftBar lock was not published as a complete file"
[[ "$(sed -n '1p' "$refresh_lock")" =~ ^[0-9]+$ ]] || fail "SwiftBar lock omitted its owner PID"
if (acquire_refresh_lock "$refresh_lock"); then
  fail "SwiftBar lock admitted a contender while its owner was alive"
fi
release_refresh_lock "$refresh_lock" "$REFRESH_LOCK_OWNER_FILE"
[[ ! -e "$refresh_lock" ]] || fail "SwiftBar lock release left the lock published"

mkdir "$refresh_lock"
printf '%s\n' 99999999 >"$refresh_lock/pid"
acquire_refresh_lock "$refresh_lock" || fail "SwiftBar lock did not migrate a stale legacy directory"
[[ -f "$refresh_lock" && ! -d "$refresh_lock" ]] || fail "SwiftBar legacy lock was not migrated to a lock file"
release_refresh_lock "$refresh_lock" "$REFRESH_LOCK_OWNER_FILE"

mkdir "$refresh_lock"
printf '%s\n' "$$" >"$refresh_lock/pid"
if acquire_refresh_lock "$refresh_lock"; then
  fail "SwiftBar lock reclaimed a live legacy directory owner"
fi

echo "shell regressions passed"
