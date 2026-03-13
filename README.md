# codex-acc-sw

**Easily manage multiple OpenAI Codex CLI accounts by swapping only the saved login credentials.**

Based on the original [codex-cli-account-switcher](https://github.com/bashar94/codex-cli-account-switcher).

The official [OpenAI Codex CLI](https://github.com/openai/codex) does **not support multi-account login**.  
Users must manually re-authenticate every time they switch accounts — a painful process for developers who use multiple OpenAI accounts (for example, personal vs work).

I raised this issue here: [#4432](https://github.com/openai/codex/issues/4432)  
and also created a pull request adding multi-account support: [#4457](https://github.com/openai/codex/pull/4457)  
However, the feature hasn’t yet been merged or prioritized, so this standalone script fills that gap.

***I HAVE TESTED THIS ON MAC ONLY***


---

## 🔧 Installation

```bash
# Clone and install
git clone https://github.com/MaximilianMauroner/codex-acc-sw.git
cd codex-acc-sw
chmod +x codex-accounts.sh

# Optionally make it global via a shorter symlink
sudo ln -sf "$(pwd)/codex-accounts.sh" /usr/local/bin/acc-sw
```

## 🚀 Usage
```
acc-sw list
acc-sw current
acc-sw refresh
acc-sw save <name>
acc-sw add <name>
acc-sw <name>
acc-sw switch <name>
acc-sw rename <old-name> <new-name>
```
### Examples
```
# Save your current login
acc-sw save bashar

# Add a new account slot
acc-sw add tazrin
codex login   # then run:
acc-sw save tazrin

# Switch between accounts
acc-sw bashar

# Equivalent explicit form
acc-sw switch bashar

# Try to fetch fresh usage for the active account
acc-sw refresh

# Fix a mistaken saved name
acc-sw rename main third
```
`acc-sw list` also shows the latest known current and weekly remaining usage for each account.
The active `[current]` marker is derived from the live `~/.codex/auth.json` when possible, not just the saved state file.
## 📁 Data Locations
Codex stores its login credentials in `~/.codex/auth.json`.
This script saves one `auth.json` file per account and swaps only that file, leaving the rest of your `~/.codex` data alone.

| Path                            | Purpose                              |
| ------------------------------- | ------------------------------------ |
| `~/.codex/auth.json`            | Active Codex account credentials     |
| `~/codex-data/<name>.auth.json` | Saved account credentials            |
| `~/.codex-switch/state`         | Tracks current and previous accounts |

It’s safe to use — your Codex configuration, history, sessions, and logs are preserved during every switch.

## ⚙️ Requirements
- macOS / Linux
- `bash`
- `python3`
- Codex CLI installed:
  - macOS: `brew install codex`
  - Linux: use your package manager or follow the [Codex CLI docs](https://developers.openai.com/codex/cli/)

## 🧠 Notes
- Supports unlimited accounts — name-based switching.
- Automatically backs up the current account credentials before changing.
- Shows the current and previous account states.
- Shows the latest known current and weekly remaining usage in `acc-sw list`.
- `switch`, `current`, and `list` do a short best-effort live usage refresh for the active account and fall back to cached usage if that probe fails.
- `acc-sw refresh` runs a longer explicit live probe for the currently active account.
- Live usage refresh uses the active `~/.codex/auth.json` tokens against ChatGPT's usage endpoint instead of relying only on session logs.
- Avoids assigning pre-switch usage snapshots to a freshly switched account until that account has produced its own newer Codex session activity.
- Works cross-platform: macOS, Linux, WSL.
- Lightweight local dependencies (`bash`, `python3`).
- Helpful prompts if Codex isn’t installed or logged in yet.
- You can safely share this across machines (just copy `~/codex-data`).
