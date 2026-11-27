# Security policy

Diskward deletes files, so the most serious bugs are ones where it could remove something it shouldn't. Examples:

- a path outside your home folder, or a protected folder (Documents, Keychains, `~/.ssh`, iCloud Drive)
- a symlink trick that redirects a delete
- something cleaned without the confirmation sheet
- a cleanup rule selecting the wrong items

## Reporting

**Please don't open a public issue for these.** Report privately via
[GitHub security advisories](https://github.com/gustavopaixao/diskward/security/advisories/new).

Please include the macOS version, the Diskward version, the source or rule involved, and the relevant lines from `~/Library/Logs/StorageHelper/cleanup.log` (remove anything private).

You'll get a reply within a few days. Fixes for confirmed issues are released as soon as possible, with credit to you if you'd like.

## Supported versions

Only the latest release gets security fixes.
