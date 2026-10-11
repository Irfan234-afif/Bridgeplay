#!/bin/sh
# notproton CrossOver compatibility tool shim
set -e

verb="$1"
shift || true

# hook_launch.c passes the launch options through a shell before this script runs, matching
# Linux Steam. A NAME=value option placed ahead of %command% is an environment variable,
# and anything after %command% is a launch argument passed to the game.
launch_args="$*"

case "$verb" in
  getcompatpath)
    printf '%s\n' "$STEAM_COMPAT_DATA_PATH"
    exit 0
    ;;
esac

np_support="$HOME/Library/Application Support/notproton"
# cxcompatdb resolves its database through CX_HOME and logs an error for
# every module loaded without it :(
export CX_HOME="$HOME/Library/Application Support/CrossOver"
np_flavor=""
np_build=""
CDPATH=''
np_tool_dir=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || np_tool_dir=""
if [ -n "$np_tool_dir" ] && [ -r "$np_tool_dir/flavor" ]; then
  read -r np_flavor < "$np_tool_dir/flavor" || np_flavor=""
fi
if [ -n "$np_tool_dir" ] && [ -r "$np_tool_dir/build" ]; then
  read -r np_build < "$np_tool_dir/build" || np_build=""
fi
case "$np_build" in *[!A-Za-z0-9.-]*) np_build="" ;; esac
np_display=$(sed -n 's/.*"display_name"[[:space:]]*"\(.*\)".*/\1/p' \
  "$np_tool_dir/compatibilitytool.vdf" 2>/dev/null | head -1) || np_display=""
[ -n "$np_display" ] || np_display="CrossOver build ${np_build:-unknown}"
CX_ROOT="$np_support/runners/crossover-$np_build/CrossOver"
export CX_ROOT
# CrossOver initializes Rosetta's Windows thread-state support even without D3DMetal.
if [ -f "$CX_ROOT/lib64/apple_gptk/external/libd3dshared.dylib" ]; then
  export CX_APPLEGPTK_LIBD3DSHARED_PATH="$CX_ROOT/lib64/apple_gptk/external/libd3dshared.dylib"
fi
# WineCX with a Game Porting Toolkit linked in keeps libd3dshared in its own lib/external.
if [ -z "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}" ] \
  && [ -f "$CX_ROOT/lib/notproton-backends/d3dmetal.enabled" ] \
  && [ -f "$CX_ROOT/lib/external/libd3dshared.dylib" ]; then
  export CX_APPLEGPTK_LIBD3DSHARED_PATH="$CX_ROOT/lib/external/libd3dshared.dylib"
fi

wine_unix="$CX_ROOT/lib/wine/aarch64-unix"
WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
WINESERVER="$CX_ROOT/bin/wineserver-arm64"
if [ "$np_flavor" = rosetta ] || [ ! -x "$WINELOADER" ] || [ ! -x "$WINESERVER" ]; then
  wine_unix="$CX_ROOT/lib/wine/x86_64-unix"
  WINELOADER="$wine_unix/wine"
  WINESERVER="$CX_ROOT/bin/wineserver"
  [ -x "$WINESERVER" ] || WINESERVER="$CX_ROOT/bin/wineserver-x86"
fi
export WINELOADER WINESERVER

# Keeps Wine from inheriting the prefix and template locks (fd 8 and 9).
without_lock_fds() {
  "$@" 8>&- 9>&-
}

# If two WINEDLLPATH directories have the same DLL, Wine uses the one listed first.
export WINEDLLPATH="$CX_ROOT/lib/wine/x86_64-windows:$wine_unix${WINEDLLPATH:+:$WINEDLLPATH}"
export PATH="$CX_ROOT/bin:$PATH"

if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
  log="$STEAM_COMPAT_DATA_PATH/notproton-run.log"
else
  log=/dev/null
fi
[ "$(stat -f %z "$log" 2>/dev/null || echo 0)" -gt 262144 ] \
  && : > "$log" || true
{
  echo "=== notproton run $(date) ==="
  echo "verb=$verb"
  echo "args:"; for a in "$@"; do printf '  [%s]\n' "$a"; done
  echo "cwd=$(pwd)"
  echo "STEAM_COMPAT_DATA_PATH=$STEAM_COMPAT_DATA_PATH"
  echo "STEAM_COMPAT_INSTALL_PATH=$STEAM_COMPAT_INSTALL_PATH"
  echo "STEAM_COMPAT_APP_ID=$STEAM_COMPAT_APP_ID"
  echo "-- steam env passed through --"
  env | grep -iE '^(Steam|SDL_)' | sort
} >> "$log" 2>&1 || true

# Wine keeps its server socket in <tmp>/.wine-<uid> and the wineserver refuses to start when
# others can read it ("must not be accessible by other users"). A directory of ours with a
# looser mode goes back to 0700. A link, or a directory someone else owns, is only reported:
# it is never followed or changed.
heal_wine_tmp() {
  wine_tmp="$1/.wine-$(id -u)"
  if [ -L "$wine_tmp" ]; then
    echo "=== warning: $wine_tmp is a symlink, left alone; wineserver may refuse to start ===" >> "$log" 2>&1 || true
    return 0
  fi
  [ -e "$wine_tmp" ] || return 0
  wine_tmp_info=$(stat -f '%u %Lp %HT' "$wine_tmp" 2>/dev/null) || return 0
  wine_tmp_owner=${wine_tmp_info%% *}
  wine_tmp_rest=${wine_tmp_info#* }
  wine_tmp_mode=${wine_tmp_rest%% *}
  wine_tmp_type=${wine_tmp_rest#* }
  if [ "$wine_tmp_type" != Directory ]; then
    echo "=== warning: $wine_tmp is not a directory ($wine_tmp_type), left alone ===" >> "$log" 2>&1 || true
    return 0
  fi
  if [ "$wine_tmp_owner" != "$(id -u)" ]; then
    echo "=== warning: $wine_tmp belongs to uid $wine_tmp_owner, left alone; wineserver may refuse to start ===" >> "$log" 2>&1 || true
    return 0
  fi
  [ "$wine_tmp_mode" != 700 ] || return 0
  # -h: should the directory have been swapped for a link since the checks, the link
  # itself changes, never what it points at.
  if chmod -h 700 "$wine_tmp" 2>> "$log"; then
    echo "=== $wine_tmp was mode $wine_tmp_mode, set to 700 ===" >> "$log" 2>&1 || true
  else
    echo "=== warning: could not set $wine_tmp to mode 700 ===" >> "$log" 2>&1 || true
  fi
}
heal_wine_tmp /tmp

stage_step="startup"
# shellcheck disable=SC2329 # the trap below invokes this
report_early_exit() {
  status=$?
  [ "$status" = 0 ] && return 0
  echo "=== aborted during $stage_step (exit $status) before launch ===" \
    >> "$log" 2>&1 || true
}
trap report_early_exit EXIT

while :; do
  case "$STEAM_COMPAT_INSTALL_PATH" in
    ?*/) STEAM_COMPAT_INSTALL_PATH="${STEAM_COMPAT_INSTALL_PATH%/}" ;;
    *) break ;;
  esac
done
export STEAM_COMPAT_INSTALL_PATH

app_id="$STEAM_COMPAT_APP_ID"
case "$app_id" in ''|0) app_id="$SteamAppId" ;; esac
case "$app_id" in ''|0) app_id=$(basename "$STEAM_COMPAT_DATA_PATH" 2>/dev/null) ;; esac
case "$app_id" in ''|*[!0-9]*) app_id=0 ;; esac
echo "app_id=$app_id (STEAM_COMPAT_APP_ID=$STEAM_COMPAT_APP_ID)" >> "$log" 2>&1 || true

# SDL has no built-in mapping for some pads (GameSir G7 Pro dongle, 3537:1022), so
# winebus hands games their raw button order. Mappings in gamecontrollerdb.txt reach
# winebus through the environment; its registry "map" loader crashes in this Wine.
# macOS Steam has no virtual gamepad Wine could read, so a pad Steam Input claims (and
# lists in SDL_GAMECONTROLLER_IGNORE_DEVICES) would reach the game as nothing. Games read
# pads directly unless the launch options set NOTPROTON_RAW_CONTROLLERS=0.
if [ "${NOTPROTON_RAW_CONTROLLERS:-1}" = "1" ]; then
  NOTPROTON_RAW_CONTROLLERS=1
  SDL_GAMECONTROLLER_IGNORE_DEVICES=
  export NOTPROTON_RAW_CONTROLLERS SDL_GAMECONTROLLER_IGNORE_DEVICES
fi

# SDL hands pads that macOS GameController.framework knows (GameSir G7 Pro over Bluetooth)
# to its MFi driver, which finds nothing outside an app run loop such as winedevice.exe's,
# so the pad never reached Wine. IOKit reads them instead.
SDL_JOYSTICK_MFI=0
export SDL_JOYSTICK_MFI

# The full database, gamecontrollerdb.merged.txt from scripts/update-gamecontrollerdb.sh
# (~90 KB), reaches SDL as a file: SDL_Init reads SDL_GAMECONTROLLERCONFIG_FILE (SDL 2.0.22+),
# then the variable's lines, which outrank the file's. Only the hand-written lines ride in
# the variable, which every Wine process inherits. A runner SDL without the hint gets the
# database in the variable instead. The variable keeps the last line per GUID, newest
# first, up to pad_cap bytes.
np_pad_mappings() {
  pad_db="$np_support/gamecontrollerdb.txt"
  pad_full="$np_support/gamecontrollerdb.merged.txt"
  pad_sdl="$CX_ROOT/lib/libSDL2-2.0.0.dylib"
  pad_cap=32768
  pad_env_src=""
  if [ -f "$pad_full" ] && [ -z "$SDL_GAMECONTROLLERCONFIG_FILE" ]; then
    if [ -f "$pad_sdl" ] && LC_ALL=C grep -q -a SDL_GAMECONTROLLERCONFIG_FILE "$pad_sdl" 2>/dev/null; then
      SDL_GAMECONTROLLERCONFIG_FILE="$pad_full"
      export SDL_GAMECONTROLLERCONFIG_FILE
      echo "controllers: mapping file $pad_full" >> "$log" 2>&1 || true
    else
      pad_env_src="$pad_full"
      echo "controllers: $pad_sdl lacks SDL_GAMECONTROLLERCONFIG_FILE, $pad_full goes in the environment (capped)" >> "$log" 2>&1 || true
    fi
  fi
  [ -f "$pad_db" ] || pad_db=""
  [ -n "$pad_env_src$pad_db" ] || return 0
  # Last line per GUID, newest first until pad_cap bytes, printed in file order
  pad_maps=$(cat ${pad_env_src:+"$pad_env_src"} ${pad_db:+"$pad_db"} | tr -d '\r' \
    | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
    | awk -v cap="$pad_cap" '
      { line[NR] = $0 }
      END {
        for (i = NR; i >= 1; i--) {
          g = tolower(substr(line[i], 1, 32))
          if (g in seen) continue
          seen[g] = 1
          if (size + length(line[i]) + 1 > cap) { dropped++; continue }
          size += length(line[i]) + 1
          keep[i] = 1
        }
        for (i = 1; i <= NR; i++) if (i in keep) print line[i]
        if (dropped) printf "controllers: %d mapping(s) over the %d-byte cap dropped\n", dropped, cap > "/dev/stderr"
      }' 2>> "$log")
  [ -n "$pad_maps" ] || return 0
  if [ -n "$SDL_GAMECONTROLLERCONFIG" ]; then
    SDL_GAMECONTROLLERCONFIG="$SDL_GAMECONTROLLERCONFIG
$pad_maps"
  else
    SDL_GAMECONTROLLERCONFIG="$pad_maps"
  fi
  export SDL_GAMECONTROLLERCONFIG
  echo "controllers: $(printf '%s\n' "$pad_maps" | wc -l | tr -d ' ') mapping(s) in SDL_GAMECONTROLLERCONFIG from ${pad_env_src:+$pad_env_src }${pad_db}" >> "$log" 2>&1 || true
}
np_pad_mappings

# Per-game fixes: the shipped gamefixes-default/<appid>.conf, then the user's
# gamefixes/<appid>.conf, the later file winning per key. KEY=VALUE lines are checked
# against an allow-list and never sourced, and the launch options win over both files.
gamefix_keys=""
gamefix_backend=""
gamefix_dlloverrides=""
gamefix_msync=""
gamefix_nvapi=""
gamefix_args=""

gamefix_log() {
  echo "gamefix: $*" >> "$log" 2>&1 || true
}

# Wine syntax: name[,name...]=[n|b|n,b|b,n|d] entries joined by semicolons.
valid_dll_overrides() {
  rest=$1
  [ -n "$rest" ] || return 1
  while [ -n "$rest" ]; do
    entry=${rest%%;*}
    case "$rest" in *';'*) rest=${rest#*;} ;; *) rest="" ;; esac
    [ -n "$entry" ] || continue
    case "$entry" in *=*) ;; *) return 1 ;; esac
    case "${entry%%=*}" in ''|,*|*,|*,,*|*[!A-Za-z0-9_.,+-]*) return 1 ;; esac
    case "${entry#*=}" in ''|n|b|d|n,b|b,n) ;; *) return 1 ;; esac
  done
}

