# codex-acc-sw

`codex-account-switch` (short alias: `acc-sw`) is a small Unix-style helper for switching between multiple OpenAI Codex CLI accounts and checking live usage at a glance.

## What it does

- Saves one Codex login per account name
- Switches accounts by replacing only `~/.codex/auth.json` — nothing else is touched
- Shows live usage for every saved account in a single aligned table
- Shows both the 5-hour window reset and the weekly reset side by side
- Color-codes usage percentages (green → yellow → red as budget depletes)
- Optionally shows Claude Code usage in the same table (macOS, auto-detected)
- Optional native SwiftUI menu-bar app with progress bars, pace projections, local sparklines, and cost history
- Optional SwiftBar menu-bar widget for a script-only setup

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/MaximilianMauroner/codex-acc-sw/main/install.sh | bash
```

Save your current login, add a second account, then check status:

```bash
acc-sw save work
acc-sw add personal   # prepares a fresh login slot
codex login           # authenticate the new account
acc-sw save personal
acc-sw status
```

Switch accounts instantly:

```bash
acc-sw personal
acc-sw work
```

## Output

```
$ acc-sw status
── codex ──────────────────────────────────────────────
* work      5h:  82%  week:  54%  reset: 1h14m / 5d3h
  personal  5h:   0%  week:  91%  reset: 1h14m / 5d3h
  client    5h:   7%  week:  23%  reset: 1h14m / 5d3h
── claude ─────────────────────────────────────────────
  claude    5h:  38%  week:  67%  reset: 1h14m / 5d3h
```

Column guide:

| Column | Meaning |
| --- | --- |
| `*` | Active account |
| `5h:` | Remaining budget in the current 5-hour window |
| `week:` | Remaining budget for the current 7-day period |
| `reset: A / B` | Time until the 5h window resets / time until the weekly reset |

Color coding (applied to both `5h:` and `week:` values):

- 🟢 **green** — more than 60 % remaining
- ⬜ **default** — 11 – 60 % remaining
- 🟡 **yellow** — 1 – 10 % remaining
- 🔴 **red** — 0 % remaining (exhausted)

The Claude section is fetched automatically from the Anthropic API using the Claude Code keychain credentials (macOS only). Toggle it off with:

```bash
acc-sw configure show claude off
```

## Optional native menu-bar app

On macOS, build and install the SwiftUI menu-bar app:

```bash
make install PREFIX="$HOME/.local"
make install-macos-menu-app PREFIX="$HOME/.local"
make open-macos-menu-app
```

The native app runs as a menu-bar-only app. Its compact title shows each working plan's limiting budget, period, and reset shorthand, for example `chris wk26% 4d` or `claude 5h78% 4h`. Its SwiftUI popover shows active Codex and Claude summaries, per-account progress bars, reset times, projected pace, local usage sparklines, and a 30-day stacked cost chart with per-day hover breakdowns.

Use the Settings screen to choose which working plans appear in the closed menu-bar title. Hidden plans remain visible inside the popover.

Use the Actions screen to switch Codex accounts, save the current login, prepare a new login, rename saved accounts, or remove inactive saved accounts. Claude auth is currently shown as storage information only; profile switching is not automated yet.

The `x` button hides the popover. To quit the app, open the About screen from the header and use `Quit AI Usage Bar`.

Cost history is powered by [context-bar](https://github.com/htahaozlu/context-bar). For faster refreshes, install it once:

```bash
npm install -g context-bar
```

If `context-bar` is not installed, the app falls back to `npx context-bar@latest daily --json --instances` when `npx` is available.

## Optional SwiftBar widget

On macOS, install [SwiftBar](https://github.com/swiftbar/SwiftBar), then install the plugin:

```bash
brew install swiftbar
make install PREFIX="$HOME/.local"
make install-swiftbar-widget
```

`make install-swiftbar-widget` installs into SwiftBar's configured plugin folder when one is already set, otherwise it uses `~/SwiftBarPlugins`. The widget opens from cached usage immediately, warms a fresh snapshot in the background, and shows all saved Codex accounts plus Claude usage. The title and account rows are colored by projected burn pace: red if the current pace empties before reset, orange if it is tight, green if it is comfortably on track.

## Docs

- [Installation](docs/installation.md)
- [Usage](docs/usage.md)
- [Claude auth notes](docs/claude-auth.md)

## Notes

- The public command name is `codex-account-switch`; `acc-sw` is the short alias.
- `status` is the primary display command; `list` is kept as a backward-compatible alias.
- Standard install path: `make install`.
- The one-line installer downloads a tagged GitHub release and runs `make install`.

## License

MIT. See [LICENSE](LICENSE).
