# codex-acc-sw

Small hobby project for juggling multiple OpenAI Codex CLI accounts without constantly logging in and out.

This repo lives in the same problem space as the original [codex-cli-account-switcher](https://github.com/bashar94/codex-cli-account-switcher), but it has diverged into its own script, usage flow, and account/usage handling.

The official [OpenAI Codex CLI](https://github.com/openai/codex) still does not support multi-account login. If you use separate personal, work, or testing accounts, switching normally means replacing `~/.codex/auth.json` by hand or re-authenticating every time.

I also opened:
- [openai/codex#4432](https://github.com/openai/codex/issues/4432) for native multi-account support
- [openai/codex#4457](https://github.com/openai/codex/pull/4457) with an implementation attempt

Until something like that lands upstream, this script is the local workaround I use.

## Status

This is a hobby project. It is intended to be practical, local, and lightweight rather than polished or heavily battle-tested.

What I have personally tested:
- macOS

What should work, but is less verified:
- Linux
- WSL

## What it does

- Saves one Codex login per account name
- Switches accounts by replacing only `~/.codex/auth.json`
- Leaves the rest of `~/.codex` alone
- Tracks current and previous account names
- Shows current and weekly usage percentages per saved account
- Tries a short live usage refresh for the active account on `list`, `current`, and `switch`
- Supports a shorthand switch command: `acc-sw <name>`

## Requirements

- `bash`
- `python3`
- OpenAI Codex CLI installed and working
- At least one successful `codex login`
- A writable home directory for:
  - `~/.codex`
  - `~/codex-data`
  - `~/.codex-switch`

For the live usage refresh features:
- working network access
- valid auth tokens in the active `~/.codex/auth.json`

Install Codex CLI if needed:
- macOS: `brew install codex`
- otherwise: follow the official [Codex CLI docs](https://developers.openai.com/codex/cli/)

## Installation

```bash
git clone https://github.com/MaximilianMauroner/codex-acc-sw.git
cd codex-acc-sw
chmod +x codex-accounts.sh
```

Optional global shortcut:

```bash
sudo ln -sf "$(pwd)/codex-accounts.sh" /usr/local/bin/acc-sw
```

If you do not want a global symlink, you can also run the script directly with:

```bash
./codex-accounts.sh
```

## Commands

```bash
acc-sw list
acc-sw current
acc-sw refresh
acc-sw save <name>
acc-sw add <name>
acc-sw <name>
acc-sw switch <name>
acc-sw rename <old-name> <new-name>
```

What they do:

- `acc-sw list`
  Lists saved accounts and shows the latest known current and weekly usage remaining.

- `acc-sw current`
  Shows the active account and the previously active one.

- `acc-sw refresh`
  Runs a longer manual live refresh for the active account's usage.

- `acc-sw save <name>`
  Saves the currently logged-in account under a name.

- `acc-sw add <name>`
  Prepares for logging into a brand new account. It backs up the current account if needed, removes the active `auth.json`, and then you run `codex login`.

- `acc-sw switch <name>`
  Switches to a saved account by replacing `~/.codex/auth.json`.

- `acc-sw <name>`
  Shortcut for `acc-sw switch <name>`.

- `acc-sw rename <old-name> <new-name>`
  Renames a saved account and updates related saved state.

## Quick start

Save your current Codex login:

```bash
acc-sw save main
```

Add another account:

```bash
acc-sw add second
codex login
acc-sw save second
```

Switch between them:

```bash
acc-sw second
acc-sw main
```

Check the saved accounts:

```bash
acc-sw list
```

Refresh live usage for the active account:

```bash
acc-sw refresh
```

## How it works

The script only swaps the active Codex auth file:

- active account: `~/.codex/auth.json`
- saved accounts: `~/codex-data/<name>.auth.json`

It does not replace your broader Codex home directory, so your config, history, sessions, and logs stay in place.

For usage reporting, it keeps local cached snapshots and also tries to fetch a newer live snapshot for the currently active account when useful.

## Data stored locally

| Path | Purpose |
| --- | --- |
| `~/.codex/auth.json` | Active Codex account credentials |
| `~/codex-data/<name>.auth.json` | Saved account credentials |
| `~/.codex-switch/state` | Current and previous account names |
| `~/.codex-switch/usage.json` | Cached usage snapshots per account |
| `~/.codex-switch/usage-refresh.json` | Refresh timing metadata |

## Notes and caveats

- Only the auth file is swapped. This is intentional.
- `list`, `current`, and `switch` do a short best-effort live usage refresh for the active account and fall back to cached data if that refresh fails.
- `refresh` uses a longer timeout than the automatic refresh path.
- The active `[current]` marker is derived from the live `~/.codex/auth.json` when possible, not only from the saved state file.
- The script avoids assigning stale pre-switch usage snapshots to a newly switched account until there is newer activity for that account.
- If `~/.codex/auth.json` is missing when saving or adding, the script will tell you to log in first.
- Since this is a hobby project, expect rough edges and verify behavior before relying on it in a critical workflow.

## Why this exists

Codex CLI multi-account support would be better as a native feature. Until then, this script is a simple local workaround that has been good enough for my own setup.