# Prints why a pair is refused, and nothing when it is allowed.
gamefix_reason() {
  # shellcheck disable=SC2016 # the patterns match these characters literally
  case "$2" in
    *'`'*|*'$('*|*'"'*|*"'"*) echo "a backtick, \$( or a quote in the value"; return 0 ;;
    *[[:cntrl:]]*) echo "a control character in the value"; return 0 ;;
  esac
  if [ "${#2}" -gt 1024 ]; then echo "a value over 1024 characters"; return 0; fi
  case "$1" in
    BACKEND)
      case "$2" in dxmt|dxvk|wined3d|d3dmetal) ;; *) echo "not dxmt, dxvk, wined3d or d3dmetal" ;; esac ;;
    MSYNC|RETINA|NVAPI|FRAMEGEN_UI|FRAMEGEN_FALLBACK|STEAMDECK)
      case "$2" in 0|1) ;; *) echo "not 0 or 1" ;; esac ;;
    FRAMEGEN)
      # 1 is the 2x of the first release.
      case "$2" in 0|1|2|3|adaptive) ;; *) echo "not 0, 1, 2, 3 or adaptive" ;; esac ;;
    FRAMEGEN_QUALITY)
      case "$2" in performance|balanced|quality) ;; *) echo "not performance, balanced or quality" ;; esac ;;
    FRAMEGEN_ENGINE)
      case "$2" in own|metalfx) ;; *) echo "not own or metalfx" ;; esac ;;
    DLLOVERRIDES)
      valid_dll_overrides "$2" || echo "not Wine override syntax" ;;
    ARGS)
      # Space-separated arguments, each of A-Za-z0-9_+./:=,- only, so none can glob or quote.
      case "$2" in *[!A-Za-z0-9_+./:=,\ -]*) echo "an argument with characters outside A-Za-z0-9_+./:=,-" ;; esac ;;
    MTL_HUD_ENABLED|WINEDEBUG|WINE_LARGE_ADDRESS_AWARE|WINE_CPU_TOPOLOGY) ;;
    ROSETTA_ADVERTISE_AVX)
      case "$2" in 0|1) ;; *) echo "not 0 or 1" ;; esac ;;
    DXMT_?*|DXVK_?*|MVK_?*|VKD3D_?*|D3DM_?*|STAGING_?*) ;;
    *) echo "not on the allow-list" ;;
  esac
}

gamefix_read() {
  [ -f "$1" ] || return 0
  if [ ! -r "$1" ] || [ "$(stat -f %z "$1" 2>/dev/null || echo 0)" -gt 65536 ]; then
    gamefix_log "$2 conf $1 is unreadable or over 64 KiB, ignored"
    return 0
  fi
  gamefix_log "reading the $2 conf $1"
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    while :; do case "$line" in [[:space:]]*) line=${line#?} ;; *) break ;; esac; done
    while :; do case "$line" in *[[:space:]]) line=${line%?} ;; *) break ;; esac; done
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    case "$line" in
      [A-Z]*=*) case "$key" in *[!A-Z0-9_]*) key="" ;; esac ;;
      *) key="" ;;
    esac
    if [ -z "$key" ]; then
      gamefix_log "$2 conf line $lineno rejected: not KEY=VALUE"
      continue
    fi
    value=${line#*=}
    reason=$(gamefix_reason "$key" "$value")
    if [ -n "$reason" ]; then
      gamefix_log "$2 conf line $lineno rejected $key: $reason"
      continue
    fi
    case " $gamefix_keys " in
      *" $key "*) gamefix_log "$2 conf line $lineno replaces the earlier $key" ;;
      *) gamefix_keys="${gamefix_keys:+$gamefix_keys }$key" ;;
    esac
    # key is [A-Z0-9_] only, so the eval names a variable and copies the value verbatim
    eval "gamefix_value_$key=\$value gamefix_from_$key=\$2"
  done < "$1"
}

gamefix_apply_env() {
  eval "launch_set=\${$1+x}"
  if [ -n "$launch_set" ]; then
    gamefix_log "$1 kept from the launch options, the $3 conf value is not applied"
  else
    export "$1=$2"
    gamefix_log "applied $1=$2 from the $3 conf"
  fi
}

load_gamefixes() {
  case "$app_id" in ''|0) return 0 ;; esac
  gamefix_read "$np_support/gamefixes/default.conf" global
  gamefix_read "$np_support/gamefixes-default/$app_id.conf" default
  gamefix_read "$np_support/gamefixes/$app_id.conf" user
  for key in $gamefix_keys; do
    eval "value=\$gamefix_value_$key from=\$gamefix_from_$key"
    # shellcheck disable=SC2154 # eval assigns from on the line above
    case "$key" in
      BACKEND) gamefix_backend=$value; gamefix_log "BACKEND=$value from the $from conf" ;;
      DLLOVERRIDES) gamefix_dlloverrides=$value
        gamefix_log "DLLOVERRIDES=$value from the $from conf, launch options still win per DLL" ;;
      MSYNC) gamefix_msync=$value; gamefix_log "MSYNC=$value from the $from conf" ;;
      NVAPI) gamefix_nvapi=$value; gamefix_log "NVAPI=$value from the $from conf" ;;
      ARGS)
        if [ "$verb" = waitforexitandrun ]; then
          gamefix_args=$value
          gamefix_log "ARGS=$value from the $from conf, added after the launch options' arguments"
        else
          gamefix_log "ARGS not applied, $verb is not the game launch"
        fi ;;
      RETINA) gamefix_apply_env NOTPROTON_RETINA "$value" "$from" ;;
      # Steam reads SteamDeck in mixed case, which a conf key cannot spell.
      STEAMDECK) gamefix_apply_env SteamDeck "$value" "$from" ;;
      FRAMEGEN|FRAMEGEN_QUALITY|FRAMEGEN_UI|FRAMEGEN_FALLBACK|FRAMEGEN_ENGINE)
        gamefix_apply_env "NOTPROTON_$key" "$value" "$from" ;;
      *) gamefix_apply_env "$key" "$value" "$from" ;;
    esac
  done
}

# Launch options > gamefix MSYNC > an engine with msync > the prefix's last choice > off.
resolve_msync() {
  msync_from=environment
  [ -z "$WINEMSYNC" ] || return 0
  engine_msync=0
  [ ! -e "$CX_ROOT/.notproton-msync" ] || engine_msync=1
  case "$gamefix_msync" in
    0) WINEMSYNC=0; msync_from=gamefix; return 0 ;;
    1)
      if [ "$engine_msync" -eq 1 ]; then WINEMSYNC=1; msync_from=gamefix; return 0; fi
      gamefix_log "MSYNC=1 not applied, the engine has no .notproton-msync" ;;
  esac
  if [ "$engine_msync" -eq 1 ]; then WINEMSYNC=1; msync_from=engine; return 0; fi
  if [ -r "$STEAM_COMPAT_DATA_PATH/notproton-msync" ]; then
    WINEMSYNC=$(tr -d ' \t\n' \
      < "$STEAM_COMPAT_DATA_PATH/notproton-msync" 2>/dev/null || true)
    msync_from=carried-over
  fi
  [ -n "$WINEMSYNC" ] || msync_from=default
}

# Graphics backends. The engine keeps Wine's own dxgi/d3d11/d3d10core/d3d12 in lib/wine and
# ships the alternatives under lib/notproton-backends/<name>/<arch>-windows, which a game
# gets as natives in its prefix. WineCX with d3dmetal.enabled has Apple's D3DMetal as those
# builtins instead and defaults to it. An engine without that folder bakes its DLLs into
# lib/wine, so nothing is swapped there.
backend_root="$CX_ROOT/lib/notproton-backends"
backend=""
backend_from=""
backend_overrides=""

graphics_log() {
  echo "graphics: $*" >> "$log" 2>&1 || true
}

# WineCX with a Game Porting Toolkit linked in: Apple's D3DMetal forwarders are the
# dxgi/d3d10/d3d11/d3d12 builtins of lib/wine, and Wine's own are set aside in
# notproton-backends/wine-stock, so wined3d is not there to fall back on.
d3dmetal_engine() {
  [ -f "$backend_root/d3dmetal.enabled" ]
}

# The lower-case module names of the DLLs in one backend folder, winemetal left to lib/wine.
backend_dlls() {
  for f in "$1"/*.[dD][lL][lL]; do
    [ -f "$f" ] || continue
    name=${f##*/}
    name=$(printf '%s' "${name%.*}" | tr '[:upper:]' '[:lower:]')
    case "$name" in ''|*[!a-z0-9_]*|winemetal) continue ;; esac
    printf '%s\n' "$name"
  done
}

