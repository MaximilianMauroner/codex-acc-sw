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

CLAUDE_HTTP_HOME="$TEST_HOME/claude-http-home"
mkdir -p "$CLAUDE_HTTP_HOME/.codex/accounts" "$CLAUDE_HTTP_HOME/.codex/switch"
cat >"$CLAUDE_HTTP_HOME/.codex/accounts/codex.auth.json" <<'EOF'
{"tokens":{}}
EOF
cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"accountUuid":"claude-http-owner","claudeAiOauth":{"accessToken":"fixture-token"}}'
EOF
chmod 755 "$FAKE_BIN/security"

run_claude_http_fixture() {
  local label="$1"
  local payload="$2"
  local expected_status="$3"
  local response_file="$TEST_HOME/claude-http-$label.response"
  local port_file="$TEST_HOME/claude-http-$label.port"
  local output_file="$TEST_HOME/claude-http-$label.output"
  local error_file="$TEST_HOME/claude-http-$label.error"
  local server_pid port
  printf '%s\n' "$payload" >"$response_file"
  rm -f "$port_file"
  python3 - "$response_file" "$port_file" <<'PY' &
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys

response_path, port_path = sys.argv[1:]
with open(response_path, "rb") as handle:
    body = handle.read()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

server = HTTPServer(("127.0.0.1", 0), Handler)
server.timeout = 5
with open(port_path, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_port))
server.handle_request()
PY
  server_pid=$!
  for _ in {1..500}; do
    [[ -s "$port_file" ]] && break
    if ! kill -0 "$server_pid" 2>/dev/null; then
      wait "$server_pid" || true
      fail "Claude HTTP fixture $label exited before publishing its port"
    fi
    sleep 0.01
  done
  [[ -s "$port_file" ]] || fail "Claude HTTP fixture $label did not publish its port"
  port="$(<"$port_file")"
  if ! HOME="$CLAUDE_HTTP_HOME" \
    PATH="$FAKE_BIN:$PATH" \
    CODEX_ACCOUNT_SWITCH_CLAUDE_USAGE_URL="http://127.0.0.1:$port/usage" \
    bash "$COMMAND" widget --format json --timeout 0.3 >"$output_file" 2>"$error_file"; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" || true
    fail "Claude HTTP fixture $label aborted the widget"
  fi
  wait "$server_pid"
  [[ ! -s "$error_file" ]] || fail "Claude HTTP fixture $label printed a traceback"
  python3 - "$output_file" "$expected_status" "$label" <<'PY' || fail "Claude HTTP fixture $label was not provider-scoped"
import json
import sys

path, expected, label = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    accounts = json.load(handle)["accounts"]
assert any(account["provider"] == "codex" for account in accounts)
claude = next(account for account in accounts if account["provider"] == "claude")
assert claude["status"] == expected
if expected == "ok":
    assert claude["snapshot"]["current_remaining_percent"] == 75.0
    assert claude["snapshot"]["weekly_remaining_percent"] == 50.0
    assert claude["snapshot"]["current_resets_at"] == "2026-08-28T12:00:00Z"
PY
}

