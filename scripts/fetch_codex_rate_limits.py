#!/usr/bin/env python3
from __future__ import annotations

import base64
import datetime as dt
import json
import os
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request


AUTH_REFRESH_URL = "https://auth.openai.com/oauth/token"
USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
REFRESH_GRACE_SECONDS = 60
REFRESH_MAX_AGE_DAYS = 8


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def now_iso() -> str:
    return utcnow().replace(microsecond=0).isoformat().replace("+00:00", "Z")


def load_auth(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def write_auth(path: str, data: dict) -> None:
    directory = os.path.dirname(path) or "."
    fd, tmp_path = tempfile.mkstemp(prefix=".acc-sw-auth.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def jwt_payload(token: str | None) -> dict:
    if not token or token.count(".") < 2:
        return {}
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        decoded = base64.urlsafe_b64decode(payload.encode("ascii"))
        return json.loads(decoded.decode("utf-8"))
    except Exception:
        return {}


def parse_iso8601(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def should_refresh(auth: dict) -> bool:
    tokens = auth.get("tokens") or {}
    access_token = tokens.get("access_token")
    payload = jwt_payload(access_token)
    exp = payload.get("exp")
    if exp is None:
        return True

    try:
        exp_dt = dt.datetime.fromtimestamp(float(exp), tz=dt.timezone.utc)
    except Exception:
        return True

    if exp_dt <= utcnow() + dt.timedelta(seconds=REFRESH_GRACE_SECONDS):
        return True

    last_refresh = parse_iso8601(auth.get("last_refresh"))
    if last_refresh is None:
        return False

    return last_refresh <= utcnow() - dt.timedelta(days=REFRESH_MAX_AGE_DAYS)


def request_json(
    method: str,
    url: str,
    timeout_seconds: float,
    headers: dict[str, str],
    body: bytes | None = None,
) -> tuple[int, dict]:
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout_seconds) as response:
            return response.getcode(), json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = {"error": body}
        return exc.code, parsed


def refresh_tokens(auth_path: str, auth: dict, timeout_seconds: float) -> dict:
    tokens = auth.get("tokens") or {}
    refresh_token = tokens.get("refresh_token")
    if not refresh_token:
        raise RuntimeError("missing refresh token")

    body = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": CLIENT_ID,
        }
    ).encode("utf-8")

    status, payload = request_json(
        "POST",
        AUTH_REFRESH_URL,
        timeout_seconds,
        {
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
        body,
    )
    if status < 200 or status >= 300:
        raise RuntimeError(f"token refresh failed: {status}")

    new_tokens = dict(tokens)
    for key in ("access_token", "refresh_token", "id_token"):
        value = payload.get(key)
        if value:
            new_tokens[key] = value

    auth["tokens"] = new_tokens
    auth["last_refresh"] = now_iso()
    write_auth(auth_path, auth)
    return auth


def fetch_usage(auth: dict, timeout_seconds: float) -> tuple[int, dict]:
    tokens = auth.get("tokens") or {}
    access_token = tokens.get("access_token")
    account_id = tokens.get("account_id")
    if not access_token:
        raise RuntimeError("missing access token")

    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {access_token}",
    }
    if account_id:
        headers["ChatGPT-Account-Id"] = account_id

    return request_json("GET", USAGE_URL, timeout_seconds, headers)


def build_snapshot(payload: dict) -> dict:
    rate_limit = payload.get("rate_limit") or {}
    primary = rate_limit.get("primary_window") or payload.get("primary_window") or {}
    secondary = rate_limit.get("secondary_window") or payload.get("secondary_window") or {}

    current_used = primary.get("used_percent")
    weekly_used = secondary.get("used_percent")

    if current_used is None and weekly_used is None:
        raise RuntimeError("usage payload missing rate-limit percentages")

    current_window_seconds = primary.get("limit_window_seconds")
    weekly_window_seconds = secondary.get("limit_window_seconds")

    return {
        "last_seen_at": now_iso(),
        "current_remaining_percent": None
        if current_used is None
        else max(0.0, 100.0 - float(current_used)),
        "weekly_remaining_percent": None
        if weekly_used is None
        else max(0.0, 100.0 - float(weekly_used)),
        "current_window_minutes": None
        if current_window_seconds is None
        else float(current_window_seconds) / 60.0,
        "weekly_window_minutes": None
        if weekly_window_seconds is None
        else float(weekly_window_seconds) / 60.0,
        "current_resets_at": primary.get("resets_at"),
        "weekly_resets_at": secondary.get("resets_at"),
    }


def main() -> int:
    auth_path = sys.argv[1]
    timeout_seconds = float(sys.argv[2])

    try:
        auth = load_auth(auth_path)
        if should_refresh(auth):
            auth = refresh_tokens(auth_path, auth, timeout_seconds)

        status, payload = fetch_usage(auth, timeout_seconds)
        if status in (401, 403):
            auth = refresh_tokens(auth_path, auth, timeout_seconds)
            status, payload = fetch_usage(auth, timeout_seconds)

        if status < 200 or status >= 300:
            return 1

        snapshot = build_snapshot(payload)
        print(json.dumps(snapshot, separators=(",", ":")))
        return 0
    except Exception:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