# Every DLL some backend ships, so a copy one of them left in the prefix can be overridden.
managed_dlls() {
  {
    printf '%s\n' dxgi d3d11 d3d10core
    ! d3dmetal_engine || printf '%s\n' d3d10 d3d12
    for dir in "$backend_root"/*/x86_64-windows "$backend_root"/*/i386-windows; do
      case "$dir" in "$backend_root"/wine-stock/*) continue ;; esac
      [ ! -d "$dir" ] || backend_dlls "$dir"
    done
  } | sort -u
}

backend_available() {
  case "$1" in
    wined3d) ! d3dmetal_engine ;;
    d3dmetal) d3dmetal_engine ;;
    dxmt|dxvk) [ -n "$(backend_dlls "$backend_root/$1/x86_64-windows")" ] ;;
    *) return 1 ;;
  esac
}

backend_record() {
  record="$STEAM_COMPAT_DATA_PATH/notproton-backend"
  [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ -f "$record" ] && [ ! -L "$record" ] || return 1
  recorded=$(sed -n 1p "$record" 2>/dev/null) || return 1
  case "$recorded" in
    dxmt|dxvk|wined3d|d3dmetal|dxmt-builtin) printf '%s' "$recorded" ;;
    *) return 1 ;;
  esac
}

# One little-endian unsigned word of 1, 2 or 4 bytes, inside the file only.
pe_word() {
  [ "$2" -ge 0 ] && [ $(($2 + $3)) -le "$pe_size" ] || return 1
  word=$(od -A n -t "u$3" -j "$2" -N "$3" "$1" 2>/dev/null | tr -d ' \n')
  case "$word" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$word"
}

# Count 4-byte words, all of them inside the file, space-separated.
pe_words() {
  [ "$2" -ge 0 ] && [ $(($2 + $3 * 4)) -le "$pe_size" ] || return 1
  od -A n -v -t u4 -j "$2" -N $(($3 * 4)) "$1" 2>/dev/null | tr -s ' \n' '  '
}

# The file offset of an RVA, from the section table words in pe_sections.
pe_rva_offset() {
  rva=$1
  # shellcheck disable=SC2086 # the table is a list of numbers and has to split
  set -- $pe_sections
  while [ "$#" -ge 10 ]; do
    span=$3
    [ "$5" -le "$span" ] || span=$5
    if [ "$rva" -ge "$4" ] && [ "$rva" -lt $(($4 + span)) ]; then
      [ $((rva - $4)) -lt "$5" ] || return 1
      offset=$((rva - $4 + $6))
      [ "$offset" -lt "$pe_size" ] || return 1
      printf '%s' "$offset"
      return 0
    fi
    shift 10
  done
  return 1
}

# A game whose exe imports d3d12.dll is D3D12, which needs Wine's own dxgi (vkd3d), since
# DXMT's dxgi refuses swap chains for devices it did not make. Only the static import
# table counts, and anything that does not parse as a PE detects nothing.
imports_d3d12() {
  pe=$1
  [ -f "$pe" ] || return 1
  pe_size=$(stat -f %z "$pe" 2>/dev/null) || return 1
  [ "$(od -A n -t x1 -N 2 "$pe" 2>/dev/null | tr -d ' \n')" = 4d5a ] || return 1
  header=$(pe_word "$pe" 60 4) || return 1
  [ "$(od -A n -t x1 -j "$header" -N 4 "$pe" 2>/dev/null | tr -d ' \n')" = 50450000 ] || return 1
  section_count=$(pe_word "$pe" $((header + 6)) 2) || return 1
  optional_size=$(pe_word "$pe" $((header + 20)) 2) || return 1
  optional=$((header + 24))
  case "$(pe_word "$pe" "$optional" 2)" in
    267) directories=$((optional + 96)) ;;
    523) directories=$((optional + 112)) ;;
    *) return 1 ;;
  esac
  directory_count=$(pe_word "$pe" $((directories - 4)) 4) || return 1
  [ "$directory_count" -ge 2 ] && [ $((directories + 16)) -le $((optional + optional_size)) ] || return 1
  import_rva=$(pe_word "$pe" $((directories + 8)) 4) || return 1
  [ "$import_rva" -gt 0 ] && [ "$section_count" -ge 1 ] && [ "$section_count" -le 96 ] || return 1
  pe_sections=$(pe_words "$pe" $((optional + optional_size)) $((section_count * 10))) || return 1
  imports=$(pe_rva_offset "$import_rva") || return 1
  descriptors=$(((pe_size - imports) / 20))
  [ "$descriptors" -le 512 ] || descriptors=512
  [ "$descriptors" -ge 1 ] || return 1
  table=$(pe_words "$pe" "$imports" $((descriptors * 5))) || return 1
  # shellcheck disable=SC2086 # the table is a list of numbers and has to split
  set -- $table
  while [ "$#" -ge 5 ]; do
    [ "$1$4$5" != 000 ] || return 1
    if [ "$4" -gt 0 ] && name_at=$(pe_rva_offset "$4"); then
      module=$(dd if="$pe" bs=1 skip="$name_at" count=16 2>/dev/null \
        | LC_ALL=C tr '\0' '\n' | head -n 1 | LC_ALL=C tr '[:upper:]' '[:lower:]')
      [ "$module" != d3d12.dll ] || return 0
    fi
    shift 5
  done
  return 1
}

# NOTPROTON_BACKEND > CX_GRAPHICS_BACKEND > gamefix BACKEND > auto-detect > dxmt, then down
# to what the engine has.
select_backend() {
  wanted=""
  backend_from=""
  if [ ! -d "$backend_root" ]; then
    backend=dxmt-builtin
    backend_from="legacy engine layout, no lib/notproton-backends"
    if [ -n "${NOTPROTON_BACKEND:-}$gamefix_backend" ]; then
      graphics_log "requested backend ${NOTPROTON_BACKEND:-$gamefix_backend} ignored, the engine bakes its graphics DLLs into lib/wine"
    fi
    return 0
  fi
  case "${NOTPROTON_BACKEND:-}" in
    '') ;;
    dxmt|dxvk|wined3d|d3dmetal)
      wanted=$NOTPROTON_BACKEND
      backend_from="NOTPROTON_BACKEND in the launch options" ;;
    *) graphics_log "NOTPROTON_BACKEND is not dxmt, dxvk, wined3d or d3dmetal, ignored" ;;
  esac
  # The Steam panel's Graphics menu writes CX_GRAPHICS_BACKEND.
  if [ -z "$wanted" ] && [ -n "${CX_GRAPHICS_BACKEND:-}" ]; then
    case "$(printf '%s' "$CX_GRAPHICS_BACKEND" | tr '[:upper:]' '[:lower:]')" in
      d3dmetal) wanted=d3dmetal ;;
      dxmt) wanted=dxmt ;;
      dxvk) wanted=dxvk ;;
      wined3d|opengl|wine) wanted=wined3d ;;
      *) graphics_log "CX_GRAPHICS_BACKEND is not a backend this engine maps, ignored" ;;
    esac
    [ -z "$wanted" ] || backend_from="CX_GRAPHICS_BACKEND in the launch options"
  fi
  if [ -z "$wanted" ] && [ -n "$gamefix_backend" ]; then
    wanted=$gamefix_backend
    backend_from="BACKEND in the gamefix conf"
  fi
  # A helper has no game to inspect, so it keeps what the game last ran with.
  if [ -z "$wanted" ] && [ "$verb" != waitforexitandrun ] \
    && recorded=$(backend_record) && [ "$recorded" != dxmt-builtin ]; then
    wanted=$recorded
    backend_from="carried over from the last launch"
  fi
  # D3DMetal, when the engine has it, runs D3D11 and D3D12 alike and is the default.
  if [ -z "$wanted" ] && [ "$verb" = waitforexitandrun ] && [ -f "$1" ]; then
    if imports_d3d12 "$1"; then
      if d3dmetal_engine; then wanted=d3dmetal; else wanted=wined3d; fi
      backend_from="auto-detected, the game imports d3d12.dll"
    elif d3dmetal_engine; then
      wanted=d3dmetal
      backend_from="auto-detected, the engine has D3DMetal"
    else
      wanted=dxmt
      backend_from="auto-detected, the game does not import d3d12.dll"
    fi
  fi
  if [ -z "$wanted" ]; then
    if d3dmetal_engine; then wanted=d3dmetal; else wanted=dxmt; fi
    backend_from=default
  fi
  backend=$wanted
  while ! backend_available "$backend"; do
    case "$backend" in
      d3dmetal) why="no d3dmetal.enabled marker"; next=dxmt ;;
      dxvk) why="no x86_64 DLLs in notproton-backends/dxvk"; next=dxmt ;;
      wined3d) why="D3DMetal replaces Wine's Direct3D in this engine"; next=d3dmetal ;;
      *)
        why="no x86_64 DLLs in notproton-backends/$backend"
        if d3dmetal_engine; then next=d3dmetal; else next=wined3d; fi ;;
    esac
    graphics_log "$backend is not available ($why), falling back to $next"
    backend_from="$backend_from, fell back from $backend"
    backend=$next
  done
}

# Returns 0 when the destination already matches or was replaced.
stage_backend_file() {
  [ -f "$1" ] && [ ! -d "$2" ] || return 1
  if [ -f "$2" ] && [ ! -L "$2" ] \
    && [ "$(stat -f %z "$1" 2>/dev/null)" = "$(stat -f %z "$2" 2>/dev/null)" ] \
    && cmp -s "$1" "$2"; then
    return 0
  fi
  staging="$2.notproton.$$"
  rm -f "$staging" 2>/dev/null || true
  if { cp -c -f "$1" "$staging" 2>/dev/null || cp -f "$1" "$staging" 2>> "$log"; } \
    && mv -f "$staging" "$2" 2>> "$log"; then
    graphics_log "staged ${1#"$CX_ROOT/"} as ${2#"$WINEPREFIX/"}"
    return 0
  fi
  rm -f "$staging" 2>/dev/null || true
  return 1
}

# A prefix copy identical to some backend's DLL was put there by a launch, so it goes
# back to Wine's own. Anything else in the prefix is left alone.
restore_stock_dll() {
  [ -f "$3" ] && [ ! -L "$3" ] || return 0
  # Wine's own copy, which D3DMetal moves aside. A link in lib/wine is Apple's and is
  # never copied into a prefix.
  stock="$backend_root/wine-stock/$1/$2.dll"
  [ -f "$stock" ] && [ ! -L "$stock" ] || stock="$CX_ROOT/lib/wine/$1/$2.dll"
  [ -f "$stock" ] && [ ! -L "$stock" ] || return 0
  ! cmp -s "$stock" "$3" || return 0
  for theirs in "$backend_root"/*/"$1"/*.[dD][lL][lL]; do
    case "$theirs" in "$backend_root"/wine-stock/*) continue ;; esac
    [ -f "$theirs" ] || continue
    base=${theirs##*/}
    [ "$(printf '%s' "${base%.*}" | tr '[:upper:]' '[:lower:]')" = "$2" ] || continue
    if cmp -s "$theirs" "$3"; then
      stage_backend_file "$stock" "$3"
      return
    fi
  done
  return 0
}

# Copies the chosen backend's DLLs into the prefix and sets them native, and sets every
# other DLL a backend could have left there builtin.
activate_backend() {
  backend_overrides=""
  [ "$backend" != dxmt-builtin ] || return 0
  managed=$(managed_dlls)
  shipped=""
  case "$backend" in
    dxmt|dxvk) shipped=$({ backend_dlls "$backend_root/$backend/x86_64-windows"
      backend_dlls "$backend_root/$backend/i386-windows"; } | sort -u | tr '\n' ' ') ;;
  esac
  staging_failed=0
  for pair in x86_64-windows:system32 i386-windows:syswow64; do
    arch=${pair%%:*}
    dir="$WINEPREFIX/drive_c/windows/${pair##*:}"
    [ -n "$WINEPREFIX" ] && [ -d "$dir" ] || continue
    ships=""
    case "$backend" in
      dxmt|dxvk) ships=$(backend_dlls "$backend_root/$backend/$arch" | tr '\n' ' ') ;;
    esac
    for name in $managed; do
      case " $ships " in
        *" $name "*)
          if ! stage_backend_file "$backend_root/$backend/$arch/$name.dll" "$dir/$name.dll"; then
            graphics_log "could not stage $backend $arch/$name.dll into the prefix"
            staging_failed=1
          fi ;;
        *)
          restore_stock_dll "$arch" "$name" "$dir/$name.dll" \
            || graphics_log "could not restore Wine's $arch/$name.dll in the prefix" ;;
      esac
    done
  done
  if [ "$staging_failed" -eq 1 ]; then
    if d3dmetal_engine; then next=d3dmetal; else next=wined3d; fi
    graphics_log "$backend could not be staged, falling back to $next"
    backend=$next
    backend_from="$backend_from, fell back after staging failed"
    activate_backend
    return
  fi
  native=""
  builtin=""
  for name in $managed; do
    case " $shipped " in
      *" $name "*) native="${native:+$native,}$name" ;;
      *) builtin="${builtin:+$builtin,}$name" ;;
    esac
  done
  backend_overrides="${native:+$native=n,b}"
  [ -z "$builtin" ] || backend_overrides="${backend_overrides:+$backend_overrides;}$builtin=b"
  # A linked Game Porting Toolkit can bring Apple's nvapi64 into lib/wine. An nvapi that
  # answers sends some games down NVIDIA-only paths, so it stays disabled unless the game's
  # conf says NVAPI=1, and then only on D3DMetal, the only backend it talks to.
  if d3dmetal_engine && [ -e "$CX_ROOT/lib/wine/x86_64-windows/nvapi64.dll" ]; then
    if [ "$gamefix_nvapi" = 1 ] && [ "$backend" = d3dmetal ]; then
      backend_overrides="${backend_overrides:+$backend_overrides;}nvapi64=b"
    else
      [ "$gamefix_nvapi" != 1 ] || graphics_log "NVAPI=1 not applied, $backend is not d3dmetal"
      backend_overrides="${backend_overrides:+$backend_overrides;}nvapi64=d"
    fi
  fi
  if [ "$backend" = d3dmetal ]; then
    if [ -n "${CX_GRAPHICS_BACKEND:-}" ] && [ "$CX_GRAPHICS_BACKEND" != d3dmetal ]; then
      graphics_log "CX_GRAPHICS_BACKEND=$CX_GRAPHICS_BACKEND replaced by d3dmetal"
    fi
    export CX_GRAPHICS_BACKEND=d3dmetal
  fi
}

record_backend() {
  [ -n "$STEAM_COMPAT_DATA_PATH" ] || return 0
  record="$STEAM_COMPAT_DATA_PATH/notproton-backend"
  [ ! -L "$record" ] || return 0
  previous=$(backend_record) || previous=""
  if [ -n "$previous" ] && [ "$previous" != "$backend" ]; then
    graphics_log "backend switched from $previous to $backend"
  fi
  if ! { printf '%s\n%s\n' "$backend" "$backend_from" > "$record.new" \
    && mv -f "$record.new" "$record"; } 2>/dev/null; then
    rm -f "$record.new" 2>/dev/null || true
    graphics_log "could not record the backend in $record"
  fi
}

# Last entry wins: backend, then the gamefix conf, then the launch options.
compose_dll_overrides() {
  composed=$backend_overrides
  for part in "$gamefix_dlloverrides" "${WINEDLLOVERRIDES:-}"; do
    [ -n "$part" ] || continue
    composed="${composed:+$composed;}$part"
  done
  [ -z "$composed" ] || export WINEDLLOVERRIDES="$composed"
}

load_gamefixes || true

# Steam does not set SteamAppId or SteamGameId for helpers like the install-script
# evaluator. If they are set, SteamAPI_Init registers the helper as the running game so the
# real launch fails with AppError_16. Not applicable to non-Steam shortcuts, which come in
# as waitforexitandrun.
case "$verb" in
  waitforexitandrun)
    [ -n "$SteamAppId" ] || export SteamAppId="$app_id"
    [ -n "$SteamGameId" ] || export SteamGameId="$app_id"
    ;;
esac

prefix_machine() {
  dll="$WINEPREFIX/drive_c/windows/system32/ntdll.dll"
  [ -f "$dll" ] || return 1
  off=$(od -A n -t u4 -j 60 -N 4 "$dll" 2>/dev/null | tr -d ' ')
  case "$off" in ''|*[!0-9]*) return 1 ;; esac
  sig=$(od -A n -t x1 -j "$off" -N 4 "$dll" 2>/dev/null | tr -d ' \n')
  [ "$sig" = 50450000 ] || return 1
  od -A n -t x2 -j "$((off + 4))" -N 2 "$dll" 2>/dev/null | tr -d ' \n'
}

tool_name() {
  case "$1" in
    aa64) printf 'an arm64 (FEX) Wine engine' ;;
    8664) printf 'a Rosetta (x86_64) Wine engine' ;;
    *) printf 'an older 32-bit setup' ;;
  esac
}

# Steam passes "run" for helpers such as install scripts, which get no dialog.
show_alert() {
  [ "$verb" != run ] || return 0
  osascript >/dev/null 2>&1 <<APPLESCRIPT || true
display alert "$1" message "$2" as critical
APPLESCRIPT
}

# A quote or backslash in the text would end the AppleScript string early.
alert_safe() {
  # shellcheck disable=SC1003 # the pair deletes a literal backslash, not a quote
  printf '%s' "$1" | tr -d '"\\'
}

refuse_foreign_prefix() {
  case "${wine_unix##*/}" in
    aarch64-unix) want=aa64 ;;
    *) want=8664 ;;
  esac
  have=$(prefix_machine) || return 0
  [ "$have" = "$want" ] && return 0
  echo "=== prefix ntdll is $have and this compatibility tool wants $want, rebuild the prefix in NotProton ===" >> "$log" 2>&1 || true
  show_alert "This game needs its prefix rebuilt" "This game originally ran under $(tool_name "$have"), but $(tool_name "$want") is present now. The prefix needs to be rebuilt in NotProton in order to run the game. You will not lose game saves by rebuilding the prefix."
  exit 1
}

