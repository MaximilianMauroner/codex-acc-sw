# codex-acc-sw

`codex-account-switch` is a small Unix-style helper for switching between multiple OpenAI Codex CLI accounts without repeatedly logging in and out.

## What it does

- Saves one Codex login per account name
- Switches accounts by replacing only `~/.codex/auth.json`
- Leaves the rest of `~/.codex` alone
- Shows live usage for saved accounts
- Shows the next reset time in a compact format
- Collapses free-tier accounts to `free plan`

## Quick start

Install the latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/MaximilianMauroner/codex-acc-sw/main/install.sh | bash
```

Save the current login:

```bash
codex-account-switch save main
```

List saved accounts:

```bash
codex-account-switch list
```

Switch accounts:

```bash
codex-account-switch second
codex-account-switch main
```

## Docs

- [Installation](docs/installation.md)
- [Usage](docs/usage.md)

## Notes

- The public command name is `codex-account-switch`.
- `acc-sw` is an optional short alias.
- The standard install path is `make install`.
- The one-line installer downloads a tagged GitHub release and runs `make install`.

## License

MIT. See [LICENSE](LICENSE).
