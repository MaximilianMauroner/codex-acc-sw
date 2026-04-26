# Usage

## Commands

```text
codex-account-switch status
codex-account-switch current
codex-account-switch configure
codex-account-switch save [NAME]
codex-account-switch add NAME
codex-account-switch ACCOUNT_NAME
codex-account-switch rename OLD_NAME NEW_NAME
codex-account-switch remove NAME
```

| Command | Description |
| --- | --- |
| `codex-account-switch status` | Show all accounts with live usage (`list` is a backward-compatible alias) |
| `codex-account-switch current` | Show the active account with live usage |
| `codex-account-switch configure` | Configure reset style and optional display fields |
| `codex-account-switch save [NAME]` | Save the current login under `NAME`, or prompt if omitted. Refuses to overwrite a different saved account |
| `codex-account-switch add NAME` | Prepare for login to a new account named `NAME`. Refuses existing names and saves the current login first if needed |
| `codex-account-switch ACCOUNT_NAME` | Switch to an existing saved account |
| `codex-account-switch rename OLD_NAME NEW_NAME` | Rename a saved account |
| `codex-account-switch remove NAME` | Remove a saved account that is not currently active |

## Common workflow

Save the current login:

```bash
codex-account-switch save main
```

Add another account:

```bash
codex-account-switch add second
codex login
codex-account-switch save second
```

Switch between accounts:

```bash
codex-account-switch second
codex-account-switch main
```

Check status of all accounts:

```bash
acc-sw status
```

## Status output

```
── codex ───────────────────────────────────────────────
* main    5h: 100%  week:   0%  reset: 4h59m / 2d1h
  second  5h:   0%  week:   1%  reset: 49m   / 2d13h
  fourth  5h:   0%  week:  69%  reset: 3h53m / 6d16h
── claude ──────────────────────────────────────────────
  claude  5h:  55%  week:  70%  reset: 2h15m / 4d3h
```

- `*` marks the active account.
- `5h:` — remaining budget in the current 5-hour window.
- `week:` — remaining budget for the current 7-day period.
- `reset: A / B` — time until the 5h window resets / time until the weekly reset. Minutes are hidden on the weekly value once more than a day remains.
- Both percentages are color-coded: 🔴 red at 0 %, 🟡 yellow at 1–10 %, ⬜ default at 11–60 %, 🟢 green above 60 %.
- The Claude section reads live data from the Anthropic API via the Claude Code keychain credentials (macOS only).

## Output configuration

Show current settings:

```bash
codex-account-switch configure
```

Use relative reset times (default):

```bash
codex-account-switch configure reset human
```

Use absolute reset timestamps:

```bash
codex-account-switch configure reset normal
```

Toggle the Claude section:

```bash
codex-account-switch configure show claude off
codex-account-switch configure show claude on
```

## How it works

`codex-account-switch` only swaps the active Codex auth file:

- active account: `~/.codex/auth.json`
- saved accounts: `~/.codex/accounts/<name>.auth.json`

It does not replace the rest of your Codex home directory, so config, history, sessions, and logs stay in place.

For usage reporting:

- `status` fetches each saved account live from its saved auth file
- `current` and account switching fetch live from the active `~/.codex/auth.json`
- the Claude section is fetched from the Anthropic OAuth API using the Claude Code keychain token
- free-tier accounts are shown as `free plan`

## Stored files

| Path | Purpose |
| --- | --- |
| `~/.codex/auth.json` | Active Codex account credentials |
| `~/.codex/accounts/<name>.auth.json` | Saved account credentials |
| `~/.codex/switch/state` | Active account state used for switching |
| `~/.codex/switch/config` | Output configuration |

## Notes

- Only the auth file is swapped.
- Usage is fetched live whenever it is shown.
- The active `*` marker is derived from the live `~/.codex/auth.json` when possible.
- If `~/.codex/auth.json` is missing when saving, the script will tell you to log in first.
- `add NAME` reserves `NAME` for the next login and will not overwrite an existing saved account.