last_wine_build() {
  updated_file="$STEAM_COMPAT_DATA_PATH/pfx/.update-timestamp"
  [ -r "$updated_file" ] || return 0
  read -r updated _ < "$updated_file" || true
  # Wine ends the line with CRLF.
  updated=${updated%"$(printf '\r')"}
  case "$updated" in '' | *[!0-9]*) return 0 ;; esac
  [ "$updated" = "$(stat -f %m "$CX_ROOT/share/wine/wine.inf" 2>/dev/null)" ] && return 0
  had_build=other
  had_display="another version of CrossOver"
  for inf in "$np_support"/runners/crossover-*/CrossOver/share/wine/wine.inf; do
    [ "$(stat -f %m "$inf" 2>/dev/null)" = "$updated" ] || continue
    if [ "$had_build" != other ]; then
      had_build=other
      had_display="another version of CrossOver"
      break
    fi
    had_build=${inf#"$np_support/runners/crossover-"}
    had_build=${had_build%%/*}
    had_display=$(awk -F '\t' -v b="$had_build" '$2 == b { print $4; exit }' \
      "$np_support/tools" 2>/dev/null) || had_display=""
  done
}

refuse_other_build() {
  record="$STEAM_COMPAT_DATA_PATH/notproton-build"
  had_build=""
  had_display=""
  if [ -r "$record" ]; then
    {
      read -r had_build || true
      read -r had_display || true
    } < "$record"
  else
    last_wine_build
  fi
  if [ -n "$had_build" ] && [ "$had_build" != "$np_build" ]; then
    echo "=== prefix was last run by build $had_build and this compatibility tool runs $np_build, rebuild the prefix in NotProton ===" >> "$log" 2>&1 || true
    had_display=$(alert_safe "${had_display:-CrossOver build $had_build}")
    show_alert "This game needs its prefix rebuilt" "This game's prefix was last run by $had_display, and this compatibility tool runs $(alert_safe "$np_display"). Rebuild the prefix in NotProton to run it here, or pick $had_display again in the game's Compatibility settings. You will not lose game saves by rebuilding the prefix."
    exit 1
  fi
}

claim_prefix() {
  [ -r "$STEAM_COMPAT_DATA_PATH/notproton-build" ] \
    || echo "=== prefix claimed by build $np_build ===" >> "$log" 2>&1 || true
  printf '%s\n%s\n' "$np_build" "$np_display" > "$STEAM_COMPAT_DATA_PATH/notproton-build" 2>/dev/null \
    || echo "=== could not record build $np_build in the prefix ===" >> "$log" 2>&1 || true
}
# Steam cloud related
merge_user_dir() {
  src=$1
  dst=$2
  failed=
  set -- ""
  while [ "$#" -gt 0 ]; do
    rest=$1
    shift
    src_dir="$src$rest"
    dst_dir="$dst$rest"
    if [ ! -r "$src_dir" ] || [ ! -x "$src_dir" ]; then failed=1; continue; fi
    if [ -L "$dst_dir" ]; then failed=1; continue; fi
    probe=$dst_dir
    through=
    while [ -n "$probe" ] && [ "$probe" != "$dst" ]; do
      if [ -L "$probe" ]; then through=1; break; fi
      probe=${probe%/*}
    done
    if [ -n "$through" ]; then
      echo "=== $rest is held by a link, merge refused ===" >> "$log" 2>&1 || true
      failed=1
      continue
    fi
    if [ -e "$dst_dir" ] && [ ! -d "$dst_dir" ]; then
      failed=1
      continue
    fi
    if ! mkdir -p "$dst_dir" 2>/dev/null; then failed=1; continue; fi
    for entry in "$src_dir"/* "$src_dir"/.[!.]* "$src_dir"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=${entry##*/}
      if [ -d "$entry" ] && [ ! -L "$entry" ]; then
        set -- "$@" "$rest/$name"
        continue
      fi
      landing="$dst_dir/$name"
      if [ -e "$landing" ] || [ -L "$landing" ]; then
        if [ -L "$entry" ] && [ -L "$landing" ] \
          && [ "$(readlink "$entry")" = "$(readlink "$landing")" ]; then continue; fi
        if [ -f "$entry" ] && [ ! -L "$entry" ] && [ -f "$landing" ] \
          && [ ! -L "$landing" ] && cmp -s "$entry" "$landing"; then continue; fi
        echo "=== conflicting profile file: $landing ===" >> "$log" 2>&1 || true
        failed=1
        continue
      fi
      if [ -L "$entry" ]; then
        if ! cp -Ppn "$entry" "$landing" 2>/dev/null; then
          failed=1
        fi
      else
        if ! cp -pn "$entry" "$landing" 2>/dev/null || ! cmp -s "$entry" "$landing"; then
          failed=1
        fi
        chmod u+w "$landing" 2>/dev/null || true
      fi
    done
  done
  [ -z "$failed" ]
}