run_claude_http_fixture top_array '[]' invalid_response
run_claude_http_fixture top_null 'null' invalid_response
run_claude_http_fixture top_string '"bad"' invalid_response
run_claude_http_fixture top_number '42' invalid_response
run_claude_http_fixture five_hour_array '{"five_hour":[],"seven_day":{"utilization":50}}' invalid_response
run_claude_http_fixture seven_day_string '{"five_hour":{"utilization":25},"seven_day":"bad"}' invalid_response
run_claude_http_fixture utilization_string '{"five_hour":{"utilization":"25"}}' invalid_response
run_claude_http_fixture utilization_bool '{"five_hour":{"utilization":true}}' invalid_response
run_claude_http_fixture utilization_infinite '{"five_hour":{"utilization":1e999}}' invalid_response
huge_utilization="$(python3 -c 'print("1" + "0" * 400)')"
run_claude_http_fixture utilization_huge_integer "{\"five_hour\":{\"utilization\":$huge_utilization}}" invalid_response
run_claude_http_fixture reset_number '{"five_hour":{"utilization":25,"resets_at":123}}' invalid_response
run_claude_http_fixture reset_array '{"five_hour":{"utilization":25},"seven_day":{"utilization":50,"resets_at":[]}}' invalid_response
run_claude_http_fixture valid_usage '{"five_hour":{"utilization":25,"resets_at":"2026-08-28T12:00:00Z"},"seven_day":{"utilization":50,"resets_at":null}}' ok

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
  [[ "$(json_field_json_value '[]' account_alias_hashes)" == "[]" ]] || \
    fail "JSON field helper did not default an array field for a non-object result"
  [[ "$(json_field_json_value '{invalid' organization_alias_hashes)" == "[]" ]] || \
    fail "JSON field helper did not default an array field for invalid JSON"
  [[ "$(json_field_json_value '{"account_alias_hashes":["ok",{}]}' account_alias_hashes)" == "[]" ]] || \
    fail "JSON field helper accepted a non-string alias element"
  [[ "$(json_field_json_value '"unexpected"' snapshot)" == "null" ]] || \
    fail "JSON field helper did not default a snapshot for a non-object result"
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

