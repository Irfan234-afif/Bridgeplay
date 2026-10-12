# winecoreaudio render buffer patch (WineCX 11.17)

`winecoreaudio.drv` set the CoreAudio device buffer to Wine's whole 10 ms period. A render
callback then regularly asked for more frames than the client had written, and
`ca_render_cb` padded the shortfall with silence, heard as crackling (Deadlock, CS2;
CodeWeavers' Deadlock tip works around it with a 96 kHz output). `winecx-render-buffer.patch`
(against winecx `e0aa380`) asks for half a period on output streams; Wine's period stays
10 ms. Capture streams are unchanged.

Verified 2026-10-12: Deadlock at 44.1 kHz no longer crackles.

Build in the tree configured as in `winemac-patch/README.md`
(`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`):
`make dlls/winecoreaudio.drv/winecoreaudio.so`, then sign ad hoc under the runtime's identifier:
`codesign -f -s - -i winecoreaudio-5555494448b257546f33317180481a4e0075393b winecoreaudio.so`.
Pin: `FreeEngineWinecx.v1117.audio`.