# Steam Cloud stuff
migrate_user_paths() {
  profile=$1
  migration_failed=0
  for pair in \
    "Local Settings/Application Data|AppData/Local|../AppData/Local" \
    "Application Data|AppData/Roaming|./AppData/Roaming" \
    "My Documents|Documents|./Documents"; do
    old_rel=${pair%%|*}
    rest=${pair#*|}
    new_rel=${rest%%|*}
    link=${rest#*|}
    old="$profile/$old_rel"
    new="$profile/$new_rel"
    case "$(readlink "$new" 2>/dev/null || true)" in
      *"drive_c/users/steamuser/$old_rel") rm -f "$new" 2>/dev/null || true ;;
    esac
    if [ -L "$new" ]; then
      echo "=== $new_rel is a link, rebuild the prefix for cloud saves ===" \
        >> "$log" 2>&1 || true
      migration_failed=1
      continue
    fi
    held=
    for rel in "$old_rel" "$new_rel"; do
      probe=$rel
      while [ "$probe" != "${probe%/*}" ]; do
        probe=${probe%/*}
        if [ -L "$profile/$probe" ]; then held=$probe; break; fi
      done
      if [ -n "$held" ]; then break; fi
    done
    if [ -n "$held" ]; then
      echo "=== $held is a link, rebuild the prefix for cloud saves ===" \
        >> "$log" 2>&1 || true
      migration_failed=1
      continue
    fi
    if [ -e "$old" ] && [ ! -L "$old" ]; then
      if ! merge_user_dir "$old" "$new"; then
        echo "=== $old_rel did not merge into $new_rel, left in place ===" \
          >> "$log" 2>&1 || true
        migration_failed=1
        continue
      fi
      backup="$old BACKUP"
      backup_number=2
      while [ -e "$backup" ] || [ -L "$backup" ]; do
        backup="$old BACKUP $backup_number"
        backup_number=$((backup_number + 1))
      done
      if ! mv "$old" "$backup" 2>> "$log"; then
        echo "=== $old_rel could not be moved aside, cloud saves stay split ===" \
          >> "$log" 2>&1 || true
        migration_failed=1
        continue
      fi
    fi
    if [ ! -e "$old" ] && [ ! -L "$old" ]; then
      mkdir -p "${old%/*}" 2>/dev/null || true
      ln -s "$link" "$old" 2>/dev/null \
        || echo "=== $old_rel could not be aliased onto $new_rel ===" >> "$log" 2>&1 \
        || true
    elif [ -L "$old" ] && [ "$(readlink "$old")" != "$link" ]; then
      rm -f "$old" 2>/dev/null || true
      ln -s "$link" "$old" 2>/dev/null \
        || echo "=== $old_rel could not be aliased onto $new_rel ===" >> "$log" 2>&1 \
        || true
    fi
  done
  [ "$migration_failed" -eq 0 ]
}

lay_out_proton_profile() {
  users="${1:-$WINEPREFIX}/drive_c/users"
  if [ -d "$users/crossover" ] && [ ! -L "$users/crossover" ]; then
    echo "=== prefix predates the steamuser layout, rebuild it for cloud saves ===" \
      >> "$log" 2>&1 || true
    return 0
  fi
  profile="$users/steamuser"
  if [ -L "$profile" ]; then
    echo "=== the profile is a link, rebuild the prefix for cloud saves ===" \
      >> "$log" 2>&1 || true
    return 0
  fi
  mkdir -p "$profile" 2>/dev/null || return 0
  for folder in Documents Desktop Downloads Music Pictures Videos Templates \
      AppData/Local AppData/Roaming; do
    mkdir -p "$profile/$folder" 2>/dev/null || true
  done
  migrate_user_paths "$profile" || return 1
  if [ -L "$users/crossover" ] && [ ! -e "$users/crossover" ]; then
    rm -f "$users/crossover" 2>/dev/null || true
  fi
  if [ ! -e "$users/crossover" ] \
    && ln -s steamuser "$users/crossover" 2>/dev/null; then
    echo "=== pointed crossover at steamuser ===" >> "$log" 2>&1 || true
  fi
}

controller_ids() {
  printf '%s\n' "$1" | tr ',' '\n' | tr 'A-F' 'a-f' \
    | sed -n 's/^[[:space:]]*0x\([0-9a-f]\{4\}\)\/0x\([0-9a-f]\{4\}\)[[:space:]]*$/\1\/\2/p' \
    | sort -u
}

ids_without() {
  printf '%s\n' "$2" -- "$1" \
    | awk '$0 == "--" { s = 1; next } !s { b[$0]; next } $0 != "" && !($0 in b)'
}

hidraw_lines() {
  printf '%s\n' "$2" | while read -r id; do
    [ -n "$id" ] || continue
    if [ "$1" = add ]; then
      printf '%s\r\n' "[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\$id]" \
        '"Hidraw"=dword:00000000' ''
    else
      printf '%s\r\n' "[-HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\$id]" ''
    fi
  done
}

write_owned_controllers() {
  if printf '%s\n' "$1" | sed '/^$/d' | sort -u > "$controllers_file.new" \
    && mv -f "$controllers_file.new" "$controllers_file"; then
    return 0
  fi
  rm -f "$controllers_file.new"
  return 1
}

# Proton hides the controllers that Steam Input handles from the Wine process. CrossOver
# still reads a few directly (DualSense, DualShock 4, Switch 1 Pro Controller and Joy-Cons),
# so Hidraw=0 hides those too. The Switch controllers get Hidraw=0 even when Steam Input
# is off, to avoid silently breaking controller support in most games.
plan_hidden_controllers() {
  controllers_file="$STEAM_COMPAT_DATA_PATH/notproton-hidden-controllers"
  controllers_add=""
  controllers_remove=""
  controllers_wanted=""
  [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ ! -L "$controllers_file" ] || return 1
  owned=""
  [ ! -f "$controllers_file" ] || owned=$(sed -n '/^[0-9a-f]\{4\}\/[0-9a-f]\{4\}$/p' "$controllers_file")
  in_registry=""
  [ ! -f "$WINEPREFIX/system.reg" ] || in_registry=$(tr '[:upper:]' '[:lower:]' < "$WINEPREFIX/system.reg" \
    | sed -n 's/^\[system\\\\controlset001\\\\services\\\\winebus\\\\devices\\\\\([0-9a-f]\{4\}\/[0-9a-f]\{4\}\)\].*/\1/p' \
    | sort -u)
  if [ "$NOTPROTON_RAW_CONTROLLERS" != "1" ]; then
    controllers_wanted=$(ids_without "$(controller_ids "$SDL_GAMECONTROLLER_IGNORE_DEVICES")" \
      "$(controller_ids "$SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT")")
    controllers_wanted=$(printf '%s\n' "$controllers_wanted" 057e/2006 057e/2007 057e/2009 | sed '/^$/d' | sort -u)
    # Steam sends install scripts no ignore list. Keep the game's hidden controllers instead of clearing them.
    if [ "$verb" = run ]; then
      controllers_wanted=$(printf '%s\n' "$controllers_wanted" "$owned" | sed '/^$/d' | sort -u)
    fi
    controllers_wanted=$(ids_without "$controllers_wanted" "$(ids_without "$in_registry" "$owned")")
  fi
  controllers_add=$(ids_without "$controllers_wanted" "$in_registry")
  controllers_remove=$(ids_without "$owned" "$controllers_wanted")
  write_owned_controllers "$owned
$controllers_wanted"
}

import_prefix_settings() {
  if [ "$NOTPROTON_RETINA" = "1" ]; then
    retina_line='"RetinaMode"="y"'
  else
    retina_line='"RetinaMode"=-'
  fi
  controllers_planned=0
  if plan_hidden_controllers 2>/dev/null; then
    controllers_planned=1
  else
    controllers_add=""
    controllers_remove=""
    echo "=== could not track the hidden controllers, leaving them as they are ===" >> "$log" 2>&1 || true
  fi
  settings_file=$(mktemp "$WINEPREFIX/drive_c/notproton-settings.XXXXXX" 2>/dev/null) \
    || settings_file=""
  if [ -z "$settings_file" ] || ! { printf '%s\r\n' \
      'Windows Registry Editor Version 5.00' '' \
      '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
      '[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
      '[HKEY_CURRENT_USER\Software\Wine\WineDbg]' '"ShowCrashDialog"=dword:00000000' '' \
      '[HKEY_CURRENT_USER\Software\Wine\Mac Driver]' "$retina_line" '' \
      '[HKEY_LOCAL_MACHINE\Software\Classes\steam]' '"URL Protocol"=""' '' \
      '[HKEY_LOCAL_MACHINE\Software\Classes\steam\shell\open\command]' \
      '@="\"C:\\Program Files (x86)\\Steam\\steam.exe\" \"%1\""' '' \
      && hidraw_lines add "$controllers_add" && hidraw_lines remove "$controllers_remove"; } \
      > "$settings_file" 2>/dev/null; then
    [ -z "$settings_file" ] || rm -f "$settings_file"
    echo "=== could not write the prefix settings, launching without them ===" >> "$log" 2>&1 || true
    # the bridge staging still needs a built prefix
    without_lock_fds "$WINELOADER" wineboot --init >> "$log" 2>&1 || true
    return 0
  fi
  without_lock_fds "$WINELOADER" reg import "C:\\${settings_file##*/}" >> "$log" 2>&1 \
    && import_status=0 || import_status=$?
  rm -f "$settings_file"
  if [ "$import_status" -eq 0 ] && [ "$controllers_planned" -eq 1 ]; then
    write_owned_controllers "$controllers_wanted" 2>/dev/null || true
    if [ -n "$controllers_add$controllers_remove" ]; then
      # Wine only reads these keys when it starts, so restart Wine to apply them.
      without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
      without_lock_fds "$WINESERVER" -w >> "$log" 2>&1 || true
    fi
    if [ "$NOTPROTON_RAW_CONTROLLERS" = "1" ]; then
      echo "controllers: games read them directly (NOTPROTON_RAW_CONTROLLERS=1)" >> "$log" 2>&1 || true
    elif [ -n "$controllers_wanted" ]; then
      echo "controllers: $(printf '%s\n' "$controllers_wanted" | grep -c .) kept off hidraw" \
        >> "$log" 2>&1 || true
    fi
  fi
  [ "$import_status" -eq 0 ] \
    || echo "=== prefix settings import exited status=$import_status ===" >> "$log" 2>&1 || true
}

stage_step="runner check"
if [ -z "$np_build" ] || [ ! -d "$CX_ROOT/lib/wine" ]; then
  echo "=== build ${np_build:-(none recorded)} behind this compatibility tool is not set up, set it up in NotProton ===" >> "$log" 2>&1 || true
  show_alert "CrossOver is not set up" "The CrossOver build behind $(alert_safe "$np_display") is not set up. Set it up in NotProton, or pick another compatibility tool for this game."
  exit 1
fi
echo "runner: build $np_build ($np_display) at $CX_ROOT" >> "$log" 2>&1 || true

# Each CrossOver build needs its own template.
# FEX builds need two, one for FEX/arm64 Wine and one for Rosetta/AMD64 Wine
runner_id=""
[ -z "$np_build" ] || runner_id="crossover-$np_build-${wine_unix##*/}"

in_template_env() {
  prefix="$1"
  shift
  without_lock_fds \
    env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" TMPDIR="${TMPDIR:-/tmp}" \
    LANG="${LANG:-}" LC_ALL="${LC_ALL:-}" \
    PATH="$CX_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin" CX_ROOT="$CX_ROOT" CX_HOME="$CX_HOME" \
    WINEDLLPATH="$CX_ROOT/lib/wine/x86_64-windows:$wine_unix" \
    WINELOADER="$WINELOADER" WINESERVER="$WINESERVER" WINEPREFIX="$prefix" "$@"
}

seed_scratch=""
seed_building=0
# shellcheck disable=SC2329 # the traps in seed_prefix_from_template invoke this
abandon_seed() {
  if [ -n "$seed_scratch" ]; then
    if [ "$seed_building" -eq 1 ]; then
      in_template_env "$seed_scratch" "$WINESERVER" -k >/dev/null 2>&1 || true
      in_template_env "$seed_scratch" "$WINESERVER" -w >/dev/null 2>&1 || exit "$1"
    fi
    rm -rf "$seed_scratch" 2>/dev/null || true
  fi
  exit "$1"
}

prefix_server_dir() {
  [ -n "${1:-$WINEPREFIX}" ] || return 1
  ids=$(stat -f '%d-%i' "${1:-$WINEPREFIX}" 2>/dev/null) || return 1
  [ -n "$ids" ] || return 1
  printf '/tmp/.wine-%s/server-%s' "$(id -u)" \
    "$(printf '%s' "$ids" | awk -F- '{printf "%x-%x", $1, $2}')"
}

sweep_dead_seeds() {
  for leftover in "$@"; do
    [ -d "$leftover" ] && [ ! -L "$leftover" ] || continue
    case "${leftover##*.}" in ''|0|*[!0-9]*) continue ;; esac
    [ "$(stat -f %u "$leftover" 2>/dev/null)" = "$(id -u)" ] || continue
    kill -0 "${leftover##*.}" 2>/dev/null && continue
    stale_server=$(prefix_server_dir "$leftover") || continue
    if [ -d "$stale_server" ]; then
      stale_users=$(lsof -t +D "$stale_server" 2>&1 || true)
      [ -z "$stale_users" ] || continue
    fi
    rm -rf "$leftover" 2>/dev/null || true
  done
}

same_volume() {
  one=$(stat -f %d "$1" 2>/dev/null) || return 1
  two=$(stat -f %d "$2" 2>/dev/null) || return 1
  [ "$one" = "$two" ]
}

# On non-APFS file systems, a full copy is made rather than a clone.
volume_clones() {
  device=$(stat -f %Sd "$1" 2>/dev/null) || return 1
  mount | grep -q "^/dev/$device on .* (apfs[,)]"
}

# Built in a temporary folder and renamed when the build finishes, so a broken template is never used
build_prefix_template() {
  sweep_dead_seeds "$template_dir"/pfx.building.*
  seed_scratch="$template_dir/pfx.building.$$"
  mkdir "$seed_scratch" || return 1
  echo "=== building the prefix template for $runner_id ===" >> "$log" 2>&1 || true
  # The Steam user folders have to exist before wineboot runs, or wineboot will make its own
  # and cloud saves end up in the wrong place.
  lay_out_proton_profile "$seed_scratch" || return 1
  seed_building=1
  in_template_env "$seed_scratch" "$WINELOADER" wineboot --init >> "$log" 2>&1 &
  initialized=0
  wait $! || initialized=$?
  in_template_env "$seed_scratch" "$WINESERVER" -w >> "$log" 2>&1 &
  if ! wait $!; then
    echo "=== template server did not finish, leaving its staging folder intact ===" >> "$log" 2>&1 || true
    seed_scratch=""
    seed_building=0
    return 1
  fi
  seed_building=0
  if [ "$initialized" -ne 0 ] || [ ! -s "$seed_scratch/system.reg" ] \
    || [ ! -s "$seed_scratch/user.reg" ] || [ ! -s "$seed_scratch/userdef.reg" ]; then
    echo "=== wineboot produced no template, this game gets its own prefix ===" \
      >> "$log" 2>&1 || true
    rm -rf "$seed_scratch" 2>/dev/null || true
    seed_scratch=""
    return 1
  fi
  if [ ! -e "$template_dir/pfx" ] && [ ! -L "$template_dir/pfx" ]; then
    mv "$seed_scratch" "$template_dir/pfx" 2>/dev/null || true
  fi
  rm -rf "$seed_scratch" 2>/dev/null || true
  seed_scratch=""
  [ -f "$template_dir/pfx/system.reg" ]
}

install_seed_tree() (
  set -- ""
  while [ "$#" -gt 0 ]; do
    relative=$1
    shift
    source_dir="$seed_scratch$relative"
    target_dir="$WINEPREFIX$relative"
    [ -d "$target_dir" ] && [ ! -L "$target_dir" ] || return 1
    [ -r "$source_dir" ] && [ -x "$source_dir" ] || return 1
    for source in "$source_dir"/* "$source_dir"/.[!.]* "$source_dir"/..?*; do
      [ -e "$source" ] || [ -L "$source" ] || continue
      name=${source##*/}
      if [ -z "$relative" ]; then
        case "$name" in system.reg|.update-timestamp) continue ;; esac
      fi
      target="$target_dir/$name"
      if [ -d "$source" ] && [ ! -L "$source" ]; then
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
          mkdir "$target" || return 1
        fi
        [ -d "$target" ] && [ ! -L "$target" ] || return 1
        set -- "$@" "$relative/$name"
      elif [ -e "$target" ] || [ -L "$target" ]; then
        case "$relative/$name" in
          /drive_c/users/steamuser/*) continue ;;
        esac
        [ -L "$source" ] && [ -L "$target" ] \
          && [ "$(readlink "$source")" = "$(readlink "$target")" ] || return 1
      elif [ -L "$source" ]; then
        ln -sh "$(readlink "$source")" "$target" || return 1
        [ -L "$target" ] && [ "$(readlink "$source")" = "$(readlink "$target")" ] || return 1
      elif [ -f "$source" ]; then
        ln -h "$source" "$target" || return 1
        [ ! -L "$target" ] && [ "$source" -ef "$target" ] || return 1
      else
        return 1
      fi
    done
  done
  ln -h "$seed_scratch/system.reg" "$WINEPREFIX/system.reg" \
    && [ ! -L "$WINEPREFIX/system.reg" ] \
    && [ "$seed_scratch/system.reg" -ef "$WINEPREFIX/system.reg" ] || return 1
  if [ -f "$seed_scratch/.update-timestamp" ]; then
    ln -h "$seed_scratch/.update-timestamp" "$WINEPREFIX/.update-timestamp" || return 1
  fi
)

copy_template_into_prefix() {
  seed_scratch="$STEAM_COMPAT_DATA_PATH/pfx.seeding.$$"
  if ! mkdir "$seed_scratch" 2>/dev/null; then
    echo "=== prefix staging folder is occupied, skipping the template ===" >> "$log" 2>&1 || true
    seed_scratch=""
    return 0
  fi
  if same_volume "$template_dir" "$STEAM_COMPAT_DATA_PATH" && volume_clones "$template_dir"; then
    how="cloned this prefix from the $runner_id template"
    cp -c -R "$template_dir/pfx/." "$seed_scratch" 2>/dev/null && copied=0 || copied=$?
  else
    how="copied this prefix from the $runner_id template, not a clone"
    cp -R "$template_dir/pfx/." "$seed_scratch" 2>/dev/null && copied=0 || copied=$?
  fi
  if [ "$copied" -eq 0 ] && prefix_is_bare && install_seed_tree; then
    echo "=== $how ===" >> "$log" 2>&1 || true
  else
    echo "=== could not seed from the template, wine builds this prefix itself ===" \
      >> "$log" 2>&1 || true
  fi
  rm -rf "$seed_scratch" 2>/dev/null || true
  seed_scratch=""
}

prefix_is_bare() (
  set -- ""
  while [ "$#" -gt 0 ]; do
    relative=$1
    shift
    directory="$WINEPREFIX$relative"
    [ -d "$directory" ] && [ ! -L "$directory" ] \
      && [ -r "$directory" ] && [ -x "$directory" ] || return 1
    for node in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
      [ -e "$node" ] || [ -L "$node" ] || continue
      part="$relative/${node##*/}"
      if [ -L "$node" ]; then
        if [ "$part" = /dosdevices/s: ] && [ "$(readlink "$node")" = "$(game_drive_record)" ]; then
          continue
        fi
        case "$part:$(readlink "$node")" in
          /dosdevices/c::../drive_c|/dosdevices/z::/|/drive_c/users/crossover:steamuser|\
          '/drive_c/users/steamuser/My Documents:./Documents'|\
          '/drive_c/users/steamuser/Application Data:./AppData/Roaming'|\
          '/drive_c/users/steamuser/Local Settings/Application Data:../AppData/Local') continue ;;
          *) return 1 ;;
        esac
      fi
      case "$part" in
        /drive_c|/drive_c/users|/drive_c/users/steamuser|/dosdevices)
          [ -d "$node" ] || return 1 ;;
        /drive_c/users/steamuser/*)
          [ -d "$node" ] || [ -f "$node" ] || return 1 ;;
        *) return 1 ;;
      esac
      if [ -d "$node" ]; then set -- "$@" "$part"; fi
    done
  done
)

template_identity() (
  stat -f '%d:%i:%c' "$CX_ROOT" || return 1
  /usr/bin/shasum -a 256 < "$np_tool_dir/run" || return 1
  cd "$CX_ROOT" || return 1
  set -- "$WINELOADER" "$WINESERVER" share/wine/wine.inf
  for file in lib/wine/*-windows/ntdll.dll lib/wine/*-windows/lsteamclient.dll \
    lib/wine/*-unix/lsteamclient.so; do
    [ ! -f "$file" ] || set -- "$@" "$file"
  done
  /usr/bin/shasum -a 256 "$@"
)

# Each game's prefix is copied from one template (per runner) instead of running wineboot.
# On APFS the copy is a clone, so it takes almost no space.
seed_prefix_from_template() {
  sweep_dead_seeds "$STEAM_COMPAT_DATA_PATH"/pfx.seeding.*
  [ -n "$runner_id" ] || return 0
  if ! prefix_is_bare; then
    [ -f "$WINEPREFIX/system.reg" ] \
      || echo "=== prefix is not empty or a standalone Steam profile, skipping the template ===" \
        >> "$log" 2>&1 || true
    return 0
  fi
  # Since a user can have more than one Steam library and libraries can be on different drives,
  # the template is stored alongside the Steam library to support APFS cloning.
  template_cache="$(dirname "$STEAM_COMPAT_DATA_PATH")/notproton-template"
  template_lock="$(dirname "$STEAM_COMPAT_DATA_PATH")/.notproton-template.lock"
  [ ! -L "$template_cache" ] && [ ! -L "$template_lock" ] || return 0
  [ ! -e "$template_lock" ] || [ -f "$template_lock" ] || return 0
  if ! { : >> "$template_lock"; } 2>/dev/null; then
    echo "=== prefix template cache is not writable, skipping the template ===" >> "$log" 2>&1 || true
    return 0
  fi
  exec 9>> "$template_lock"
  if ! /usr/bin/lockf -s -t 0 9; then
    exec 9>&-
    echo "=== prefix templates are busy, wine builds this prefix itself ===" >> "$log" 2>&1 || true
    return 0
  fi
  template_dir="$template_cache/$runner_id"
  if [ -L "$template_cache" ] || [ -L "$template_dir" ] \
    || ! mkdir -p "$template_dir"; then exec 9>&-; return 0; fi
  if ! identity=$(template_identity); then exec 9>&-; return 0; fi
  trap 'abandon_seed 143' TERM
  trap 'abandon_seed 130' INT
  trap 'abandon_seed 129' HUP
  if [ -L "$template_dir/pfx" ] || [ -L "$template_dir/ready" ] \
    || { [ -e "$template_dir/pfx" ] && [ ! -d "$template_dir/pfx" ]; } \
    || { [ -e "$template_dir/ready" ] && [ ! -f "$template_dir/ready" ]; }; then
    exec 9>&-
    trap - TERM INT HUP
    return 0
  fi
  if [ ! -s "$template_dir/pfx/system.reg" ] \
    || [ "$(cat "$template_dir/ready" 2>/dev/null)" != "$identity" ]; then
    if ! rm -f "$template_dir/ready" || ! rm -rf "$template_dir/pfx"; then
      echo "=== could not invalidate the old prefix template, skipping it ===" >> "$log" 2>&1 || true
      exec 9>&-
      trap - TERM INT HUP
      return 0
    fi
    if build_prefix_template; then
      if ! printf '%s\n' "$identity" > "$template_dir/ready"; then
        rm -f "$template_dir/ready" 2>/dev/null || true
      fi
    fi
  fi
  if [ "$(cat "$template_dir/ready" 2>/dev/null)" = "$identity" ] \
    && [ -s "$template_dir/pfx/system.reg" ]; then
    copy_template_into_prefix
  fi
  exec 9>&-
  trap - TERM INT HUP
}

prepare_prefix_directory() {
  mkdir -p "$STEAM_COMPAT_DATA_PATH" || return 1
  prefix_lock="$STEAM_COMPAT_DATA_PATH/.notproton-prefix.lock"
  [ ! -L "$prefix_lock" ] && { [ ! -e "$prefix_lock" ] || [ -f "$prefix_lock" ]; } || return 1
  exec 8>> "$prefix_lock"
  if ! /usr/bin/lockf -s -t 0 8; then
    echo "=== another launch is preparing this prefix ===" >> "$log" 2>&1 || true
    /usr/sbin/lsof -- "$prefix_lock" >> "$log" 2>&1 || true
    return 1
  fi
  for interrupted in "$STEAM_COMPAT_DATA_PATH"/pfx.replaced.*; do
    [ -e "$interrupted" ] || [ -L "$interrupted" ] || continue
    echo "=== interrupted prefix replacement needs recovery: $interrupted ===" >> "$log" 2>&1 || true
    show_alert "Prefix recovery required" "An interrupted prefix replacement may hold saved games. Do not delete this prefix. Check its notproton-run.log for the recovery folder."
    exit 1
  done
  mkdir -p "$WINEPREFIX"
}

game_drive_record() {
  record="$STEAM_COMPAT_DATA_PATH/notproton-game-drive"
  [ -f "$record" ] && [ ! -L "$record" ] && cat "$record" 2>/dev/null
}

record_game_drive() {
  record="$STEAM_COMPAT_DATA_PATH/notproton-game-drive"
  [ "$(game_drive_record)" != "$1" ] && [ ! -L "$record" ] || return 0
  { printf '%s\n' "$1" > "$record.new" && mv -f "$record.new" "$record"; } 2>/dev/null \
    || rm -f "$record.new" 2>/dev/null || true
}

restart_for_drive() {
  # Wine only picks up a new drive when it starts.
  without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
  without_lock_fds "$WINESERVER" -w >> "$log" 2>&1 || true
}

unmap_game_drive() {
  [ -L "$drive" ] && [ "$(readlink "$drive")" = "$(game_drive_record)" ] || return 0
  rm -f "$drive" || return 0
  rm -f "$STEAM_COMPAT_DATA_PATH/notproton-game-drive" 2>/dev/null || true
  echo "=== removed drive S:, the game is not in a Steam library ===" >> "$log" 2>&1 || true
  restart_for_drive
}

# Like Proton, the game's Steam library gets drive S: so the game does not run from Z:.
map_game_drive() {
  drive="$WINEPREFIX/dosdevices/s:"
  [ -d "$WINEPREFIX/dosdevices" ] && [ ! -L "$WINEPREFIX/dosdevices" ] || return 0
  library=""
  set -f
  old_ifs=$IFS
  IFS=:
  for path in $STEAM_COMPAT_LIBRARY_PATHS; do
    path=${path%/}
    [ -n "$path" ] || continue
    case "$STEAM_COMPAT_INSTALL_PATH/" in
      "$path"/*) if [ "${#path}" -gt "${#library}" ]; then library=$path; fi ;;
    esac
  done
  IFS=$old_ifs
  set +f
  if [ -z "$library" ]; then
    unmap_game_drive
    return 0
  fi
  target=$library
  if real=$(cd -P -- "$library" 2>/dev/null && pwd) && [ "${real##*/}" = steamapps ]; then
    parent=${real%/*}
    if [ -n "$parent" ] && [ -w "$parent" ] \
      && [ "$(stat -f %d "$real")" = "$(stat -f %d "$parent")" ]; then
      target=$parent
    fi
  fi
  if [ -L "$drive" ]; then
    current=$(readlink "$drive") || return 0
    if [ "$current" = "$target" ]; then
      record_game_drive "$target"
      return 0
    fi
    if [ "$current" != "$(game_drive_record)" ]; then
      echo "=== drive S: already points to $current, left in place ===" >> "$log" 2>&1 || true
      return 0
    fi
    rm -f "$drive" || return 0
  elif [ -e "$drive" ]; then
    echo "=== drive S: is not a link, left in place ===" >> "$log" 2>&1 || true
    return 0
  fi
  if ln -s "$target" "$drive" 2>> "$log"; then
    record_game_drive "$target"
    echo "=== mapped drive S: to $target ===" >> "$log" 2>&1 || true
    restart_for_drive
  else
    echo "=== could not map drive S: to $target ===" >> "$log" 2>&1 || true
  fi
}

# Implementation of Proton's create_fonts_symlinks().
link_fonts() {
  [ -f "$WINEPREFIX/system.reg" ] || return 0
  fonts_dir="$WINEPREFIX/drive_c/windows/Fonts"
  mkdir -p "$fonts_dir" 2>> "$log" || return 0
  for dir in "$np_support/fonts" "$CX_ROOT/share/wine/fonts"; do
    for src in "$dir"/*.ttf "$dir"/*.ttc; do
      [ -f "$src" ] || continue
      name=$(basename "$src")
      case "$app_id:$name" in
        1313860:arial.ttf|1506830:arial.ttf) src="$dir/alt/$name" ;;
      esac
      dst="$fonts_dir/$name"
      if [ -L "$dst" ]; then
        rm -f "$dst" && ln -s "$src" "$dst" 2>> "$log" || true
      elif [ ! -e "$dst" ]; then
        ln -s "$src" "$dst" 2>> "$log" || true
      fi
    done
  done
}

if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
  export WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  stage_step="prefix lock"
  prepare_prefix_directory
  resolve_msync
  export WINEMSYNC="${WINEMSYNC:-0}"
  printf '%s' "$WINEMSYNC" \
    > "$STEAM_COMPAT_DATA_PATH/notproton-msync" 2>/dev/null || true
  stage_step="prefix build check"
  refuse_other_build
  stage_step="prefix arch check"
  refuse_foreign_prefix
  claim_prefix
  echo "sync: WINEMSYNC=$WINEMSYNC from $msync_from" >> "$log" 2>&1 || true
  without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
  stage_step="prefix seed"
  seed_prefix_from_template
  stage_step="profile layout"
  if ! lay_out_proton_profile; then
    show_alert "Saved-game folders need attention" "NotProton left the conflicting files in place. Open this prefix's notproton-run.log for details before trying again."
    exit 1
  fi
  echo "video: RetinaMode=${NOTPROTON_RETINA:-0}" >> "$log" 2>&1 || true
  stage_step="game drive"
  map_game_drive
  stage_step="prefix settings"
  import_prefix_settings
  stage_step="fonts"
  link_fonts
  # A prefix that Wine built just now only has dosdevices from this point on.
  stage_step="game drive"
  map_game_drive
fi

stage_step="graphics backend"
select_backend "$1"
activate_backend || true
record_backend || true
graphics_log "backend=$backend ($backend_from)"
compose_dll_overrides
[ -z "$backend_overrides" ] || graphics_log "backend overrides $backend_overrides"

bridge_src="$np_support/bridge"
prefix_steam="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
verify_runner() {
  if [ ! -d "$bridge_src/wine/$np_build" ]; then
    echo "=== no patched ntdll for build $np_build in the bridge, set it up in NotProton ===" >> "$log" 2>&1 || true
    return
  fi
  for arch in x86_64-windows i386-windows aarch64-windows; do
    staged="$bridge_src/wine/$np_build/$arch/ntdll.dll"
    live="$CX_ROOT/lib/wine/$arch/ntdll.dll"
    [ -f "$staged" ] || continue
    if [ ! -f "$live" ]; then
      echo "=== runner has no $arch ntdll, set up the runner in NotProton ===" >> "$log" 2>&1 || true
    elif ! cmp -s "$staged" "$live"; then
      echo "=== runner $arch ntdll is not the patched copy, set up the runner in NotProton ===" >> "$log" 2>&1 || true
    fi
  done
  for arch in i386-windows x86_64-windows "${wine_unix##*/}"; do
    case "$arch" in
      *-unix) name="lsteamclient.so" ;;
      *) name="lsteamclient.dll" ;;
    esac
    [ -f "$CX_ROOT/lib/wine/$arch/$name" ] && continue
    echo "=== runner is missing $arch/$name, set up the runner in NotProton ===" >> "$log" 2>&1 || true
  done
}
install_lsteamclient_trigger() {
  src="$bridge_src/i386-windows/lsteamclient.dll"
  dst="$WINEPREFIX/drive_c/windows/syswow64/lsteamclient.dll"
  [ -f "$src" ] && [ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || return 0
  cmp -s "$src" "$dst" && return 0
  if place_bridge_file i386-windows/lsteamclient.dll "$dst"; then
    echo "=== installed syswow64 lsteamclient trigger ===" >> "$log" 2>&1 || true
  else
    echo "=== could not copy i386-windows/lsteamclient.dll to $dst ===" >> "$log" 2>&1 || true
    return 1
  fi
}

# A builtin Wine only finds through a placeholder in the prefix, and prefixes made
# before the runner carried it have none. DXMT's dxgi imports winemetal, so without
# it every D3D11 game fails to start in such a prefix.
install_runner_builtins() {
  for pair in x86_64-windows:system32 i386-windows:syswow64; do
    arch=${pair%%:*}
    dir="$WINEPREFIX/drive_c/windows/${pair##*:}"
    [ -d "$dir" ] || continue
    name=winemetal.dll
    src="$CX_ROOT/lib/wine/$arch/$name"
    [ -f "$src" ] || continue
    cmp -s "$src" "$dir/$name" && continue
    if cp -f "$src" "$dir/$name"; then
      echo "=== installed $arch/$name into the prefix ===" >> "$log" 2>&1 || true
    else
      echo "=== could not install $arch/$name into the prefix ===" >> "$log" 2>&1 || true
    fi
  done
}

# A fix to match Proton
install_legacy_steam_dll() {
  src="$bridge_src/legacycompat/Steam.dll"
  dst="$WINEPREFIX/drive_c/windows/syswow64/Steam.dll"
  [ -f "$src" ] && [ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || return 0
  cmp -s "$src" "$dst" && return 0
  if place_bridge_file legacycompat/Steam.dll "$dst"; then
    echo "=== installed legacy Steam.dll ===" >> "$log" 2>&1 || true
  else
    echo "=== could not copy legacycompat/Steam.dll to $dst ===" >> "$log" 2>&1 || true
  fi
}

# Steam runs a Windows game's installscript.vdf by invoking the standalone
# evaluator through the compat tool, the same way the linux client does, but
# the binaries are missing on macOS, so...
install_legacycompat() {
  src="$bridge_src/legacycompat"
  dst="$STEAM_COMPAT_CLIENT_INSTALL_PATH/legacycompat"
  [ -d "$src" ] && [ -n "$STEAM_COMPAT_CLIENT_INSTALL_PATH" ] || return 0
  mkdir -p "$dst" || return 0
  for f in "$src"/*; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    cmp -s "$f" "$dst/$b" && continue
    if cp -c -f "$f" "$dst/$b" 2>> "$log"; then
      echo "=== installed legacycompat/$b ===" >> "$log" 2>&1 || true
    else
      echo "=== could not copy legacycompat/$b to $dst/$b ===" >> "$log" 2>&1 || true
    fi
  done
}

# Steam on Linux symlinks this for every compat tool launch. Is needed for some legacy games.
link_legacy_steam_dll() {
  src="$STEAM_COMPAT_CLIENT_INSTALL_PATH/legacycompat/Steam.dll"
  [ -n "$STEAM_COMPAT_INSTALL_PATH" ] && [ -f "$src" ] || return 0
  dst="$(dirname "$STEAM_COMPAT_INSTALL_PATH")/Steam.dll"
  [ -L "$dst" ] || [ ! -e "$dst" ] || return 0
  [ "$(readlink "$dst" 2>/dev/null)" = "$src" ] && return 0
  if ln -sfn "$src" "$dst" 2>> "$log"; then
    echo "=== linked legacy Steam.dll at $dst ===" >> "$log" 2>&1 || true
  else
    echo "=== could not link legacy Steam.dll at $dst ===" >> "$log" 2>&1 || true
  fi
}

bridge_files="steamclient64.dll steamclient.dll tier0_s64.dll vstdlib_s64.dll"
bridge_files="$bridge_files lsteamclient.dll lsteamclient.so steam.exe"
# A clone cannot cross drives, so a prefix on another drive clones from a copy of the
# bridge kept beside that drive's templates.
bridge_origin() {
  origin="$bridge_src/$1"
  [ -n "$bridge_cache" ] || return 0
  cached="$bridge_cache/$1"
  for d in "${bridge_cache%/*}" "$bridge_cache" "${cached%/*}"; do
    [ ! -L "$d" ] || return 0
  done
  mkdir -p "${cached%/*}" 2>/dev/null || return 0
  if ! cmp -s "$origin" "$cached"; then
    if ! { cp -p "$origin" "$cached.$$" && mv -f "$cached.$$" "$cached"; } 2>/dev/null; then
      rm -f "$cached.$$"
      return 0
    fi
  fi
  origin="$cached"
}
place_bridge_file() {
  bridge_origin "$1"
  cp -c -fp "$origin" "$2" 2>/dev/null || cp -fp "$bridge_src/$1" "$2" 2>> "$log"
}
if [ -d "$bridge_src" ] && [ -n "$WINEPREFIX" ]; then
  stage_step="bridge staging"
  mkdir -p "$prefix_steam"
  bridge_cache=""
  if [ -n "$STEAM_COMPAT_DATA_PATH" ] && ! same_volume "$bridge_src" "$STEAM_COMPAT_DATA_PATH" \
    && volume_clones "$STEAM_COMPAT_DATA_PATH"; then
    bridge_cache="$(dirname "$STEAM_COMPAT_DATA_PATH")/notproton-template/bridge"
  fi
  bridge_matches=1
  for f in $bridge_files; do
    src="$bridge_src/$f"
    if [ "$f" = lsteamclient.so ]; then
      src="$bridge_src/${wine_unix##*/}/$f"
    fi
    if ! cmp -s "$src" "$prefix_steam/$f"; then
      bridge_matches=0
      break
    fi
  done
  if [ "$bridge_matches" -eq 1 ]; then
    echo "=== bridge already staged ===" >> "$log" 2>&1 || true
  else
    unstaged=0
    for f in $bridge_files; do
      rel="$f"
      if [ "$f" = lsteamclient.so ]; then
        rel="${wine_unix##*/}/$f"
      fi
      src="$bridge_src/$rel"
      if [ ! -f "$src" ]; then
        echo "=== bridge missing $f ===" >> "$log" 2>&1 || true
        continue
      fi
      cmp -s "$src" "$prefix_steam/$f" && continue
      if ! place_bridge_file "$rel" "$prefix_steam/$f"; then
        echo "=== could not copy $rel to $prefix_steam/$f ===" >> "$log" 2>&1 || true
        unstaged=1
      fi
    done
    if [ "$unstaged" -eq 1 ]; then
      show_alert "Steam files could not be copied" "NotProton could not copy a file into this game's prefix. Open this prefix's notproton-run.log for details."
      exit 1
    fi
  fi
  for f in "$prefix_steam"/*.dll "$prefix_steam"/*.so "$prefix_steam"/*.exe; do
    [ -f "$f" ] || continue
    case " $bridge_files " in
      *" $(basename "$f") "*) ;;
      *) rm -f "$f" && echo "=== pruned stale $(basename "$f") ===" >> "$log" 2>&1 ;;
    esac
  done
  verify_runner
  if ! install_lsteamclient_trigger; then
    show_alert "Steam files could not be copied" "NotProton could not copy a file into this game's prefix. Open this prefix's notproton-run.log for details."
    exit 1
  fi
  install_legacy_steam_dll
  install_runner_builtins
  export WINEDLLPATH="$prefix_steam:$WINEDLLPATH"
  # If the same DLL appears twice in WINEDLLOVERRIDES, the last entry wins.
  export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}steamclient=n;steamclient64=n;lsteamclient=b"
  native_client="$STEAM_COMPAT_CLIENT_INSTALL_PATH"
  if [ -z "$native_client" ]; then
    native_client="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$native_client"
  fi
  install_legacycompat
  link_legacy_steam_dll
  echo "=== bridge staged into $prefix_steam ===" >> "$log" 2>&1 || true
  echo "WINEDLLPATH=$WINEDLLPATH" >> "$log" 2>&1 || true
  echo "WINEDLLOVERRIDES=$WINEDLLOVERRIDES" >> "$log" 2>&1 || true
  echo "STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAM_COMPAT_CLIENT_INSTALL_PATH" >> "$log" 2>&1 || true
fi

export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all}"
exec 8>&-
trap - EXIT
printf 'launch_args=%s\n' "$launch_args" >> "$log" 2>&1 || true
printf '=== launching (%s): %s %s ===\n' "$verb" "$WINELOADER" "$*" >> "$log" 2>&1 || true

target="$1"
# A game can arrive as a URL with no install path to match, so the verb has to decide the route.
case "$verb" in
  waitforexitandrun) foreground=1 ;;
  *) foreground=0 ;;
esac

shim_exe="C:\\Program Files (x86)\\Steam\\steam.exe"

if [ "$foreground" = 0 ]; then
  status=0  # set -e would exit before the status is read
  case "$verb" in
    # runinprefix is the one verb the Linux client keeps on the raw loader.
    runinprefix)
      echo "=== running helper on raw loader: $* ===" >> "$log" 2>&1 || true
      "$WINELOADER" "$@" >> "$log" 2>&1 || status=$?
      ;;
    *)
      # A helper target can be a URL, which steam.exe resolves.
      echo "=== running helper through the shim: $* ===" >> "$log" 2>&1 || true
      "$WINELOADER" "$shim_exe" "$@" >> "$log" 2>&1 || status=$?
      ;;
  esac
  echo "=== helper exited status=$status ===" >> "$log" 2>&1 || true
  exit $status
fi

# Fixes CrossOver window focus issues
steam_root="$(dirname "$(dirname "$(dirname "$STEAM_COMPAT_DATA_PATH")")")"
manifest="$steam_root/steamapps/appmanifest_$app_id.acf"
client_root="$STEAM_COMPAT_CLIENT_INSTALL_PATH"
while [ -n "$client_root" ] && [ "$client_root" != "/" ] && [ ! -d "$client_root/appcache" ]; do
  client_root=$(dirname "$client_root")
done
# Icon stuff
appinfo_tool="$HOME/Library/Application Support/notproton/appinfo"
appinfo_vdf="$client_root/appcache/appinfo.vdf"
meta_name=""
meta_icon=""
meta_clienticon=""
if [ -x "$appinfo_tool" ] && [ -f "$appinfo_vdf" ]; then
  meta=$("$appinfo_tool" "$appinfo_vdf" "$app_id" 2>> "$log") || meta=""
  meta_name=$(printf '%s\n' "$meta" | sed -n 's/^name=//p')
  meta_icon=$(printf '%s\n' "$meta" | sed -n 's/^icon=//p')
  meta_clienticon=$(printf '%s\n' "$meta" | sed -n 's/^clienticon=//p')
  case "$meta_icon" in *[!0-9a-f]*) meta_icon="" ;; esac
  case "$meta_clienticon" in *[!0-9a-f]*) meta_clienticon="" ;; esac
fi
game_name="$meta_name"
if [ -z "$game_name" ] && [ -f "$manifest" ]; then
  game_name=$(sed -n 's/.*"name"[[:space:]]*"\(.*\)".*/\1/p' "$manifest" | head -1)
fi
[ -z "$game_name" ] && game_name=$(basename "$STEAM_COMPAT_INSTALL_PATH")
[ -z "$game_name" ] && game_name="Steam Game"
# shellcheck disable=SC1003 # the pair deletes a literal backslash, not a quote
bundle_name=$(printf '%s' "$game_name" | tr -d '/:"`$\\')
bundle_name=${bundle_name#"${bundle_name%%[!.]*}"}
[ -n "$bundle_name" ] || bundle_name="Steam Game"
game_name_xml=$(printf '%s' "$game_name" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
loader_root="$HOME/Library/Application Support/notproton/launchers/$app_id"
mkdir -p "$loader_root"
loader_app="$loader_root/$bundle_name.app"
find "$loader_root" -maxdepth 1 -name '.build.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
loader_work=$(mktemp -d "$loader_root/.build.XXXXXX")
loader_stage="$loader_work/new/$bundle_name.app"
loader_contents="$loader_stage/Contents"
loader_macos="$loader_contents/MacOS"
loader_res="$loader_contents/Resources"
mkdir -p "$loader_macos" "$loader_res"

icon_arg=""
resolve_icon() {
  set +e
  iconmaker="$HOME/Library/Application Support/notproton/iconmaker"
  art_dir="$client_root/appcache/librarycache/$app_id"
  art=""
  if [ -n "$meta_clienticon" ]; then
    ico="$loader_root/clienticon-$meta_clienticon.ico"
    absent="$loader_root/clienticon-$meta_clienticon.absent"
    failed="$loader_root/clienticon-$meta_clienticon.failed"
    find "$loader_root" -maxdepth 1 -name 'clienticon-*'   ! -name "clienticon-$meta_clienticon.*" -delete 2>/dev/null || true
    find "$absent" -mtime +14 -delete 2>/dev/null || true
    find "$failed" -mmin +60 -delete 2>/dev/null || true
    if [ ! -s "$ico" ] && [ ! -f "$absent" ] && [ ! -f "$failed" ]; then
      url="https://shared.fastly.steamstatic.com/community_assets/images/apps/$app_id/$meta_clienticon.ico"
      code=$(curl -fsL --connect-timeout 5 --max-time 20 -w '%{http_code}' -o "$ico.new" "$url" 2>>"$log")
      magic=$(od -An -tx1 -N4 "$ico.new" 2>/dev/null | tr -d ' \n')
      if [ "$magic" = "00000100" ]; then
        mv -f "$ico.new" "$ico"
        echo "fetched client icon $meta_clienticon" >> "$log" 2>&1 || true
      else
        rm -f "$ico.new"
        if [ "$code" = "404" ]; then
          : > "$absent"
          echo "no client icon published for $meta_clienticon" >> "$log" 2>&1 || true
        else
          : > "$failed"
          echo "client icon fetch for $meta_clienticon failed (http ${code:-none}), will retry in an hour" >> "$log" 2>&1 || true
        fi
      fi
    fi
    [ -s "$ico" ] && art="$ico"
  fi
  if [ -z "$art" ] && [ -n "$meta_icon" ] && [ -f "$art_dir/$meta_icon.jpg" ]; then
    art="$art_dir/$meta_icon.jpg"
  fi
  if [ -z "$art" ]; then
    art=$(find "$art_dir" -maxdepth 1 -type f -name '*.jpg' 2>/dev/null |   grep -E '/[0-9a-f]{40}\.jpg$' | head -1)
  fi
  # Capsule art (horrible) fallback if no icon at all exists...
  if [ -z "$art" ]; then
    for name in library_600x900.jpg header.jpg; do
      found=$(find "$art_dir" -name "$name" 2>/dev/null | head -1)
      [ -n "$found" ] && { art="$found"; break; }
    done
  fi
  # non-Steam shortcuts have no art, so (as a temporary measure while I think of
  # better ways to solve for this) let's use the icon in the EXE itself instead.
  if [ -z "$art" ] && [ -f "$target" ]; then
    case "$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')" in
      *.exe) art="$target" ;;
    esac
  fi
  icon_source=""
  if [ -n "$art" ]; then
    icon_source="$art $(stat -f %m "$art" 2>/dev/null || echo 0)"
  fi
  icon_cache="$loader_root/game.icns"
  if [ -n "$art" ] && [ -s "$icon_cache" ] &&   [ "$(cat "$loader_root/notproton-icon.source" 2>/dev/null)" =   "$icon_source" ] && cp -f "$icon_cache" "$loader_res/game.icns"; then
    icon_arg="  <key>CFBundleIconFile</key><string>game</string>"
    echo "icon reused from $art" >> "$log" 2>&1 || true
  elif [ -n "$art" ] && [ -x "$iconmaker" ]; then
    if "$iconmaker" "$art" "$icon_cache" >> "$log" 2>&1 &&   cp -f "$icon_cache" "$loader_res/game.icns"; then
      icon_arg="  <key>CFBundleIconFile</key><string>game</string>"
      printf '%s\n' "$icon_source" > "$loader_root/notproton-icon.source"
      echo "icon built from $art" >> "$log" 2>&1 || true
    elif [ "$art" = "$ico" ]; then
      # A cached .ico that iconmaker rejects is corrupt and passes the size
      # guard on every launch, so drop it to force a clean fetch next time.
      rm -f "$ico"
      echo "discarded unreadable client icon $meta_clienticon" >> "$log" 2>&1 || true
    fi
  fi
  set -e
  return 0
}
resolve_icon || true
[ -n "$icon_arg" ] || echo "no icon resolved, launching without one" >> "$log" 2>&1 || true

uielement_arg=""
if [ "${NOTPROTON_HIDE_LAUNCHER_TILE:-0}" = "1" ]; then
  uielement_arg="  <key>LSUIElement</key><true/>"
  echo "launcher tile hidden by NOTPROTON_HIDE_LAUNCHER_TILE" >> "$log" 2>&1 || true
fi
cat > "$loader_contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$game_name_xml</string>
  <key>CFBundleDisplayName</key><string>$game_name_xml</string>
  <key>CFBundleIdentifier</key><string>com.notproton.launcher.$app_id</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>This game would like to access your microphone.</string>
  <key>NSCameraUsageDescription</key><string>This game would like to access your camera.</string>
  <key>NSLocalNetworkUsageDescription</key><string>This game would like to access devices on your local network.</string>
$uielement_arg
$icon_arg
</dict>
</plist>
PLIST

# Invokes macOS Game Mode
for f in "$wine_unix"/*; do
  [ -e "$f" ] || continue
  base=${f##*/}
  case "$base" in
    wine|wine.app) continue ;;
  esac
  ln -sfn "$f" "$loader_macos/$base"
done
ln "$WINELOADER" "$loader_macos/wine" 2>/dev/null || cp "$WINELOADER" "$loader_macos/wine"
if [ -x "$loader_macos/wine" ]; then
  WINELOADER="$loader_app/Contents/MacOS/wine"
  echo "loader staged in bundle for game mode" >> "$log" 2>&1 || true
else
  echo "loader staging failed, game mode unavailable" >> "$log" 2>&1 || true
fi

cat > "$loader_macos/launcher" <<LAUNCHER
#!/bin/sh
export WINELOADER="$WINELOADER"
wine_log="$loader_root/notproton-wine.log"
exec > "\$wine_log" 2>&1
shim="$HOME/Library/Application Support/notproton/overlay-shim.dylib"
if [ -n "\$STEAM_DYLD_INSERT_LIBRARIES" ]; then
  if [ -f "\$shim" ]; then
    export DYLD_INSERT_LIBRARIES="\$shim:\$STEAM_DYLD_INSERT_LIBRARIES"
    export NOTPROTON_OVERLAY_SHIM="\$shim"
  else
    export DYLD_INSERT_LIBRARIES="\$STEAM_DYLD_INSERT_LIBRARIES"
  fi
elif [ -f "\$shim" ] && [ "\${NOTPROTON_FRAMEGEN:-0}" != 0 ] && [ "\$NOTPROTON_FRAMEGEN" != off ]; then
  # Frame generation lives in the shim, so it loads without the Steam overlay too.
  export DYLD_INSERT_LIBRARIES="\$shim"
  export NOTPROTON_OVERLAY_SHIM="\$shim"
fi
[ -n "\$NOTPROTON_GAME_CWD" ] && cd "\$NOTPROTON_GAME_CWD"
"$WINELOADER" "\$@"
exit \$?
LAUNCHER
chmod +x "$loader_macos/launcher"

bundle_listing() {
  (cd "$1" && find . | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then
      printf 'l %s %s\n' "$p" "$(readlink "$p")"
    elif [ -d "$p" ]; then
      printf 'd %s\n' "$p"
    else
      printf 'f %s %s %s\n' "$p" "$(stat -f %Lp "$p")" "$(cksum < "$p")"
    fi
  done)
}
install_bundle() (
  exec 7>> "$loader_root/.lock"
  /usr/bin/lockf -s -t 30 7 || exit 1
  same=""
  for b in "$loader_root"/*.app; do
    if [ "$b" = "$loader_app" ] && [ -d "$b" ] && [ ! -L "$b" ] &&
       [ "$(bundle_listing "$b")" = "$(bundle_listing "$loader_stage")" ]; then
      same=1
    fi
  done
  if [ -n "$same" ]; then
    for b in "$loader_root"/*.app "$loader_root"/.[!.]*.app; do
      if [ "$b" != "$loader_app" ]; then rm -rf "$b" || true; fi
    done
    echo "launcher bundle unchanged" >> "$log" 2>&1 || true
  else
    stage_identity=$(stat -f '%d:%i' "$loader_stage") || exit 1
    loader_backup=$(mktemp -d "$loader_root/.backup.XXXXXX") || exit 1
    finish_bundle() {
      result=$?
      trap - EXIT
      trap '' HUP INT TERM
      installed_identity=$(stat -f '%d:%i' "$loader_app" 2>/dev/null) || installed_identity=""
      if [ "$installed_identity" != "$stage_identity" ]; then
        for saved in "$loader_backup"/* "$loader_backup"/.[!.]*; do
          [ -e "$saved" ] || [ -L "$saved" ] || continue
          mv "$saved" "$loader_root/${saved##*/}" || result=1
        done
        rmdir "$loader_backup" 2>/dev/null || result=1
      else
        rm -rf "$loader_backup" || true
      fi
      rm -rf "$loader_work" || true
      exit "$result"
    }
    trap 'finish_bundle' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for b in "$loader_root"/*.app "$loader_root"/.[!.]*.app "$loader_app"; do
      if [ -e "$b" ] || [ -L "$b" ]; then
        mv "$b" "$loader_backup/${b##*/}" || exit 1
      fi
    done
    mv "$loader_stage" "$loader_app" || exit 1
    echo "launcher bundle updated" >> "$log" 2>&1 || true
    finish_bundle
  fi
  rm -rf "$loader_work" || true
)
install_bundle

