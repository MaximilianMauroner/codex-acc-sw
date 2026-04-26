# codex-acc-sw

`codex-account-switch` (short alias: `acc-sw`) is a small Unix-style helper for switching between multiple OpenAI Codex CLI accounts and checking live usage at a glance.

## What it does

- Saves one Codex login per account name
- Switches accounts by replacing only `~/.codex/auth.json` — nothing else is touched
- Shows live usage for every saved account in a single aligned table
- Shows both the 5-hour window reset and the weekly reset side by side
- Color-codes usage percentages (green → yellow → red as budget depletes)
- Optionally shows Claude Code usage in the same table (macOS, auto-detected)

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/MaximilianMauroner/codex-acc-sw/main/install.sh | bash
```

Save your current login, add a second account, then check status:

```bash
codex-account-switch save main
codex-account-switch add second   # logs out, run: codex login && acc-sw save second
acc-sw status
```

Switch accounts instantly:

```bash
acc-sw second
acc-sw main
```

## Output

```
$ acc-sw status
── codex ───────────────────────────────────────────────
* main    5h: 100%  week:   0%  reset: 4h59m / 2d1h
  second  5h:   0%  week:   1%  reset: 49m   / 2d13h
  fourth  5h:   0%  week:  69%  reset: 3h53m / 6d16h
── claude ──────────────────────────────────────────────
  claude  5h:  55%  week:  70%  reset: 2h15m / 4d3h
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

The Claude section is fetched automatically from the Anthropic API using the Claude Code keychain credentials (macOS only). Toggle it with:

```bash
acc-sw configure show claude off
```

## Docs

- [Installation](docs/installation.md)
- [Usage](docs/usage.md)

## Notes

- The public command name is `codex-account-switch`; `acc-sw` is the short alias.
- `status` is the primary display command; `list` is kept as a backward-compatible alias.
- Standard install path: `make install`.
- The one-line installer downloads a tagged GitHub release and runs `make install`.

## License

MIT. See [LICENSE](LICENSE).
