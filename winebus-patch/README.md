# winebus-patch

`winecx-sdl-mappings.patch` fixes `sdl_bus_load_mappings()` in `dlls/winebus.sys/main.c` (the
PE half). It wrote each mapping to `mappings[count]` after `count++` and terminated
`mappings[len]`, so any value under winebus's `map` key wrote past the array and crashed
winebus with every pad on it. Against winecx `e0aa380`; the build and pin are in
`docs/WINECX.md` (Controllers).