wine_helpers='winedevice\.exe|services\.exe|plugplay\.exe|svchost\.exe'
wine_helpers="$wine_helpers|rpcss\.exe|explorer\.exe|steam\.exe"
wine_helpers="$wine_helpers|winemenubuilder\.exe|conhost\.exe|start\.exe"
wine_helpers="$wine_helpers|wineboot\.exe|rundll32\.exe|tabtip\.exe"
wine_helpers="$wine_helpers|vc_redist|vcredist|dxsetup\.exe|msiexec\.exe"
wine_helpers="$wine_helpers|installinf|iscriptevaluator\.exe|regsvr32\.exe"
wine_helpers="$wine_helpers|winedbg\.exe|unitycrashhandler"
prefix_game_running() {
  command -v lsof >/dev/null 2>&1 || return 1
  dir=$(prefix_server_dir) || return 1
  [ -d "$dir" ] || return 1
  pids=$(lsof -t +D "$dir" 2>/dev/null | sort -u | tr '\n' ',')
  pids=${pids%,}
  [ -n "$pids" ] || return 1
  # shellcheck disable=SC1003 # the pair matches the backslash in a drive path
  ps -p "$pids" -o args= 2>/dev/null | grep -E '^[A-Za-z]:\\' | grep -viE "$wine_helpers" | grep -q .
}

