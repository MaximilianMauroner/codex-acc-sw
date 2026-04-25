PREFIX ?= /usr/local
DESTDIR ?=
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/libexec/codex-account-switch
INSTALL_ALIAS ?= 0

INSTALL ?= install
LN_SFN ?= ln -sfn

SCRIPT_SRC = codex-accounts.sh
HELPER_SRC = scripts/fetch_codex_rate_limits.py

SCRIPT_DST = $(DESTDIR)$(LIBEXECDIR)/codex-accounts.sh
HELPER_DST = $(DESTDIR)$(LIBEXECDIR)/scripts/fetch_codex_rate_limits.py
COMMAND_DST = $(DESTDIR)$(BINDIR)/codex-account-switch
ALIAS_DST = $(DESTDIR)$(BINDIR)/acc-sw

.PHONY: all install uninstall

all:
	@echo "Nothing to build. Use 'make install'."

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
