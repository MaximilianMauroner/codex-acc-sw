# Usage

## Commands

```text
codex-account-switch list
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
| `codex-account-switch list` | List saved accounts with live usage, including the next reset when available |
| `codex-account-switch current` | Show the active account with live usage |
| `codex-account-switch configure` | Configure reset style and optional output fields |
| `codex-account-switch save [NAME]` | Save the current login under `NAME`, or prompt if omitted |
| `codex-account-switch add NAME` | Prepare for login to a new account named `NAME` |
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

Show all saved accounts:

```bash
codex-account-switch list
```

## Output configuration

Show current settings:

```bash
codex-account-switch configure
```

Use relative reset times:

```bash
codex-account-switch configure reset human
```

Use absolute reset timestamps:

```bash
codex-account-switch configure reset normal
```

Toggle optional fields:

```bash
codex-account-switch configure show plan on
codex-account-switch configure show updated on
codex-account-switch configure show next-reset off
codex-account-switch configure show live on
```

Apply presets:

```bash
codex-account-switch configure preset default
codex-account-switch configure preset verbose
```

By default:

- output is compact
- free-tier accounts show as `free plan`
- the next reset is shown as a relative countdown

## How it works

`codex-account-switch` only swaps the active Codex auth file:

- active account: `~/.codex/auth.json`
- saved accounts: `~/.codex/accounts/<name>.auth.json`

It does not replace the rest of your Codex home directory, so config, history, sessions, and logs stay in place.

For usage reporting:

- `list` fetches each saved account live from its saved auth file
- `current` and account switching fetch live from the active `~/.codex/auth.json`
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
- The active `[active]` marker is derived from the live `~/.codex/auth.json` when possible.
- If `~/.codex/auth.json` is missing when saving or adding, the script will tell you to log in first.
