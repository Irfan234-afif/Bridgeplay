#!/bin/bash
# Bridgeplay one-click installer.
# Copies Bridgeplay, Apple's Game Porting Toolkit (D3DMetal), the WineCX engine (no download)
# and the default configs, then opens Bridgeplay, whose Setup Assistant does the rest:
# Rosetta, Steam, sign-in, the App Management permission and the Steam setup.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
support="$HOME/Library/Application Support/notproton"

say()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mGagal:\033[0m %s\n' "$*" >&2; read -r -p "Tekan Enter untuk menutup..." _; exit 1; }

xattr -dr com.apple.quarantine "$here" 2>/dev/null || true

[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] || die "Mac ini bukan Apple Silicon (M1/M2/M3/...). Bridgeplay tidak jalan di Mac Intel."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || die "Butuh macOS 26 atau lebih baru (sekarang $(sw_vers -productVersion)). Update macOS dulu."

say "Memasang Bridgeplay..."
osascript -e 'tell application id "com.bridgeplay.Bridgeplay" to quit' >/dev/null 2>&1 || true
rm -rf /Applications/Bridgeplay.app
ditto "$here/Bridgeplay.app" /Applications/Bridgeplay.app || die "Bridgeplay gagal disalin ke Applications."
xattr -dr com.apple.quarantine /Applications/Bridgeplay.app 2>/dev/null || true

if [ ! -d /Applications/Steam.app ]; then
    say "Memasang Steam..."
    mnt="$(mktemp -d)"
    hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mnt" "$here/steam.dmg" || die "Installer Steam tidak bisa dibuka."
    ditto "$mnt/Steam.app" /Applications/Steam.app; ok=$?
    hdiutil detach -quiet "$mnt" 2>/dev/null; rmdir "$mnt" 2>/dev/null
    [ $ok -eq 0 ] || die "Steam gagal disalin ke Applications."
    xattr -dr com.apple.quarantine /Applications/Steam.app 2>/dev/null || true
fi

say "Menyalin Game Porting Toolkit, engine WineCX dan config (tanpa download)..."
mkdir -p "$support/gamefixes" "$HOME/Library/Caches/notproton"
rm -rf "$support/gptk"
ditto "$here/gptk" "$support/gptk" || die "Game Porting Toolkit gagal disalin."
# Bridgeplay reuses any cached file whose hash matches its pin, so nothing is downloaded.
ditto "$here/cache" "$HOME/Library/Caches/notproton" || die "File engine gagal disalin."
# default.conf is always the bundled one (an existing different copy is kept as .bak);
# per-game confs the user already has are left alone.
if [ -f "$support/gamefixes/default.conf" ] && ! cmp -s "$here/config/gamefixes/default.conf" "$support/gamefixes/default.conf"; then
    cp "$support/gamefixes/default.conf" "$support/gamefixes/default.conf.bak"
fi
cp "$here/config/gamefixes/default.conf" "$support/gamefixes/default.conf"
cp -n "$here/config/gamefixes/"*.conf "$support/gamefixes/" 2>/dev/null || true
cp -n "$here/config/gamecontrollerdb.txt" "$support/" 2>/dev/null || true
xattr -dr com.apple.quarantine "$support" 2>/dev/null || true
# Show the Setup Assistant again even if an earlier Bridgeplay was dismissed.
defaults delete com.bridgeplay.Bridgeplay setupAssistantFinished >/dev/null 2>&1 || true

say "Selesai. Bridgeplay terbuka, ikuti Setup Assistant-nya."
open /Applications/Bridgeplay.app
sleep 2
osascript -e 'tell application "Terminal" to close (every window whose name contains "Install.command")' >/dev/null 2>&1 &
exit 0
