#!/usr/bin/env python3
"""Inventory installed Steam games and rate them for NotProton.

Reads ~/Library/Application Support/Steam/steamapps/appmanifest_*.acf, queries the Steam store
(native Mac?), PCGamingWiki (D3D/Vulkan, 64-bit) and AreWeAntiCheatYet (anti-cheat), writes
compat/installed.json and prints a table.
"""
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import np_lookup as L  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STEAMAPPS = os.path.expanduser("~/Library/Application Support/Steam/steamapps")
SKIP = {228980}  # Steamworks Common Redistributables


def main():
    rows = []
    for f in sorted(glob.glob(os.path.join(STEAMAPPS, "appmanifest_*.acf"))):
        txt = open(f, encoding="utf-8", errors="replace").read()
        g = lambda k: (re.search(r'"%s"\s+"(.*)"' % k, txt) or [None, ""])[1]
        appid = int(g("appid"))
        if appid in SKIP:
            continue
        name = g("name")
        idir = os.path.join(STEAMAPPS, "common", g("installdir"))
        skip = re.compile(r"unins|crash|redist|vcredist|dxsetup|dotnet|installer|setup|eac|battleye|helper|touchup|cleanup|overlayinjector|bugsplat|bssndrpt|repair|crs-|activationui", re.I)
        exes = sorted({os.path.relpath(os.path.join(d, x), idir) for d, _, fs in os.walk(idir) for x in fs
                       if x.lower().endswith(".exe") and not skip.search(x) and d[len(idir):].count(os.sep) <= 4})
        st = L.store(appid) or {}
        info = L.pcgw(appid, name)
        ac = L.awacy(appid)
        api = L.api_summary(info)
        mac = bool(st.get("mac"))
        rows.append({
            "appid": appid, "name": name, "installdir": g("installdir"),
            "exes": exes, "vr_only": bool(info and info.get("vr_only")),
            "ray_tracing": (info or {}).get("ray_tracing") or "?", "mac_native": mac, "windows": st.get("windows"),
            "api": api, "d3d_raw": info and info["d3d"], "vulkan_raw": info and info["vulkan"],
            "win64": (info or {}).get("win64") or "?",
            "anticheat": L.anticheat_text(info, ac),
            "pcgw_page": info and info["page"],
            "suggested_backend": L.suggest_backend(api, mac),
        })
        print(f"  fetched {appid} {name}", file=sys.stderr)
    out = os.path.join(ROOT, "compat", "installed.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump(rows, open(out, "w"), indent=2)
    hdr = ("appid", "name", "mac native?", "D3D/Vulkan", "64-bit", "anti-cheat", "suggested first backend")
    table = [hdr] + [(str(r["appid"]), r["name"], "yes" if r["mac_native"] else "no", r["api"], r["win64"],
                      r["anticheat"], r["suggested_backend"]) for r in rows]
    w = [max(len(t[i]) for t in table) for i in range(len(hdr))]
    for i, t in enumerate(table):
        print(" | ".join(c.ljust(w[j]) for j, c in enumerate(t)))
        if i == 0:
            print("-+-".join("-" * x for x in w))


if __name__ == "__main__":
    main()
