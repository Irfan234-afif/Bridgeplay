# Native installer validation

Local validation on 2026-10-21, Apple Silicon, macOS 27.0.1. The implementation is based
on upstream `9ada9fe`; this records local evidence, not a maintainer-signed release approval.

| Check | Result |
|---|---|
| Standalone debug and release installer builds | Passed using Command Line Tools, Swift 6.2.3 / macOS SDK 26.2 |
| Final local release DMG | 771,820 bytes; below the 5 MiB packaging budget |
| `codesign --verify --strict --deep` on installer app | Passed (ad hoc local signature) |
| `make scriptcheck runcheck` | Passed with ShellCheck 0.11.0; 41 shell scripts |
| `make native-installercheck` | Passed: signed fixtures, install/update detection, save/config preservation, rejected inputs, lock, rollback, recovery; eight cleanup-identification checks |
| Build ordering after public version reset | Passed: a higher build with a lower 0.x public version remains eligible and installs |
| Live production release 0.7.0 / build 44 | Downloaded 79,164,423 bytes; EdDSA verification, extraction, code signature, isolated installation and installed-state check passed |
| UI download and running-app guard | Real network progress observed; installation refused while the user's Bridgeplay was running |
| Already-current wizard | Current signed 3.5.0 fixture detected; no reinstall requested |
| Mounted-DMG completion | Finish with Open disabled ejected the disposable source image and moved that exact DMG to Trash; verified both outcomes |
| Packaged resources and translations | App rendered en, it and zh-Hans with development resource bundles unavailable; all 55 source strings have translations |
| Independent source review | Four material issues found and fixed: cross-user lock access, offline recovery, cleanup working directory and shared initializer visibility |

The mounted-image test started the executable with its working directory on that image.
The cleanup helper moved to an external working directory before waiting for exit, so it
did not keep the image busy. The real installed Bridgeplay app was not replaced or quit;
Steam, prefixes, saves and user configuration were not deployed to or modified.

## Remaining gates

Xcode 27.1 was subsequently installed, but its license is not yet accepted. The official
build attempt stops at prerequisites (`cmake`, Homebrew `bison`, and Xcode tools unavailable
until license acceptance). Homebrew also refuses further dependency installation at this
gate. The prior CLT app-test attempt could not load the `Testing` module, so the Swift
Testing suites are authored but are not counted as passing. The full product build and
existing app snapshot comparison must run with the supported Xcode toolchain.

Public-distribution verification still requires a maintainer signing decision and an actual
quarantined/browser-downloaded launch, including App Translocation and Downloads access.
The local ad hoc build is not notarized. Installer flock serializes installers, while the
process guard provides best-effort coordination with Sparkle; a newly launched updater can
still race it. Multiple real macOS users and external/non-APFS/case-sensitive volumes require
additional runtime coverage. No gameplay, Steam deployment or engine-compatibility claims
are made from bootstrap tests.

Local DMG SHA-256 at the recorded size:

```text
64cda3ee3f8e206445e90a9ff735aaee558df963d206aa8bc68eef44c6d09faa
```
