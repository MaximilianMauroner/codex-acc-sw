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

Save the current login under a name:

```bash
codex-account-switch save work
```

Add a second account:

```bash
codex-account-switch add personal
codex login
codex-account-switch save personal
```

Switch between accounts:

```bash
codex-account-switch personal
codex-account-switch work
```

Show status for all saved accounts:

```bash
acc-sw status
```

## Status output

```
$ acc-sw status
── codex ──────────────────────────────────────────────
* work      5h:  82%  week:  54%  reset: 1h14m / 5d3h
  personal  5h:   0%  week:  91%  reset: 1h14m / 5d3h
  client    5h:   7%  week:  23%  reset: 1h14m / 5d3h
── claude ─────────────────────────────────────────────
  claude    5h:  38%  week:  67%  reset: 1h14m / 5d3h
```

- `*` marks the active account.
- `5h:` — remaining budget in the current 5-hour window.
- `week:` — remaining budget for the current 7-day period.
- `reset: A / B` — time until the 5h window resets / time until the weekly reset. Minutes are hidden on the weekly value once more than a day remains.
- Both percentages are color-coded: 🔴 red at 0 %, 🟡 yellow at 1–10 %, ⬜ default at 11–60 %, 🟢 green above 60 %.
- The Claude row is fetched from the Anthropic API via the Claude Code keychain credentials (macOS only). It appears only when Claude Code is installed and signed in.

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
- the Claude row is fetched from the Anthropic OAuth API using the Claude Code keychain token
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