wait_prefix_idle() {
  idle=0
  tick=0
  while [ "$idle" -lt 10 ] && [ "$tick" -lt 300 ]; do
    tick=$((tick + 1))
    if prefix_game_running; then idle=0; else idle=$((idle + 1)); fi
    sleep 1
  done
  echo "wait_prefix_idle done after tick=$tick idle=$idle" >> "$log" 2>&1 || true
}

kill_wine_prefix() {
  "$WINESERVER" -k >> "$log" 2>&1 || true
  "$WINESERVER" -w >> "$log" 2>&1 || true
  if command -v lsof >/dev/null 2>&1 && server_dir=$(prefix_server_dir); then
    if [ -d "$server_dir" ]; then
      survivors=$(lsof -t +D "$server_dir" 2>/dev/null | sort -u)
      if [ -n "$survivors" ]; then
        echo "=== sweeping prefix stragglers: $survivors ===" >> "$log" 2>&1 || true
        # shellcheck disable=SC2086 # survivors is a list of pids and has to split
        kill -9 $survivors 2>/dev/null || true
      fi
    fi
  fi
}

# Steam's "Exit Game" and the client shutting the game down both send a
# termination signal to this run script, this handles it
# shellcheck disable=SC2329 # the trap below invokes this
terminate() {
  echo "=== termination signal received, killing wine prefix ===" >> "$log" 2>&1 || true
  kill_wine_prefix
  [ -n "$open_pid" ] && kill "$open_pid" 2>/dev/null || true
}
trap terminate TERM INT HUP

