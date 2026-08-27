PREFIX ?= /usr/local
DESTDIR ?=
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/libexec/codex-account-switch
INSTALL_ALIAS ?= 0
SWIFTBAR_CONFIGURED_PLUGIN_DIR := $(shell defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null)
SWIFTBAR_PLUGIN_DIR ?= $(if $(SWIFTBAR_CONFIGURED_PLUGIN_DIR),$(SWIFTBAR_CONFIGURED_PLUGIN_DIR),$(HOME)/SwiftBarPlugins)

INSTALL ?= install
LN_SFN ?= ln -sfn

SCRIPT_SRC = codex-accounts.sh
HELPER_SRC = scripts/fetch_codex_rate_limits.py
SWIFTBAR_PLUGIN_SRC = plugins/swiftbar/ai-usage.1m.sh
MACOS_APP_SRC_DIR = apps/AIUsageBar
MACOS_APP_EXECUTABLE = AIUsageBar
MACOS_APP_BUNDLE_NAME = AI Usage Bar.app
MACOS_APP_BUILD_ROOT = $(CURDIR)/build/macos
MACOS_APP_BUNDLE = $(MACOS_APP_BUILD_ROOT)/$(MACOS_APP_BUNDLE_NAME)
MACOS_APP_INSTALL_DIR ?= $(HOME)/Applications

SCRIPT_DST = $(DESTDIR)$(LIBEXECDIR)/codex-accounts.sh
HELPER_DST = $(DESTDIR)$(LIBEXECDIR)/scripts/fetch_codex_rate_limits.py
COMMAND_DST = $(DESTDIR)$(BINDIR)/codex-account-switch
ALIAS_DST = $(DESTDIR)$(BINDIR)/acc-sw
SWIFTBAR_PLUGIN_DST = $(SWIFTBAR_PLUGIN_DIR)/ai-usage.1m.sh
MACOS_APP_INSTALL_DST = $(MACOS_APP_INSTALL_DIR)/$(MACOS_APP_BUNDLE_NAME)

.PHONY: all test install uninstall install-swiftbar-widget uninstall-swiftbar-widget build-macos-menu-app install-macos-menu-app open-macos-menu-app uninstall-macos-menu-app

all:
	@echo "Nothing to build. Use 'make install'."

test:
	bash tests/regression.sh

install:
	$(INSTALL) -d "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(LIBEXECDIR)/scripts"
	$(INSTALL) -m 755 "$(SCRIPT_SRC)" "$(SCRIPT_DST)"
	$(INSTALL) -m 644 "$(HELPER_SRC)" "$(HELPER_DST)"
	$(LN_SFN) "$(SCRIPT_DST)" "$(COMMAND_DST)"
	@if [ "$(INSTALL_ALIAS)" = "1" ]; then \
		$(LN_SFN) "$(COMMAND_DST)" "$(ALIAS_DST)"; \
	fi

uninstall:
	rm -f "$(COMMAND_DST)" "$(ALIAS_DST)"
	rm -f "$(SCRIPT_DST)" "$(HELPER_DST)"
	rmdir "$(DESTDIR)$(LIBEXECDIR)/scripts" 2>/dev/null || true
	rmdir "$(DESTDIR)$(LIBEXECDIR)" 2>/dev/null || true

install-swiftbar-widget:
	$(INSTALL) -d "$(SWIFTBAR_PLUGIN_DIR)"
	$(INSTALL) -m 755 "$(SWIFTBAR_PLUGIN_SRC)" "$(SWIFTBAR_PLUGIN_DST)"

uninstall-swiftbar-widget:
	rm -f "$(SWIFTBAR_PLUGIN_DST)"

build-macos-menu-app:
	cd "$(MACOS_APP_SRC_DIR)" && swift build -c release
	rm -rf "$(MACOS_APP_BUNDLE)"
	$(INSTALL) -d "$(MACOS_APP_BUNDLE)/Contents/MacOS" "$(MACOS_APP_BUNDLE)/Contents/Resources"
	$(INSTALL) -m 755 "$(MACOS_APP_SRC_DIR)/.build/release/$(MACOS_APP_EXECUTABLE)" "$(MACOS_APP_BUNDLE)/Contents/MacOS/$(MACOS_APP_EXECUTABLE)"
	$(INSTALL) -m 644 "$(MACOS_APP_SRC_DIR)/Info.plist" "$(MACOS_APP_BUNDLE)/Contents/Info.plist"
	printf 'APPL????' > "$(MACOS_APP_BUNDLE)/Contents/PkgInfo"
	codesign --force --sign - "$(MACOS_APP_BUNDLE)" >/dev/null 2>&1 || true

install-macos-menu-app: install build-macos-menu-app
	$(INSTALL) -d "$(MACOS_APP_INSTALL_DIR)"
	rm -rf "$(MACOS_APP_INSTALL_DST)"
	cp -R "$(MACOS_APP_BUNDLE)" "$(MACOS_APP_INSTALL_DST)"

open-macos-menu-app:
	open -g "$(MACOS_APP_INSTALL_DST)"

uninstall-macos-menu-app:
	rm -rf "$(MACOS_APP_INSTALL_DST)"
