# NotProton-WineHQ

> **This is a fork of [NotProton](https://github.com/NotProtonNot/NotProton).**
>
> I built this for my girlfriend. She only plays occasionally, maybe once or twice a month, and
> buying a CrossOver license for that just isn't worth it for us. So this fork adds a free WineHQ
> engine that runs without CrossOver.
>
> I'll keep maintaining it until someone asks me to stop. That said, don't expect it to stay up to
> date: I only work on it when I find the time and motivation, or when something breaks. This fork
> may lag far behind upstream.
>
> **If you actually want to support the developers**, please read
> [NotProtonNot/NotProton#37](https://github.com/NotProtonNot/NotProton/issues/37) first. It explains
> why the main project chose not to support WineHQ. If you can afford it, consider using the
> upstream project with CrossOver as intended.
>
> This fork is not affiliated with or endorsed by the NotProton developers, the Wine project
> (WineHQ), CodeWeavers or Valve. "Wine" and "CrossOver" are trademarks of their respective
> owners and are only used here to describe what the software works with. Please report problems
> with this fork [here](https://github.com/leonseemann/NotProton-WineHQ/issues), not upstream.
>
> Modified by Leon Seemann, 2026. Like upstream, this fork is licensed under the GPLv3; see
> [NOTICE](NOTICE) for details.

---

## NotProton

NotProton enables the Steam Play experience from Linux Steam in the macOS Steam client.

This is done by forcibly enabling the Steam Play functionality in macOS Steam (which is
present and inert) as well as by porting some components of Valve's Proton to macOS.

This tool is intended to be used with Steam Client 1788652215 or 1790121765 and **CrossOver 26.3 or CrossOver Preview
20261006 or 2026082**. Both the FEX and the Rosetta versions are supported. I recommend using the FEX version of the 
Preview 20261006, as it includes both the FEX version as well as the Rosetta one. 

## Free Wine engine (no CrossOver needed)

NotProton can also run entirely on free software. Under Compatibility Tool, **Download & Set Up**
fetches the WineHQ 11.15 macOS build from [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds)
(hash pinned), unpacks it into `~/Library/Application Support/notproton/engines/` and sets the
compatibility tool up from it exactly like a CrossOver copy. No CrossOver license is involved; the
license check is skipped only for loaders whose hash pins the free build.

11.15 is chosen because it is the Wine the bridge components (`lsteamclient`, `steam.exe`) are built
against. Differences from CrossOver to be aware of:

- It is an x86_64 build and runs under Rosetta 2, like the Rosetta build of CrossOver.
- Direct3D 10/11 goes through [DXMT](https://github.com/3Shain/dxmt) (master `e94c312`, LGPL-2.1+,
  see `docs/DXMT.md`), downloaded and pinned alongside Wine, which translates straight to Metal.
  Wine's own wined3d cannot reach feature level 11 on macOS OpenGL. D3DMetal is Apple's and needs
  CrossOver's Wine changes, so this engine does not use it; the WineCX engine can, with a Game
  Porting Toolkit you supply (`docs/WINECX.md`).
- DXMT needs macdrv functions upstream Wine hides; NotProton ships a rebuilt `winemac.so`
  that exports them (see `winemac-patch/`).
- D3D 12 has no fast path; vkd3d over the bundled MoltenVK is limited.
- WineHQ has no msync/esync, so CPU-heavy games can run slower than under CrossOver or Sikarugir.
- The graphics backend options in the Steam panel have no effect on this engine.

To support another WineHQ build, run `ntdll-patch/resolve.py` against its Wine tree, build the
payloads with `ntdll-patch/build.sh` / `build32.sh`, and add the hashes to `SupportedRunners`,
`NtdllPatcher.byBuild` and `FreeEngine`.

The macOS app itself is located in the ```app``` folder. The core logic is in ```dylib```.
```lsteamclient``` is a macOS port of Valve's lsteamclient. ```steam-shim```is a port of Valve's
steam-helper from Proton 9. ntdll-patch patches the copy of CrossOver that the app
makes/places in the ```~/Library/Application Support/notproton/runners/``` folder so that
lsteamclient is loaded.

This release is coming several days past when I wanted to release it, so the
documentation is quite sparse. Sorry about that, I'll improve it shortly. For real this time.

Please read NOTICE for license information.

Please open issue reports with any issues. PRs are welcome and encouraged. Contributions policy to come shortly.

There are many people who worked on similar ideas, similar projects. I did not base NotProton on their work, but I still want to 
give thanks to the people who came before me:

[Nat Brown](https://github.com/natbro) made [Kaon](https://github.com/natbro/kaon), which is similar in goals to NotProton.

mont127's [Neutron](https://github.com/mont127/Neutron) is also a similar idea, but implemented differently. 

[Gio](https://github.com/giodotblue) was working enabling Steam Play inside of Steam on macOS prior to the release of NotProton itself. 
I would have done things differently had I been aware of that. 

Thanks to everyone who has positively contributed to macOS gaming. 
