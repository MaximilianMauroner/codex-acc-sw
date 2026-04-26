# Installation

## Requirements

- `bash`
- `make`
- `python3`
- OpenAI Codex CLI installed and working
- At least one successful `codex login`

Install Codex CLI if needed:

- macOS: `brew install codex`
- otherwise: follow the official [Codex CLI docs](https://developers.openai.com/codex/cli/)

## One-line install

Latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/MaximilianMauroner/codex-acc-sw/main/install.sh | bash
```

Install with the `acc-sw` alias:

```bash
curl -fsSL https://raw.githubusercontent.com/MaximilianMauroner/codex-acc-sw/main/install.sh | bash -s -- --alias
```

Install a specific tagged release:

```bash
curl -fsSL https://raw.githubusercontent.com/MaximilianMauroner/codex-acc-sw/main/install.sh | bash -s -- --version v0.2.1
```

## Manual install

Clone the repository:

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

Package or stage files with `DESTDIR`:

```bash
make install PREFIX=/usr/local DESTDIR="$PWD/stage"
```

Run directly from the repository without installing:

```bash
./codex-accounts.sh
```

## Install variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `PREFIX` | `/usr/local` | Base install prefix |
| `DESTDIR` | empty | Staging root for packaging |
| `BINDIR` | `$(PREFIX)/bin` | Command install directory |
| `LIBEXECDIR` | `$(PREFIX)/libexec/codex-account-switch` | Private helper/script directory |
| `INSTALL_ALIAS` | `0` | Set to `1` to install `acc-sw` |
