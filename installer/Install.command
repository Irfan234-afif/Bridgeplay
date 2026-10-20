#!/bin/bash
# Bridgeplay one-click installer.
# Copies Bridgeplay, Apple's Game Porting Toolkit (D3DMetal), the WineCX engine (no download)
# and the default configs, installs Steam from Valve's CDN when it is missing, then opens
# Bridgeplay, whose Setup Assistant does the rest: Rosetta, sign-in, the App Management
# permission and the Steam setup. Assembled into a zip by scripts/package-installer.sh.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
support="$HOME/Library/Application Support/bridgeplay"
caches="$HOME/Library/Caches/bridgeplay"
# Bridgeplay before 3.0.0 kept its files under "notproton". The app moves them to
# "bridgeplay" itself on first launch (with a backup), so the installer never moves them.
# While only the old folders exist, it writes into them so that move carries the new
# files along; a bridgeplay folder made next to them would get in the migration's way.
legacy_support="$HOME/Library/Application Support/notproton"
legacy_caches="$HOME/Library/Caches/notproton"
migrate_later=0
if [ ! -d "$support" ] && [ -d "$legacy_support" ]; then
    support="$legacy_support"
    migrate_later=1
fi
if [ ! -d "$caches" ] && [ -d "$legacy_caches" ]; then
    caches="$legacy_caches"
    migrate_later=1
fi

say()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mGagal:\033[0m %s\n' "$*" >&2; read -r -p "Tekan Enter untuk menutup..." _; exit 1; }

# Valve's official macOS Steam installer, and the Team ID Valve signs Steam.app with.
steam_url="https://cdn.cloudflare.steamstatic.com/client/installer/steam.dmg"
valve_team="MXGJJ98X76"
steam_tmp=""
steam_mnt=""
# shellcheck disable=SC2329 # runs from the EXIT trap
cleanup() {
    if [ -n "$steam_mnt" ]; then hdiutil detach -quiet "$steam_mnt" >/dev/null 2>&1; fi
    if [ -n "$steam_tmp" ]; then rm -rf "$steam_tmp"; fi
    return 0
}
trap cleanup EXIT

xattr -dr com.apple.quarantine "$here" 2>/dev/null || true

[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] || die "Mac ini bukan Apple Silicon (M1/M2/M3/...). Bridgeplay tidak jalan di Mac Intel."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || die "Butuh macOS 26 atau lebih baru (sekarang $(sw_vers -productVersion)). Update macOS dulu."
[ -w /Applications ] || die "Akun ini tidak bisa menulis ke folder Applications. Login dengan akun admin, lalu jalankan Install.command lagi."
[ -d "$here/Bridgeplay.app" ] || die "Bridgeplay.app tidak ada di folder installer. Ekstrak ulang zip-nya, lalu coba lagi."

say "Memasang Bridgeplay..."
osascript -e 'tell application id "com.bridgeplay.Bridgeplay" to quit' >/dev/null 2>&1 || true
rm -rf /Applications/Bridgeplay.app
ditto "$here/Bridgeplay.app" /Applications/Bridgeplay.app || die "Bridgeplay gagal disalin ke Applications."
xattr -dr com.apple.quarantine /Applications/Bridgeplay.app 2>/dev/null || true

if [ ! -d /Applications/Steam.app ]; then
    say "Steam belum terpasang. Mengunduh installer Steam resmi dari Valve..."
    steam_tmp="$(mktemp -d)" || die "Folder sementara tidak bisa dibuat."
    dmg="$steam_tmp/steam.dmg"
    curl -fL --retry 3 --connect-timeout 20 --progress-bar -o "$dmg" "$steam_url" \
        || die "Steam gagal diunduh. Pastikan Mac tersambung ke internet, lalu jalankan Install.command lagi."
    # A UDIF disk image ends with a 512-byte trailer that starts with "koly".
    [ "$(tail -c 512 "$dmg" | head -c 4)" = "koly" ] \
        || die "File yang diunduh bukan installer Steam (bukan DMG). Coba lagi nanti."
    say "Memasang Steam..."
    steam_mnt="$steam_tmp/mnt"
    mkdir "$steam_mnt"
    hdiutil attach -nobrowse -readonly -noautoopen -quiet -mountpoint "$steam_mnt" "$dmg" </dev/null \
        || { steam_mnt=""; die "Installer Steam tidak bisa dibuka."; }
    if ! codesign --verify --strict "$steam_mnt/Steam.app" 2>/dev/null \
        || ! codesign -dv "$steam_mnt/Steam.app" 2>&1 | grep -qx "TeamIdentifier=$valve_team"; then
        die "Steam yang diunduh tidak ditandatangani Valve. Instalasi dibatalkan."
    fi
    ditto "$steam_mnt/Steam.app" /Applications/Steam.app || die "Steam gagal disalin ke Applications."
    hdiutil detach -quiet "$steam_mnt" >/dev/null 2>&1
    steam_mnt=""
    xattr -dr com.apple.quarantine /Applications/Steam.app 2>/dev/null || true
fi

say "Menyalin Game Porting Toolkit, engine WineCX dan config (tanpa download)..."
if [ "$migrate_later" -eq 1 ]; then
    say "Data Bridgeplay lama ditemukan di folder notproton. File baru ditaruh di sana dulu; Bridgeplay memindahkannya ke folder bridgeplay saat pertama dibuka (tutup Steam dan game dulu)."
fi
mkdir -p "$support/gamefixes" "$caches"
rm -rf "$support/gptk"
ditto "$here/gptk" "$support/gptk" || die "Game Porting Toolkit gagal disalin."
# Bridgeplay reuses any cached file whose hash matches its pin, so nothing is downloaded.
ditto "$here/cache" "$caches" || die "File engine gagal disalin."
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
