# State (2026-10-10)

Branch `integrate` = working fork state; nothing pushed except the `dxmt-e94c312` release asset.

## Works (verified on M5 Max, macOS 27.0.1, WineCX 11.15 + GPTK 4.0b2 D3DMetal)
- 14+ Windows-only games reach a full-screen window; Spider-Man 2 plays (77.9 fps, loads save). See compat/games.json.
- Retina: D3DMetal back buffers sized in pixels (winemac patch, 233353d).
- Xbox controllers: SDL-enabled winebus (9a0cbf5). Do NOT set winebus `Hidraw=1` for pads; it bypasses SDL.
- Many games need `ROSETTA_ADVERTISE_AVX=1` (set in user gamefixes/default.conf and per-game Steam launch options).

## Blockers / open
- NotProton can't deploy to Steam: App Management permission is lost on every ad-hoc rebuild (`run failed: cannot write /Applications/Steam.app/Contents/MacOS`). User must re-allow NotProton in Privacy & Security > App Management. Long-term: sign builds with a stable identity.
- Ravenswatch: black band at top + bottom cropped; game sizes buffers from 1512x876 pt (982 − notch/menu bar). WIP on branch `wip/retina-notch` (unverified). Live runner has the verified winemac (c6110318…).
- Borderlands 4: hangs before first frame (exception storm, likely Denuvo under Rosetta). Not solved.
- The Last of Us Part I: not crashing; probably long first shader build. Skipped by user.
- DOOM: The Dark Ages / Indiana Jones need hardware ray tracing (MoltenVK has none); Half-Life: Alyx is VR.
