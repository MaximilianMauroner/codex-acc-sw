# Installation

## Requirements

- `bash`
- `make`
- `python3`
- OpenAI Codex CLI installed and working
- At least one successful `codex login`
- Optional for the native menu-bar app: Swift toolchain / Xcode command line tools
- Optional for native app cost history: an installed `context-bar` executable
- Optional for the script-only menu-bar widget: [SwiftBar](https://github.com/swiftbar/SwiftBar)

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

## Optional native menu-bar app

The native app is a small SwiftUI menu-bar app that uses the installed `codex-account-switch` command as its usage data source.

Build, install, and open it:

```bash
make install PREFIX="$HOME/.local"
make install-macos-menu-app PREFIX="$HOME/.local"
make open-macos-menu-app
```

By default, the app is installed to:

```text
~/Applications/AI Usage Bar.app
```

Use a different install location:

```bash
make install-macos-menu-app PREFIX="$HOME/.local" MACOS_APP_INSTALL_DIR="/Applications"
```

Uninstall the app:

```bash
make uninstall-macos-menu-app
```

The app runs without a Dock icon and stores its local sparkline history at:

```text
~/Library/Application Support/AIUsageBar/history.json
```

Its 30-day cost history is powered by [context-bar](https://github.com/htahaozlu/context-bar). Install it globally:

```bash
npm install -g context-bar
```

The app does not invoke `npx` or download a package automatically. It requires an installed `context-bar` executable. Set `CONTEXT_BAR_BIN=/path/to/context-bar` before launching the app to select a specific binary.

## Optional SwiftBar widget

Install SwiftBar:

```bash
brew install swiftbar
```

Install `codex-account-switch`, then install the widget plugin:

```bash
make install PREFIX="$HOME/.local"
make install-swiftbar-widget
```

By default, the plugin is installed to:

```text
<SwiftBar PluginDirectory>/ai-usage.1m.sh
```

If SwiftBar already has a configured plugin folder, `make install-swiftbar-widget` detects it automatically. Otherwise it installs to `~/SwiftBarPlugins`; when SwiftBar asks for its plugin folder, choose that folder.

If your SwiftBar plugin folder is elsewhere:

```bash
make install-swiftbar-widget SWIFTBAR_PLUGIN_DIR="$HOME/path/to/SwiftBar Plugins"
```

Uninstall the widget plugin:

```bash
make uninstall-swiftbar-widget
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
| `SWIFTBAR_PLUGIN_DIR` | SwiftBar `PluginDirectory`, otherwise `~/SwiftBarPlugins` | SwiftBar plugin install directory |
| `MACOS_APP_INSTALL_DIR` | `~/Applications` | Native menu-bar app install directory |
