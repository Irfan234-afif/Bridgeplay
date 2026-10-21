#!/usr/bin/env python3
"""(Re)seed compat/games.json: installed Windows-only games (from compat/installed.json) plus a
curated list of popular Windows-only DX11-era Steam games. Each candidate is verified against the
Steam store (windows && !mac). Existing entries keep status/notes/last_tested/fork_commit/engine/tested_on/reports;
only api/anticheat/name are refreshed.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import np_lookup as L  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAMES = os.path.join(ROOT, "compat", "games.json")
INSTALLED = os.path.join(ROOT, "compat", "installed.json")

# Curated candidates (appid -> label used if the store lookup fails).
CURATED = {
    1966720: "Lethal Company", 739630: "Phasmophobia", 3241660: "R.E.P.O.", 632360: "Risk of Rain 2",
    374320: "DARK SOULS III", 814380: "Sekiro: Shadows Die Twice", 524220: "NieR:Automata",
    1687950: "Persona 5 Royal", 582010: "Monster Hunter: World", 548430: "Deep Rock Galactic",
    489830: "The Elder Scrolls V: Skyrim Special Edition", 377160: "Fallout 4", 292030: "The Witcher 3: Wild Hunt",
    526870: "Satisfactory", 22380: "Fallout: New Vegas", 1245620: "ELDEN RING", 990080: "Hogwarts Legacy",
    782330: "DOOM Eternal", 892970: "Valheim", 1623730: "Palworld",
}


BORKED = {  # appid -> reason (PCGamingWiki 'vr only' / 'ray tracing = always on')
    546560: "VR-only (PCGamingWiki: vr only = true); needs a headset and SteamVR, which this engine does not provide",
    2677660: "Hardware ray tracing always on (PCGamingWiki: ray tracing = always on, Vulkan 1.1); MoltenVK has no RT",
    3017860: "Hardware ray tracing always on, Vulkan 1.3 (PCGamingWiki: ray tracing = always on; min GPU needs hardware RT); MoltenVK has no RT",
}


def backend_for(api, native):
    b = L.suggest_backend(api, native).split()[0]
    return b if b in ("dxmt", "dxvk", "wined3d", "d3dmetal") and "Vulkan" not in api else None


def main():
    old = {g["appid"]: g for g in json.load(open(GAMES))} if os.path.exists(GAMES) else {}
    cands = dict(CURATED)
    if os.path.exists(INSTALLED):
        for r in json.load(open(INSTALLED)):
            cands.setdefault(r["appid"], r["name"])
    out, dropped = {}, []
    for appid, label in cands.items():
        st = L.store(appid)
        if not st or not st["windows"] or st["mac"]:
            dropped.append((appid, label, "no store data" if not st else "has mac build or not windows"))
            continue
        name = st["name"] or label
        info = L.pcgw(appid, name)
        api = L.api_summary(info)
        ac = L.anticheat_text(info, L.awacy(appid))
        g = old.get(appid, {})
        if appid in BORKED and g.get("status", "untested") == "untested":
            g = dict(g, status="borked", backend=None, notes=BORKED[appid])
        out[appid] = {
            "appid": appid, "name": name,
            "api": api if api != "?" else "unknown",
            "anticheat": ac,
            "status": g.get("status", "untested"),
            "backend": g.get("backend") if g.get("status", "untested") != "untested" else backend_for(api, False),
            "engine": g.get("engine"),
            "notes": g.get("notes", ""),
            "last_tested": g.get("last_tested"),
            "fork_commit": g.get("fork_commit"),
            "tested_on": g.get("tested_on"),
            "reports": g.get("reports"),
        }
        print(f"  {appid} {name}: {api} / {ac}", file=sys.stderr)
    for appid, g in old.items():  # keep hand-added entries that were not re-verified
        out.setdefault(appid, g)
    json.dump(sorted(out.values(), key=lambda g: g["name"].lower()), open(GAMES, "w"), indent=2)
    open(GAMES, "a").write("\n")
    for d in dropped:
        print("dropped", *d, file=sys.stderr)


if __name__ == "__main__":
    main()
