# Usage

## Commands

```text
codex-account-switch status
codex-account-switch current
codex-account-switch widget [--format swiftbar|json|text]
codex-account-switch configure
codex-account-switch save [NAME]
codex-account-switch add NAME
codex-account-switch switch ACCOUNT_NAME
codex-account-switch ACCOUNT_NAME
codex-account-switch rename OLD_NAME NEW_NAME
codex-account-switch remove NAME
```

| Command | Description |
| --- | --- |
| `codex-account-switch status` | Show all accounts with live usage (`list` is a backward-compatible alias) |
| `codex-account-switch current` | Show the active account with live usage |
| `codex-account-switch widget` | Render Codex + Claude usage for a SwiftBar menu-bar widget, JSON, or text |
| `codex-account-switch configure` | Configure reset style and optional display fields |
| `codex-account-switch save [NAME]` | Save the current login under `NAME`, or prompt if omitted. Refuses to overwrite a different saved account |
| `codex-account-switch add NAME` | Prepare for login to a new account named `NAME`. Refuses existing names and saves the current login first if needed |
| `codex-account-switch switch ACCOUNT_NAME` | Switch to an existing saved account |
| `codex-account-switch ACCOUNT_NAME` | Shortcut for switching to an existing saved account |
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
- `stale` — live usage could not be fetched, so the row is showing the last successful usage snapshot.
- `login expired` — live usage could not be fetched and no cached snapshot exists. Switch to that account and run `codex login` again.
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

## Native menu-bar app

The native app gives the usage data a real SwiftUI surface instead of a SwiftBar text menu:

```bash
make install PREFIX="$HOME/.local"
make install-macos-menu-app PREFIX="$HOME/.local"
make open-macos-menu-app
```

The menu-bar title stays compact, for example `CX chris wk26% 4d main wk84% 6d | CC 5h78% 4h`. Each value shows the limiting budget period, its remaining percent, and that period's reset in one unit. The `CX` side lists every working non-free Codex plan, active account first; free plans and errored accounts stay out of the closed title. Opening it shows:

- 30-day stacked cost history from local Codex and Claude transcripts, with per-day hover breakdowns
- active Codex and Claude summary tiles
- 5h and weekly progress bars
- reset times
- projected pace labels
- local sparklines from samples collected while the app runs
- login, network, and stale-data states from the existing CLI

The app refreshes cached data immediately, then fetches live data in the background. It also refreshes roughly once per minute while running.

Use the Settings screen to choose which working plans appear in the closed menu-bar title. Hidden plans remain visible inside the popover; if every item is hidden, the title falls back to `AI`.

Use the Actions screen to switch Codex accounts, save the current login, prepare a new login, rename saved accounts, or remove inactive saved accounts. The new-login flow can open Terminal for `codex login` and then saves the account under the prepared name.

The `x` button hides the popover. To quit the app, open the About screen from the header and use `Quit AI Usage Bar`.

The cost chart uses [context-bar](https://github.com/htahaozlu/context-bar)'s `daily --json --instances` report. The app prefers an installed `context-bar` binary, then falls back to `npx context-bar@latest daily --json --instances` if `npx` is available. Cost values are estimates derived from local transcript usage and model pricing, not provider billing statements.

Claude Code usage is fetched from the macOS Keychain generic-password item with service `Claude Code-credentials`. See [Claude auth notes](claude-auth.md) for the local storage findings and what would be needed for future Claude profile switching.

## SwiftBar widget

`widget` renders all saved Codex accounts plus Claude usage for a native macOS menu-bar workflow:

```bash
codex-account-switch widget --format swiftbar
codex-account-switch widget --format json
codex-account-switch widget --format text
codex-account-switch widget --cached
codex-account-switch widget --refresh-cache
```

The SwiftBar plugin is installed separately:

```bash
brew install swiftbar
make install PREFIX="$HOME/.local"
make install-swiftbar-widget
```

The plugin uses SwiftBar's refresh-on-open setting, but renders cached usage first so the menu opens quickly. It then warms a fresh usage snapshot in the background for the next open or refresh. The collapsed title shows active Codex + Claude when healthy, for example `Cdx 82 · Cla 38`; login errors for the active Codex account or Claude take priority.

Title and account-row colors reflect projected burn pace:

- `red` means the current pace is projected to hit zero before the reset.
- `orange` means the current pace is tight and projected to have less than 12% left at reset.
- `green` means the current pace is projected to survive the reset with buffer.
- `gray` means the widget is still learning pace, showing a free plan, or using unavailable data.

The dropdown includes a `Pace:` line for paid plans, such as `5h fast, empty 1h47m early` or `week steady, 42% at reset`.

Claude widget errors are explicit:

- `login needed` — Claude Code credentials are missing, expired, or have no access token.
- `network error` — the Anthropic usage API or local keychain read timed out or failed.
- `invalid response` — the API returned data that could not be parsed as usage.
- `security command missing` — the macOS Keychain CLI is unavailable.

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
| `~/.codex/switch/usage-cache/*.json` | Last successful usage snapshots used for stale widget/status rows |

## Notes

- Only the auth file is swapped.
- Usage is fetched live whenever it is shown.
- The active `*` marker is derived from the live `~/.codex/auth.json` when possible.
- If `~/.codex/auth.json` is missing when saving, the script will tell you to log in first.
- `add NAME` reserves `NAME` for the next login and will not overwrite an existing saved account.
