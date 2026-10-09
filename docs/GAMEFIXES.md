# Per-game fixes and graphics backends

The `run` script reads two optional files for each game, named after its Steam app id:

1. `~/Library/Application Support/notproton/gamefixes-default/<appid>.conf`, shipped with NotProton
2. `~/Library/Application Support/notproton/gamefixes/<appid>.conf`, your own

The later file wins per key. A variable you set in the game's Steam launch options
(`NAME=value %command%`) wins over both files.

## Format

One `KEY=VALUE` per line. Blank lines and lines starting with `#` are ignored, and so is
whitespace around a line. There are no inline comments: everything after the first `=`
is the value. The files are never run as shell code. A line is rejected, and the rejection
logged, when:

- the key is not on the list below
- the value contains a backtick, `$(`, a quote or a control character, or is over 1024 characters

| Key | Values | Effect |
| --- | --- | --- |
| `BACKEND` | `dxmt`, `dxvk`, `wined3d`, `d3dmetal` | Graphics backend, see below |
| `ARGS` | space-separated arguments of `A-Za-z0-9_+./:=,-` | Added to the game's command line after the launch options' own arguments. Ignored for installers and other helpers |
| `DLLOVERRIDES` | Wine syntax, e.g. `dinput8=n,b;xinput1_3=n` | Added to `WINEDLLOVERRIDES` after the backend's entries and before the launch options' |
| `MSYNC` | `0`, `1` | `1` turns msync on when the engine supports it; `0` turns it off |
| `RETINA` | `0`, `1` | Same as `NOTPROTON_RETINA` (High Resolution) |
| `DXMT_*`, `DXVK_*`, `MVK_*`, `VKD3D_*`, `D3DM_*`, `STAGING_*` | any | Exported as is |
| `MTL_HUD_ENABLED`, `WINEDEBUG`, `WINE_LARGE_ADDRESS_AWARE`, `WINE_CPU_TOPOLOGY` | any | Exported as is |

Wine uses the last entry for a DLL in `WINEDLLOVERRIDES`. The order is: backend, then
`DLLOVERRIDES`, then the launch options, then the Steam client DLLs, which always come last.

## Graphics backends

| Name | What runs D3D10/11 | D3D12 |
| --- | --- | --- |
| `dxmt` | DXMT (Metal), the default | does not work |
| `dxvk` | DXVK-macOS (MoltenVK); Wine's own `dxgi` stays builtin | vkd3d |
| `wined3d` | Wine's own DLLs | vkd3d |
| `d3dmetal` | Apple D3DMetal, only on engines that ship it | D3DMetal |

The backend is picked in this order:

1. `NOTPROTON_BACKEND=<name>` in the launch options
2. `CX_GRAPHICS_BACKEND` in the launch options, which the Steam panel's Graphics menu sets.
   Any case is accepted. `d3dmetal`, `dxmt` and `dxvk` map to themselves, and `wined3d`,
   `opengl` and `wine` map to `wined3d`. Other values are logged and ignored
3. `BACKEND=` in a conf file
4. Auto-detect. If the game's `.exe` imports `d3d12.dll` in its PE import table, the game
   gets `wined3d`. Otherwise it gets `dxmt`. Delay-loaded and `LoadLibrary` imports do not
   count, and neither does a file that does not parse as a PE
5. `dxmt`

A backend the engine lacks falls back: `dxvk` → `dxmt` → `wined3d`, and `d3dmetal` → `dxmt`.
Engines without `lib/notproton-backends` have their graphics DLLs built in. They show the
backend `dxmt-builtin` and do not swap anything.

The chosen backend's DLLs are copied into the prefix's `system32` and `syswow64` and set
to `n,b`. Every other DLL that any backend ships is set to `b`. When you switch backends, a
copy left behind by another backend is replaced with Wine's own. `d3dmetal` also sets
`CX_GRAPHICS_BACKEND=d3dmetal`. The run log
(`notproton-run.log`) shows each decision. The `notproton-backend` file in the game's
compatdata folder has the current backend and why it was picked.

## Examples

An Unreal game that defaults to D3D12, moved onto its D3D11 renderer under DXVK:

```
BACKEND=dxvk
ARGS=-dx11
DXVK_HUD=fps
```

A game that needs native input DLLs and verbose loader logs:

```
DLLOVERRIDES=dinput8=n,b;xinput1_3=n,b
WINEDEBUG=+loaddll
```

A DXMT game with MetalFX, msync off and High Resolution on:

```
BACKEND=dxmt
DXMT_METALFX_SPATIAL_SWAPCHAIN=1
MSYNC=0
RETINA=1
```
