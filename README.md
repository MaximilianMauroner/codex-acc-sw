# codex-acc-sw

Small hobby project for juggling multiple OpenAI Codex CLI accounts without constantly logging in and out.

This repo lives in the same problem space as the original [codex-cli-account-switcher](https://github.com/bashar94/codex-cli-account-switcher), but it has diverged into its own script, usage flow, and account/usage handling.

The official [OpenAI Codex CLI](https://github.com/openai/codex) still does not support multi-account login. If you use separate personal, work, or testing accounts, switching normally means replacing `~/.codex/auth.json` by hand or re-authenticating every time.

Relevant background from the original project:
- the original author raised [openai/codex#4432](https://github.com/openai/codex/issues/4432) for native multi-account support
- the original author also opened [openai/codex#4457](https://github.com/openai/codex/pull/4457) with an implementation attempt

This repo is a separate hobby project built from that starting point and adapted into its own local workflow.

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
- Tracks the active account name
- Shows current and weekly usage percentages per saved account
- Shows the next current-window reset time per saved account
- Fetches live usage on every `list`, `current`, `switch`, and `refresh`
- Supports a shorthand switch command: `acc-sw <name>`

## Requirements

- `bash`
- `python3`
- OpenAI Codex CLI installed and working
- At least one successful `codex login`
- A writable home directory for:
  - `~/.codex`

For the live usage features:
- working network access
- valid auth tokens in the relevant saved `*.auth.json` files

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
acc-sw remove <name>
```

What they do:

- `acc-sw list`
  Lists saved accounts and fetches live current and weekly usage remaining for each one, plus the next current-window reset time.

- `acc-sw current`
  Shows the active account, its live usage, and the next current-window reset time.

- `acc-sw refresh`
  Runs a longer manual live refresh for the active account's usage and shows the next current-window reset time.

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

- `acc-sw remove <name>`
  Removes a saved account. You must switch away first if it is currently active.

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
- saved accounts: `~/.codex/accounts/<name>.auth.json`

It does not replace your broader Codex home directory, so your config, history, sessions, and logs stay in place.

For usage reporting, it calls the usage API directly whenever it shows usage data. `list` fetches each saved account live from its saved auth file, while `current`, `switch`, and `refresh` fetch live from the active `~/.codex/auth.json`.
The output also includes the next current-window reset time when the API returns it, so you can see when that account becomes usable again.

## Data stored locally

| Path | Purpose |
| --- | --- |
| `~/.codex/auth.json` | Active Codex account credentials |
| `~/.codex/accounts/<name>.auth.json` | Saved account credentials |
| `~/.codex/switch/state` | Active account state used for switching |

## Notes and caveats

- Only the auth file is swapped. This is intentional.
- `list`, `current`, `switch`, and `refresh` do not read from a local usage cache. They fetch live usage data every time.
- `list` fetches each saved account directly from its saved auth file, so it can show up-to-date data for accounts that are not currently active.
- `refresh` uses a longer timeout than the automatic refresh path.
- The active `[active]` marker is derived from the live `~/.codex/auth.json` when possible, not only from the saved state file.
- If `~/.codex/auth.json` is missing when saving or adding, the script will tell you to log in first.
- Since this is a hobby project, expect rough edges and verify behavior before relying on it in a critical workflow.

## License

This project is released under the MIT License. See `LICENSE`.
