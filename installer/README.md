# Installer

`Install.command` installs the app, Apple's Game Porting Toolkit, the WineCX engine and the
default configs from the folder it sits in, then opens the app's Setup Assistant.

Assembled next to it at packaging time, never committed:

| Path | Source |
|---|---|
| `NotProton.app` | `build/NotProton.app` from `scripts/build-local.sh` |
| `gptk/` | `redist/lib` of Apple's Game Porting Toolkit DMG (Apple license, non-commercial) |
| `GPTK-License.rtf` | From the same DMG |
| `cache/` | `~/Library/Caches/notproton` after an engine install (files matching the pins) |
| `steam.dmg` | Valve's macOS Steam installer |

`config/` holds the bundled `gamefixes` and `gamecontrollerdb.txt`. `BACA DULU.txt` is the
user guide shipped in the zip.