(
  HOME="$TEST_HOME"
  # shellcheck source=../codex-accounts.sh
  source "$COMMAND"
  recovery_root="$TEST_HOME/active-lineage-recovery"
  CODEX_HOME="$recovery_root/.codex"
  AUTH_FILE="$CODEX_HOME/auth.json"
  DATA_DIR="$CODEX_HOME/accounts"
  STATE_DIR="$CODEX_HOME/switch"
  STATE_FILE="$STATE_DIR/state"
  CONFIG_FILE="$STATE_DIR/config"
  USAGE_CACHE_DIR="$STATE_DIR/usage-cache"
  AUTH_STORE_LOCK_DIR="$STATE_DIR/auth-store.lock"
  IDENTITY_LINEAGE_FILE="$STATE_DIR/identity-lineage.json"
  ensure_dirs

  baseline_path="$recovery_root/baseline.auth.json"
  refreshed_path="$recovery_root/refreshed.auth.json"
  active_baseline_path="$recovery_root/active-baseline.auth.json"
  cat >"$baseline_path" <<EOF
{"last_refresh":"2026-08-27T00:00:00Z","tokens":{"id_token":"$subject_only_token","refresh_token":"old"}}
EOF
  cat >"$refreshed_path" <<EOF
{"last_refresh":"2026-08-27T01:00:00Z","tokens":{"id_token":"$subject_only_token","access_token":"$explicit_account_token","refresh_token":"new"}}
EOF

  cp "$baseline_path" "$DATA_DIR/alpha.auth.json"
  cp "$baseline_path" "$AUTH_FILE"
  cp "$AUTH_FILE" "$active_baseline_path"
  baseline_digest="$(auth_file_digest "$baseline_path")"
  acquire_auth_store_lock
  reconcile_refreshed_auth \
    "$refreshed_path" \
    "$DATA_DIR/alpha.auth.json" \
    "$baseline_path" \
    "$baseline_digest" \
    1 \
    "$active_baseline_path" || fail "normal proven rotation did not reconcile"
  release_auth_store_lock
  cmp -s "$refreshed_path" "$DATA_DIR/alpha.auth.json" || \
    fail "normal proven rotation left saved credentials stale"
  cmp -s "$refreshed_path" "$AUTH_FILE" || \
    fail "normal proven rotation left active credentials stale"
  [[ ! -e "$(pending_active_sync_path)" ]] || \
    fail "normal proven rotation left a pending active sync marker"
  [[ "$(current_account_name_from_auth)" == "alpha" ]] || \
    fail "normal proven rotation lost the active account name"
  sync_active_auth_to_saved_account alpha || \
    fail "normal proven rotation left active refresh/name synchronization broken"

  eval "$(declare -f publish_auth_if_unchanged | sed '1s/publish_auth_if_unchanged/real_publish_auth_if_unchanged/')"
  force_active_publish_failure=1
  publish_auth_if_unchanged() {
    if [[ "$force_active_publish_failure" == "1" && "$2" == "$AUTH_FILE" ]]; then
      return 1
    fi
    real_publish_auth_if_unchanged "$@"
  }

  cp "$baseline_path" "$DATA_DIR/alpha.auth.json"
  cp "$baseline_path" "$AUTH_FILE"
  cp "$AUTH_FILE" "$active_baseline_path"
  baseline_digest="$(auth_file_digest "$baseline_path")"
  acquire_auth_store_lock
  reconcile_refreshed_auth \
    "$refreshed_path" \
    "$DATA_DIR/alpha.auth.json" \
    "$baseline_path" \
    "$baseline_digest" \
    1 \
    "$active_baseline_path" || fail "active publish failure aborted saved reconciliation"
  release_auth_store_lock
  cmp -s "$refreshed_path" "$DATA_DIR/alpha.auth.json" || \
    fail "active publish failure prevented saved publication"
  cmp -s "$baseline_path" "$AUTH_FILE" || \
    fail "active publish failure changed active credentials"
  [[ -f "$(pending_active_sync_path)" ]] || \
    fail "active publish failure discarded its pending marker"
  force_active_publish_failure=0
  [[ "$(current_account_name_from_auth)" == "alpha" ]] || \
    fail "name detection did not retry a failed active publication"
  cmp -s "$refreshed_path" "$AUTH_FILE" || \
    fail "name detection retry did not repair active credentials"
  [[ ! -e "$(pending_active_sync_path)" ]] || \
    fail "successful active publication retry left its pending marker"

  cp "$baseline_path" "$AUTH_FILE"
  cp "$refreshed_path" "$DATA_DIR/alpha.auth.json"
  baseline_digest="$(auth_file_digest "$baseline_path")"
  refreshed_digest="$(auth_file_digest "$refreshed_path")"
  write_pending_active_sync "$DATA_DIR/alpha.auth.json" "$baseline_digest" "$refreshed_digest" || \
    fail "consume retry fixture did not create its pending marker"
  force_active_publish_failure=1
  [[ -z "$(current_account_name_from_auth)" ]] || \
    fail "failed marker consumption reported an active account"
  [[ -f "$(pending_active_sync_path)" ]] || \
    fail "consume-side CAS failure discarded its valid marker"
  cmp -s "$baseline_path" "$AUTH_FILE" || \
    fail "consume-side CAS failure changed active credentials"
  force_active_publish_failure=0
  [[ "$(current_account_name_from_auth)" == "alpha" ]] || \
    fail "marker consumption did not retry after a transient CAS failure"
  cmp -s "$refreshed_path" "$AUTH_FILE" || \
    fail "consume-side CAS retry did not repair active credentials"
  [[ ! -e "$(pending_active_sync_path)" ]] || \
    fail "consume-side CAS retry left its pending marker"

  cp "$baseline_path" "$DATA_DIR/alpha.auth.json"
  cp "$baseline_path" "$AUTH_FILE"
  baseline_digest="$(auth_file_digest "$baseline_path")"
  refreshed_digest="$(auth_file_digest "$refreshed_path")"
  acquire_auth_store_lock
  write_pending_active_sync "$DATA_DIR/alpha.auth.json" "$baseline_digest" "$refreshed_digest" || \
    fail "interruption fixture did not create its pending sync marker"
  copy_newer_matching_auth \
    "$refreshed_path" \
    "$DATA_DIR/alpha.auth.json" \
    "$baseline_path" \
    "$baseline_digest" \
    "$refreshed_digest" || fail "interruption fixture did not publish saved credentials"
  release_auth_store_lock
  cmp -s "$baseline_path" "$AUTH_FILE" || \
    fail "interruption fixture updated active credentials too early"
  [[ "$(current_account_name_from_auth)" == "alpha" ]] || \
    fail "pending sync recovery did not restore the active account name"
  cmp -s "$refreshed_path" "$AUTH_FILE" || \
    fail "pending sync recovery did not repair active credentials"

  cp "$baseline_path" "$DATA_DIR/alpha.auth.json"
  cp "$baseline_path" "$AUTH_FILE"
  baseline_digest="$(auth_file_digest "$baseline_path")"
  write_pending_active_sync "$DATA_DIR/alpha.auth.json" "$baseline_digest" "$refreshed_digest" || \
    fail "pre-publication crash fixture did not create its marker"
  [[ "$(current_account_name_from_auth)" == "alpha" ]] || \
    fail "pre-publication crash lost the unchanged byte-matched account"
  cmp -s "$baseline_path" "$AUTH_FILE" || \
    fail "pre-publication marker installed credentials absent from the saved account"
  [[ ! -e "$(pending_active_sync_path)" ]] || \
    fail "pre-publication marker was not consumed after saved digest rejection"

  cp "$baseline_path" "$DATA_DIR/alpha.auth.json"
  cp "$baseline_path" "$active_baseline_path"
  cat >"$AUTH_FILE" <<EOF
{"last_refresh":"2026-08-27T02:00:00Z","tokens":{"id_token":"$shared_subject_account_b","refresh_token":"concurrent-login"}}
EOF
  baseline_digest="$(auth_file_digest "$baseline_path")"
  acquire_auth_store_lock
  reconcile_refreshed_auth \
    "$refreshed_path" \
    "$DATA_DIR/alpha.auth.json" \
    "$baseline_path" \
    "$baseline_digest" \
    1 \
    "$active_baseline_path" || fail "concurrent-change fixture did not reconcile saved credentials"
  release_auth_store_lock
  grep -q 'concurrent-login' "$AUTH_FILE" || \
    fail "proven rotation overwrote a concurrent active login"
  [[ -f "$(pending_active_sync_path)" ]] || \
    fail "failed concurrent active CAS discarded its pending marker too early"
  current_account_name_from_auth >/dev/null || true
  [[ ! -e "$(pending_active_sync_path)" ]] || \
    fail "observed concurrent active divergence left a pending sync marker"

  rm -f "$DATA_DIR/beta.auth.json" "$(pending_active_sync_path)"
  cp "$refreshed_path" "$DATA_DIR/alpha.auth.json"
  cat >"$AUTH_FILE" <<EOF
{"last_refresh":"2026-08-27T02:00:00Z","tokens":{"id_token":"$subject_only_token","refresh_token":"subject-owner-b"}}
EOF
  subject_b_before="$(auth_file_digest "$AUTH_FILE")"
  [[ -z "$(current_account_name_from_auth)" ]] || \
    fail "a sole canonical lineage alias claimed a later subject-only owner"
  [[ "$(auth_file_digest "$AUTH_FILE")" == "$subject_b_before" ]] || \
    fail "a sole canonical lineage alias overwrote a later subject-only owner"
  printf '{bad marker\n' >"$(pending_active_sync_path)"
  [[ -z "$(current_account_name_from_auth)" ]] || \
    fail "a malformed pending marker selected an account"
  [[ ! -e "$(pending_active_sync_path)" ]] || \
    fail "a malformed pending marker was not removed"
  [[ "$(auth_file_digest "$AUTH_FILE")" == "$subject_b_before" ]] || \
    fail "a malformed pending marker rewrote active credentials"

  cp "$baseline_path" "$AUTH_FILE"
  cp "$refreshed_path" "$DATA_DIR/alpha.auth.json"
  cp "$refreshed_path" "$DATA_DIR/beta.auth.json"
  ambiguous_before="$(auth_file_digest "$AUTH_FILE")"
  [[ -z "$(current_account_name_from_auth)" ]] || \
    fail "multiple saved canonical files selected an ambiguous active account"
  [[ "$(auth_file_digest "$AUTH_FILE")" == "$ambiguous_before" ]] || \
    fail "multiple saved canonical files rewrote active credentials"
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
