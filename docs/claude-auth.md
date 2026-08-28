# Claude Auth Notes

Local findings on macOS, gathered without printing credential values:

- Claude Code usage works from a macOS Keychain generic-password item.
- The Keychain service is `Claude Code-credentials`.
- The item is in the login keychain and its account is the local macOS user.
- The stored secret is a JSON payload. The usage code reads `claudeAiOauth.accessToken` from that payload.
- Claude Code metadata is also present in `~/.claude.json`, especially `oauthAccount`.
- The Claude desktop app keeps OAuth cache entries in `~/Library/Application Support/Claude/config.json`, including `oauth:tokenCache` and `oauth:tokenCacheV2`.

The current app only reads Claude usage. It does not switch Claude profiles.

Future Claude profile switching would need to save and restore at least the Keychain credential payload. It may also need to snapshot related metadata from `~/.claude.json`, depending on which fields Claude Code expects after a login changes. That should be implemented as an explicit opt-in flow with backups and no credential printing.
