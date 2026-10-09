# WineCX engine

NotProton's second free engine. WineCX is CodeWeavers' open-source (LGPL) CrossOver 26.3
Wine changes, rebased by dappermint onto upstream wine-11.15
([dappermint/winecx](https://github.com/dappermint/winecx), branch `wine1115`). It is built in
CI into a Whisky runtime by [dappermint/winecx-gptk](https://github.com/dappermint/winecx-gptk).

Compared with the WineHQ 11.15 engine it adds:

- **msync**, CrossOver's Mach-port synchronisation (`WINEMSYNC=1`), which cuts the wineserver
  round trips that slow down CPU-heavy games.
- **D3DMetal support** through CrossOver's hooks (winemac `macdrv_functions`, the
  `libd3dshared` non-native code regions in ntdll, and the d3dkmt answers). This only works
  with a Game Porting Toolkit you install yourself. NotProton never downloads or ships it.
- **DXMT master and DXVK-macOS 1.10.3** as backends a game opts into. DXMT is the same
  `e94c312` build as the WineHQ engine ([DXMT.md](DXMT.md)), not the archive's 0.80. The
  builtin Direct3D is Wine's own, or D3DMetal once a Game Porting Toolkit is linked.

In NotProton it is build `winecx-11.15`, tool `notproton-winecx`, shown as "WineCX 11.15
(msync, D3DMetal)". Like the WineHQ engine it needs no CrossOver license. The licence check
treats it as free only because the loader hash matches the pinned one, so a CrossOver install
can never pass as it.

## Artifact

| | |
|---|---|
| File | `Libraries.tar.gz`, 461,224,571 bytes |
| URL | https://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.5.125/Libraries.tar.gz |
| Mirror | https://github.com/dappermint/Whisky/releases/download/v4.5.125/Libraries.tar.gz (same bytes, the copy Whisky downloads) |
| sha256 | `6db83765d9bd9d9941cacf8e09d2b8a3014738305ca4672d2188f3e6e51fae87` |
| Source | winecx `5b45f4564c4f87fa9c0f958733a5e9bb3918a058` (the tip of `wine1115`), built by winecx-gptk `7a0349b26a04081497ae494027cf69d1a4eeb10c` |
| Base | Wine 11.15 (`VERSION`), the same Wine the bridge components are built against |
| Arch | x86_64 only (Rosetta). PE halves for x86_64 and i386, no arm64/arm64EC |
| Deployment target | minos 26.0 |

Runtime 4.5.125 is the last build on the 11.15 base. Later runtimes (4.6.x, 4.7.x) are
Wine 11.16 and 11.17. It was chosen over frankea/Whisky's
[v4.5.105-beta.1](https://github.com/frankea/Whisky/releases/tag/v4.5.105-beta.1)
(winecx `c2cce0e`) because it carries the msync fixes from 2026-08-21: sleeping instead of
spinning while a wait registers, single-waiter wakeups, and skipping wake syscalls nobody is
waiting on.

Layout inside the archive: `Libraries/Wine` is the Wine tree (`bin/`, `lib/wine/{x86_64-unix,
x86_64-windows,i386-windows}`, bundled dylibs in `lib/`, `share/wine` with wine-mono 11.2.0
and gecko). `Libraries/DXMT/{x64,x32}` holds DXMT 0.80's frontends with the builtin marker
stripped, which NotProton does not use. `Libraries/DXVK/{x64,x32}` holds DXVK. A 0.80-era
`winemetal` is a builtin in `lib/wine`, which NotProton replaces.

## What NotProton lays out

The engine root (`…/WineCX 11.15.app/Contents/SharedSupport/CrossOver`, cloned into the runner
`runners/crossover-winecx-11.15`) is the archive's `Libraries/Wine`, plus:

```
.notproton-msync                                  engine supports msync
lib/wine/x86_64-unix/winemetal.so                 DXMT master, replacing the archive's
lib/wine/{x86_64,i386}-windows/winemetal.dll      DXMT master, replacing the archive's
lib/notproton-backends/dxmt/{x86_64,i386}-windows/{d3d11,d3d10core,dxgi}.dll   DXMT master, marker stripped
lib/notproton-backends/dxvk/{x86_64,i386}-windows/{d3d11,d3d10core}.dll        from the archive
```

DXMT comes from `dxmt-e94c312.tar.gz` (the WineHQ engine's pin, shared download cache).
`winemetal.so` and both `winemetal.dll` are replaced together, since they share one unix-call
table and never mix with 0.80. The D3D DLLs get the 16 bytes of the Wine builtin marker at
0x40 overwritten with a DOS stub, the same bytes winecx-gptk writes, so they load as natives
from a prefix: Wine swaps a marked DLL found in a prefix for the `lib/wine` builtin of the
same name (`load_builtin`, `dlls/ntdll/unix/loader.c`). Each is pinned before and after.
nvapi64, nvngx and the WIP `d3d12.dll` are left out. The DXVK repack has no `dxgi.dll`.
Every file is pinned by sha256 (`FreeEngineWinecx.expectedFiles`); a pin change makes an
installed engine show "Update & Set Up".

DXMT on this engine does **not** need `winemac-patch/`. winecx's `winemac.so` already exports
`_macdrv_functions` (`dlls/winemac.drv/d3dmetal.c`), and the table DXMT reads is unchanged
between 0.80 and master.

## D3DMetal: the builtin model

Apple's forwarders only work as builtins: only a builtin gets its unix half
(`get_builtin_unix_funcs`), and Wine searches its own `lib/wine` before any `WINEDLLPATH`
entry, swapping a marked copy in a prefix for the `lib/wine` builtin. So, as Whisky does,
a linked Game Porting Toolkit *becomes* the engine's Direct3D builtins:

```
lib/wine/x86_64-windows/{d3d10,d3d11,d3d12,dxgi}.dll  -> <gptk>/wine/x86_64-windows/<name>
lib/wine/x86_64-unix/{d3d10,d3d11,d3d12,dxgi}.so      -> <gptk>/wine/x86_64-unix/<name>.so
                                                         (or <gptk>/external/libd3dshared.dylib
                                                         when the GPTK has no unix folder)
lib/wine/x86_64-{windows,unix}/nvapi64.{dll,so}       -> <gptk>, when the GPTK has it
lib/external/{D3DMetal.framework,libd3dshared.dylib}  -> <gptk>/external/
lib/notproton-backends/wine-stock/x86_64-windows/{d3d10,d3d11,d3d12,dxgi}.dll  Wine's originals
lib/notproton-backends/d3dmetal.enabled
```

**Link** (`WinecxD3DMetal.link`): each of Wine's four DLLs is checked against its pin
(`FreeEngineWinecx.current.d3dStock`) and moved, not copied, into `wine-stock`. A DLL that
does not match refuses the link. Then the symlinks are created, every link is checked to
resolve, and `d3dmetal.enabled` is written last. Nothing of Apple's is copied. A failure at
any step runs unlink.

**Unlink** (`WinecxD3DMetal.unlink`): the marker goes first, then only symlinks are removed,
and Wine's originals are moved back from `wine-stock`, byte for byte. A real file is never
deleted. `lib/external` keeps winecx's `README`.

The engine passes its layout check in exactly two states: stock (Wine's four DLLs in
`lib/wine` under their pins, no `wine-stock`, no `.so` for them, no marker) or linked (the
marker, symlinks in `lib/wine` and `lib/external`, Wine's four intact in `wine-stock`).
Anything else makes the engine show "Update & Set Up". A Game Porting Toolkit that was moved
or deleted leaves the linked shape with dangling links: the Status page then shows it as not
found, and Rescan unlinks.

Linking happens when the engine is installed (before the runner is cloned from it, so the
runner carries the same links) and when you press **Rescan**, which relinks or unlinks both
the engine and `runners/crossover-winecx-11.15`. It refuses while a game is running. The
32-bit side is untouched: D3DMetal has no i386 half.

`d3dmetal.enabled` is a `key=value` file: `source=` (the GPTK `lib` folder), `version=`
(D3DMetal.framework's version), `libd3dshared=lib/external/libd3dshared.dylib` (exported as
`CX_APPLEGPTK_LIBD3DSHARED_PATH`, relative to `CX_ROOT`) and `model=builtin`.

What `compat_run.sh` does with it is in [GAMEFIXES.md](GAMEFIXES.md#winecx-with-d3dmetal):
`d3dmetal` becomes the default and the D3D12 choice, `wined3d` runs `d3dmetal`, and `dxmt`
and `dxvk` still work per game as natives.

`nvngx-on-metalfx.dll` is not linked. It only serves DLSS through Apple's nvapi, and
CrossOver renames it to `nvngx.dll` per prefix, which NotProton does not do. Apple's
`nvapi64` is linked but disabled per game unless its conf says `NVAPI=1`.

## Using D3DMetal with your own Game Porting Toolkit

Apple's licence does not let NotProton redistribute D3DMetal, so you supply it:

1. Download the Game Porting Toolkit from Apple:
   https://developer.apple.com/download/all/?q=Game%20Porting%20Toolkit (free Apple
   developer account).
2. Open the disk image ("Evaluation environment for Windows games").
3. Copy the **contents of its `redist/lib` folder** into
   `~/Library/Application Support/notproton/gptk/`, so you end up with `gptk/external/` and
   `gptk/wine/`.
4. In NotProton's Status page, press **Rescan** on the "Game Porting Toolkit" row. It turns
   green with "Linked from <path>." If the WineCX engine is not installed yet, "Download & Set
   Up" on the "WineCX Engine" row links it during setup.

NotProton looks in this order and links the first complete copy: that folder (the
`redist` folder itself, or the whole volume, is also accepted), then
`/Applications/Game Porting Toolkit.app` (`brew install --cask gcenx/wine/game-porting-toolkit`,
which keeps it in `Contents/Resources/wine/lib`), then `~/Applications/Game Porting Toolkit.app`.

A copy counts only when `external/libd3dshared.dylib`, `external/D3DMetal.framework` and
`wine/x86_64-windows/{d3d10,d3d11,d3d12,dxgi}.dll` are all present and each forwarder carries
the `Wine builtin DLL` marker. GPTK 4.0 beta 2 also has `wine/x86_64-unix/<name>.so` (links
to `../../external/libd3dshared.dylib`), `nvapi64` and `nvngx-on-metalfx`, `License.rtf` and
`SOURCE.txt`; the unix halves and nvapi64 are linked when present. NotProton only reads the
folder.

## Risks

- **D3DMetal is engine-wide.** With a GPTK linked, every game on the WineCX engine that
  does not choose `dxmt` or `dxvk` runs D3DMetal, and Wine's `wined3d` is not reachable on
  that engine (use the WineHQ engine for it). A `dxmt`/`dxvk` game still gets Apple's
  `d3d10`/`d3d12` builtins. `wineboot --update` copies `lib/wine` builtins into a prefix, so
  Apple's forwarders can end up in a prefix's `system32`, as they do under Whisky. No game was
  launched in this work.
- **Upstream maturity.** The runtimes are CI builds from one maintainer, tagged automatically.
  The `runtime-v4.5.1xx` tags carry only a version table. The 11.15 notes
  ([v4.5.0](https://github.com/dappermint/winecx-gptk/releases/tag/v4.5.0),
  [v4.5.1](https://github.com/dappermint/winecx-gptk/releases/tag/v4.5.1)) list one known
  caveat: a non-reproducible Steam renderer wedge under `WINEMSYNC=1` on a heavily loaded
  machine. The workaround is `WINEMSYNC=0`. frankea
  validated Steam's UI, D3D12 via D3DMetal and DXVK D3D11 on 11.15, but not a DX12 game
  launched from Steam
  ([v4.5.105-beta.1](https://github.com/frankea/Whisky/releases/tag/v4.5.105-beta.1)).
- **msync needs the wineserver started with the same `WINEMSYNC`.** Otherwise the client
  aborts with "Server is running with WINEMSYNC but this process is not"
  (`dlls/ntdll/unix/msync.c`). `compat_run.sh` exports `WINEMSYNC` before it starts the
  prefix's server.
- **The CrossOver user profile.** A prefix built by another engine keeps its profile under
  `users/<name>`, while CrossOver-lineage Wine uses `users/crossover`
  ([frankea notes](https://github.com/frankea/Whisky/releases/tag/v4.5.105-beta.1)).
  NotProton prefixes are tied to one build, so this only matters if a prefix is moved
  between engines.
- **Bridge compatibility is inferred, not run.** `ntdll.so` exports a superset of stock
  11.15's (299 → 302 symbols), so `lsteamclient.so` resolves. The PE `ntdll.dll` exports were
  not compared, because no stock 11.15 `ntdll.dll` was built locally. `RunnerPatcher` replaces
  winecx's own `lsteamclient` with the bridge's. The bridge has no wineserver-protocol
  component. No game was launched in this work.
- **DXVK.** The archive's DXVK has no `dxgi.dll` for either arch. A 32-bit game on DXVK paired
  with Wine's dxgi can fail with "Adapter is not a DXVK adapter" (winecx-gptk `build.yml`
  comment).
- **Licences.** Wine is LGPL-2.1+, DXMT master LGPL-2.1+ (source at
  https://github.com/3Shain/dxmt/tree/e94c312f5c054263acf261cfa109edf13e757587), DXVK zlib, MoltenVK Apache-2.0. The tarball also
  bundles nixpkgs libraries: ffmpeg 7.1.1 built `--enable-gpl` with x264/x265 (GPL-3.0+),
  and gstreamer's fdk-aac plugin. It ships **no licence texts**, and winecx-gptk has no
  licence of its own. NotProton only downloads the upstream release on the user's machine
  and redistributes none of it. Anyone mirroring the archive takes on those obligations.
- **Rosetta.** The engine is x86_64 and Apple has said Rosetta is largely going away in
  macOS 28. D3DMetal is x86_64 only too (winecx-gptk README).
- **GPTK authenticity.** NotProton checks the builtin marker and file presence but not Apple's
  code signature (Whisky checks both, in `GPTKImporter+Authenticity.swift`). The payload is
  a local folder the user chose.

## Regenerating the pins

```
tar -xzf Libraries.tar.gz
cd ntdll-patch
python3 resolve.py ../Libraries/Wine          # self-tests against PINNED
./build.sh   ../Libraries/Wine/lib/wine/x86_64-windows/ntdll.dll winecx-11.15
./build32.sh ../Libraries/Wine/lib/wine/i386-windows/ntdll.dll  winecx-11.15
python3 apply.py <ntdll.dll> <out> <detour bin>   # patched hashes
```

| Pin | sha256 |
|---|---|
| loader `lib/wine/x86_64-unix/wine` | `a4b677428a6834f97f536a84d32c5da982c9a449e5d483c6be3d1c9b8f308998` |
| clean x86_64 ntdll | `5710d16382c7a822ed8b1cba58d95fd86fe01905f039c296ca7224abff8f98e8` |
| patched x86_64 ntdll | `4efd956e573726777827cddaa89ef3b7f72d6cfd7b8e2049e41f5f5bdf4a6306` |
| clean i386 ntdll | `e1b208073c804a443e64ada577899d96a5c8eaee435813e4a30e0d143bca6e3c` |
| patched i386 ntdll | `23ee72664f172d38d76ecb8969d5c5af7e6828864dfe298338ed0e773910bc5d` |
| `detour2-winecx-11.15.bin` | `fde56854b9a7a32da19babe2427d19ff6a6b83de1917fe8d32aaddd2991fc6b9` |
| `detour32-winecx-11.15.bin` | `37daf5f795535df91bc8fcbd356f22f4fd1ab379ec4acc97ddff44037d265556` |

The unpack test (`FreeEngineWinecxTests.unpacksRealArchive`) checks all of this against the
real archive when `NOTPROTON_WINECX_ARCHIVE` points at it, or when it sits in NotProton's
download cache.
