# Security

Bridgeplay loads code into the Steam client and into games, re-signs Steam, and updates
itself with a signed Sparkle feed. Please report anything that could let someone else run
code through it, read Steam data, or ship a bad update.

## Reporting

Report privately through GitHub: **Security › Report a vulnerability** on
https://github.com/raymondchins/Bridgeplay/security. Please don't open a public issue for a
security problem.

Include what you found, how to reproduce it, and which Bridgeplay version (Status page) and
macOS version you used. You will get a reply within a week. Fixes ship as a normal Sparkle
update, and the release notes credit you unless you prefer not.

## Scope

In scope: the app, `notproton.dylib` and the run script, the installer, the update feed and
the shipped Wine patches.

Out of scope: Steam, Wine/WineCX, DXMT, DXVK and Apple's Game Porting Toolkit themselves;
report those upstream. Anything that needs an attacker who already runs code as your macOS
user is a hardening request, not a vulnerability, but it is still welcome as an issue.

## Known trade-offs

- Bridgeplay releases are signed with a self-signed certificate (no Apple Developer ID)
  and not notarized, and the installer removes the download's
  quarantine flag. Download it only from https://bridgeplay.dev or the GitHub releases.
- Steam is re-signed so it can load Bridgeplay, which removes Valve's hardened runtime.
- Updates are verified with an EdDSA signature (`SUPublicEDKey`) before they are installed.
