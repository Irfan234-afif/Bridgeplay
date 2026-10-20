# Installer

`Install.command` installs the app, Apple's Game Porting Toolkit, the WineCX engine and the
default configs from the folder it sits in, downloads Steam from Valve's CDN when
`/Applications/Steam.app` is missing, then opens the app's Setup Assistant.

Build the zip with:

    make app
    scripts/package-installer.sh      # writes out/Bridgeplay-Installer.zip

The script stages `out/installer/Bridgeplay/` and fails if a piece is missing or an engine
archive does not match its pin in `FreeEngine*.swift`:

| Path in the zip | Source |
|---|---|
| `Bridgeplay.app` | `out/Bridgeplay.app` from `make app` |
| `Install.command`, `BACA DULU.txt`, `README.txt`, `config/` | this folder |
| `LICENSE`, `LICENSE.*`, `NOTICE` | repository root |
| `gptk/` | `~/Library/Application Support/bridgeplay/gptk` (`redist/lib` of Apple's Game Porting Toolkit DMG) |
| `GPTK-License.rtf` | `gptk/License.rtf` from the same DMG |
| `cache/engines/` | the pinned WineCX runtime, DXMT and DXVK archives from `~/Library/Caches/bridgeplay/engines` |

On a Mac the app has not migrated to 3.0.0 yet, the script falls back to the old
`notproton` folders. `Install.command` installs into the `bridgeplay` folders. When only the
old `notproton` folders exist, it writes into those instead and leaves the move to the app,
which migrates them on first launch.

Never shipped: Valve's Steam client and the Steam packages in `valve-packages/` (the app
downloads those from Valve's CDN), and GPTK is never committed. GPTK's `/redist` files are
Apple software that Apple allows to be redistributed for non-commercial use only; Bridgeplay
is free and non-commercial.

`BACA DULU.txt` (Indonesian) and `README.txt` (English) are the user guides in the zip. macOS
15 and later no longer opens unsigned scripts from right-click > Open, so step 1 sends users to
System Settings > Privacy & Security > Open Anyway.