game_cwd="$(pwd)"
if [ -n "$gamefix_args" ]; then
  # shellcheck disable=SC2086 # ARGS tokens hold no spaces or glob characters and have to split
  set -- "$@" $gamefix_args
  echo "gamefix: game arguments are now: $*" >> "$log" 2>&1 || true
fi
if [ -n "$STEAM_DYLD_INSERT_LIBRARIES" ]; then
  echo "=== overlay injected from $STEAM_DYLD_INSERT_LIBRARIES ===" >> "$log" 2>&1 || true
else
  echo "=== client staged no overlay renderer, overlay disabled ===" >> "$log" 2>&1 || true
fi
set -- --args "$shim_exe" "$@"
for name in $(env | sed -nE 's/^(CX_APPLEGPTK_LIBD3DSHARED_PATH|SDL_GAMECONTROLLERCONFIG(_FILE)?|SDL_JOYSTICK_MFI|WINE_LARGE_ADDRESS_AWARE|WINE_CPU_TOPOLOGY|Steam[A-Za-z0-9]*|(CX_GRAPHICS|D3DM_|DXMT_|DXVK_|MVK_|VKD3D_|STAGING_|MTL_|ROSETTA_)[A-Z0-9_]*|NOTPROTON_FRAMEGEN(_[A-Z]+)?)=.*/\1/p'); do
  eval "value=\$$name"
  # shellcheck disable=SC2154 # eval assigns value on the line above
  set -- --env "$name=$value" "$@"
done
set -- \
  --env CX_ROOT="$CX_ROOT" \
  --env CX_HOME="$CX_HOME" \
  --env WINESERVER="$WINESERVER" \
  --env WINEDLLPATH="$WINEDLLPATH" \
  --env WINEDLLOVERRIDES="$WINEDLLOVERRIDES" \
  --env WINEMSYNC="$WINEMSYNC" \
  --env WINEPREFIX="$WINEPREFIX" \
  --env WINEDEBUG="$WINEDEBUG" \
  --env PATH="$PATH" \
  --env STEAM_COMPAT_DATA_PATH="$STEAM_COMPAT_DATA_PATH" \
  --env STEAM_COMPAT_INSTALL_PATH="$STEAM_COMPAT_INSTALL_PATH" \
  --env STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_COMPAT_CLIENT_INSTALL_PATH" \
  --env STEAM_COMPAT_APP_ID="$STEAM_COMPAT_APP_ID" \
  --env STEAM_DYLD_INSERT_LIBRARIES="$STEAM_DYLD_INSERT_LIBRARIES" \
  --env NOTPROTON_GAME_CWD="$game_cwd" "$@"
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A"
lsregister="$lsregister/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$lsregister" ] && "$lsregister" -f "$loader_app" >> "$log" 2>&1 || true
if [ "${NOTPROTON_LAUNCH_SERVICES:-0}" = "1" ]; then
  open -n -W -a "$loader_app" "$@" >> "$log" 2>&1 &
else
  # A bundle started by `open` is its own TCC responsible process, so every game
  # needed a separate Input Monitoring grant before controllers worked. Started
  # from here it stays attributed to Steam, which already holds that grant, and
  # macOS still takes the Dock name and icon from the enclosing bundle. env -i
  # with the same --env list keeps the environment `open` would have given it.
  count=$#
  i=0
  mode=vars
  while [ "$i" -lt "$count" ]; do
    arg=$1
    shift
    i=$((i + 1))
    case "$mode:$arg" in
      vars:--env)
        set -- "$@" "$1"
        shift
        i=$((i + 1))
        ;;
      vars:--args)
        mode=args
        set -- "$@" "$loader_app/Contents/MacOS/launcher"
        ;;
      args:*) set -- "$@" "$arg" ;;
    esac
  done
  echo "launching bundle directly so input permission stays with Steam" >> "$log" 2>&1 || true
  env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" SHELL="$SHELL" TMPDIR="$TMPDIR" \
    __CF_USER_TEXT_ENCODING="$__CF_USER_TEXT_ENCODING" "$@" >> "$log" 2>&1 &
fi
open_pid=$!
status=0
seen=0
idle=0
while :; do
  if prefix_game_running; then
    seen=1
    idle=0
  else
    idle=$((idle + 1))
  fi
  if ! kill -0 "$open_pid" 2>/dev/null; then
    wait "$open_pid" || status=$?
    echo "=== bundle exited status=$status ===" >> "$log" 2>&1 || true
    if [ "$status" -le 128 ]; then
      wait_prefix_idle
    fi
    break
  fi
  if [ "$seen" -eq 1 ] && [ "$idle" -ge 10 ]; then
    echo "=== game tree gone, ending session ===" >> "$log" 2>&1 || true
    break
  fi
  sleep 1
done
echo "=== game exited status=$status, killing wine prefix ===" >> "$log" 2>&1 || true
kill_wine_prefix
echo "=== wine prefix killed, session ending ===" >> "$log" 2>&1 || true
exit $status
