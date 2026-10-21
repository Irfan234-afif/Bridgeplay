# Apple Game Porting Toolkit: how Bridgeplay meets its license

The installer ships Apple's Game Porting Toolkit redistributables (`D3DMetal.framework` and
the `wine/` libraries from the toolkit's `/redist` directory). They are Apple software under
Apple's license, shipped as `GPTK-License.rtf`; they are not in this repository. This page
maps each condition of that license (Game Porting Toolkit 4.0 beta 3) to what Bridgeplay
does. It is a record of the project's reading, not legal advice.

| License term | What it asks | How Bridgeplay meets it |
|---|---|---|
| 2A(iii) | Distribute "solely for non-commercial purposes" | Bridgeplay is free: no price, paid tier, ads, donations or sponsorship, in the app, the site or the repository. README and NOTICE say so. |
| 2A, 2C | Keep Apple's copyright and proprietary notices on each copy | The installer ships Apple's `License.rtf` as `GPTK-License.rtf`, and the framework keeps its own `Resources/LICENSE`. `scripts/package-installer.sh` stops if the license file is missing. |
| 2C | Only the Framework "in its entirety" or parts of the Redistributables may be distributed apart from the toolkit | Only `D3DMetal.framework` (whole) and files from `/redist` are shipped. |
| 2D | No modifying or creating derivative works | Shipped unmodified. `package-installer.sh` refuses any Mach-O in the GPTK folder that does not carry Apple's own signature (`codesign -R 'anchor apple'`). |
| 2C | Not on non-Apple devices | The installer and the app require an Apple Silicon Mac. |
| 2C | No renting, selling, hosting or service bureau use | Users run it on their own Mac; nothing is hosted or resold. |
| 7B | Use only with materials you may legally use | Users play games they own in their own Steam library. |

Not covered by an automated check: the Windows DLLs under `wine/` are PE files that
`codesign` cannot verify, so their integrity rests on copying them straight from Apple's
DMG. Their source is the Wine source Apple publishes for the toolkit (LGPL-2.1-or-later),
available on request under the offer in [NOTICE](../NOTICE).

When Apple ships a new toolkit version, reread its license and update this table.
