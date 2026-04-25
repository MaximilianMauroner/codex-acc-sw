# codex-acc-sw

`codex-account-switch` is a small Unix-style helper for switching between multiple OpenAI Codex CLI accounts without repeatedly logging in and out.

This repo lives in the same problem space as the original [codex-cli-account-switcher](https://github.com/bashar94/codex-cli-account-switcher), but it has diverged into its own script, usage flow, and account/usage handling.

The official [OpenAI Codex CLI](https://github.com/openai/codex) still does not support multi-account login. If you use separate personal, work, or testing accounts, switching normally means replacing `~/.codex/auth.json` by hand or re-authenticating every time.

Relevant background from the original project:
- the original author raised [openai/codex#4432](https://github.com/openai/codex/issues/4432) for native multi-account support
- the original author also opened [openai/codex#4457](https://github.com/openai/codex/pull/4457) with an implementation attempt

This repo is a separate hobby project built from that starting point and adapted into its own local workflow.

## Features

- Saves one Codex login per account name
- Switches accounts by replacing only `~/.codex/auth.json`
- Leaves the rest of `~/.codex` alone
- Tracks the active account name
- Shows current and weekly usage percentages per saved account
- Shows the next current-window reset time per saved account
- Fetches live usage on every `list`, `current`, and account switch
- Switches accounts with `codex-account-switch ACCOUNT_NAME`

## Status

This is a hobby project. It is intended to be practical, local, and lightweight rather than polished or heavily battle-tested.

Tested:
- macOS

Expected to work, but less verified:
- Linux
- WSL

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

One-line install:

```bash
curl -fsSL https://raw.githubusercontent.com/MaximilianMauroner/codex-acc-sw/main/install.sh | bash
```

One-line install with the short alias too:

```bash
curl -fsSL https://raw.githubusercontent.com/MaximilianMauroner/codex-acc-sw/main/install.sh | bash -s -- --alias
```

Install a specific tagged release:

```bash
curl -fsSL https://raw.githubusercontent.com/MaximilianMauroner/codex-acc-sw/main/install.sh | bash -s -- --version v0.1.0
```

Manual install:

```bash
git clone https://github.com/MaximilianMauroner/codex-acc-sw.git
cd codex-acc-sw
```

Install for the current user:

```bash
make install PREFIX="$HOME/.local"
```

Install system-wide:

```bash
sudo make install PREFIX=/usr/local
```

Install the optional `acc-sw` alias:

```bash
make install PREFIX="$HOME/.local" INSTALL_ALIAS=1
```

Packaging or staged installs can use `DESTDIR`:

```bash
make install PREFIX=/usr/local DESTDIR="$PWD/stage"
```

You can also run it directly from the repository:

```bash
./codex-accounts.sh
```

## Usage

```bash
codex-account-switch [COMMAND]
codex-account-switch ACCOUNT_NAME
```

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

## Standard install variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `PREFIX` | `/usr/local` | Base install prefix |
| `DESTDIR` | empty | Staging root for packaging |
| `BINDIR` | `$(PREFIX)/bin` | Command install directory |
| `LIBEXECDIR` | `$(PREFIX)/libexec/codex-account-switch` | Private helper/script directory |
| `INSTALL_ALIAS` | `0` | Set to `1` to install `acc-sw` |

## Quick start

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

Configure output:

```bash
codex-account-switch configure
codex-account-switch configure reset human
codex-account-switch configure show plan on
codex-account-switch configure preset default
```

## How it works

`codex-account-switch` only swaps the active Codex auth file:

- active account: `~/.codex/auth.json`
- saved accounts: `~/.codex/accounts/<name>.auth.json`

It does not replace the rest of your Codex home directory, so config, history, sessions, and logs stay in place.

For usage reporting, it calls the usage API directly whenever it shows usage data. `list` fetches each saved account live from its saved auth file, while `current` and account switching fetch live from the active `~/.codex/auth.json`.
By default, the output is compact and shows `window`, `week`, and a human-readable `next reset` countdown. Free-tier accounts collapse to `free plan` by default. You can change the reset style and optional fields with `codex-account-switch configure`.

## Configuration

Display settings are stored in `~/.codex/switch/config`.

```bash
codex-account-switch configure
codex-account-switch configure reset human
codex-account-switch configure reset normal
codex-account-switch configure show plan on
codex-account-switch configure show updated on
codex-account-switch configure show next-reset off
codex-account-switch configure show live on
codex-account-switch configure preset default
codex-account-switch configure preset verbose
```

## Data stored locally

| Path | Purpose |
| --- | --- |
| `~/.codex/auth.json` | Active Codex account credentials |
| `~/.codex/accounts/<name>.auth.json` | Saved account credentials |
| `~/.codex/switch/state` | Active account state used for switching |

## Notes

- Only the auth file is swapped. This is intentional.
- `list`, `current`, and account switching do not read from a local usage cache. They fetch live usage data every time.
- `list` fetches each saved account directly from its saved auth file, so it can show up-to-date data for accounts that are not currently active.
- The active `[active]` marker is derived from the live `~/.codex/auth.json` when possible, not only from the saved state file.
- If `~/.codex/auth.json` is missing when saving or adding, the script will tell you to log in first.
- Since this is a hobby project, expect rough edges and verify behavior before relying on it in a critical workflow.

## License

This project is released under the MIT License. See `LICENSE`.
