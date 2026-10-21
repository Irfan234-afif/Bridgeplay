# Native installer

The native installer is an optional small bootstrap for a new installation or an app
update. It downloads the existing Bridgeplay release, verifies its Sparkle EdDSA signature
before extraction, and installs the app in `/Applications/Bridgeplay.app`. It does not
bundle Wine, GPTK, or the product's payload. Discussion: [issue #17](https://github.com/raymondchins/Bridgeplay/issues/17).

## Build

```sh
make native-installer
```

This builds the `BridgeplayInstaller` SwiftPM product for arm64, copies its two resource
bundles and font license files, compiles installer translations, renders the existing
Bridgeplay mark as the icon, signs the app and packages `out/Bridgeplay-Setup.zip`, a ZIP with only the app in it (a downloaded DMG makes Gatekeeper ask twice).
The default is an ad hoc local build. `BRIDGEPLAY_SIGN_IDENTITY` selects the maintainer's
signing identity. The default size budget is 5 MiB; a larger artifact fails packaging.
`BRIDGEPLAY_INSTALLER_MAX_BYTES` can override the budget for a deliberate size review.

CI also packages the DMG as a build artifact and runs `native-installercheck`.
The maintainer release script attaches the DMG to each app release after generating the
product appcast, so it never becomes a Sparkle update for the product. Its dry run builds
an ad hoc DMG without reading signing identities from the keychain.
The bootstrap can be built separately from the full app/Wine toolchain. Follow
[BUILD-LOCAL.md](BUILD-LOCAL.md) for the product build, which still requires Xcode.
Creating an ad hoc DMG does not provide Developer ID signing or notarization. Test a
quarantined browser download before claiming a frictionless public installation.

## Behavior

The wizard checks the release and installed app, then offers Install or Update. An already
current app requires no download. A newer installed build is kept; the installer refuses a
downgrade. A different application or unsafe destination is not replaced.

The app archive is authenticated with the same public key as the installed app's Sparkle
updater. The app's identity, build, version and code signature are checked before replacement.
The installer stages on the destination volume, coordinates through a persistent lock,
refuses an active Bridgeplay/updater process, and keeps the prior app in the hidden
`.Bridgeplay.app.previous` sibling for recovery. An interrupted replacement is recovered
locally before release discovery, including when the network is unavailable. Unexpected
backup contents are preserved and reported instead of deleted. An older recovery bundle is
rotated by rename before replacement. Retired copies owned by another account or containing
read-only directories stay intact as `.Bridgeplay.app.previous-<UUID>` siblings; an
administrator can remove them in Finder. They do not block subsequent updates.

Prefixes, saves, Steam libraries, support folders and user configuration are not rewritten
by the bootstrap. Opening the installed app continues its existing Setup Assistant or
Status/update flow. Engine/graphics downloads and Steam setup remain the app's responsibility;
the existing Apple toolkit download/import path is preserved. This DMG does not replace the
existing bundled ZIP installer or alter Sparkle's update feed.

On Finish, users may open Bridgeplay and eject/move the source DMG to Trash. Cleanup is
available only when the exact source image is identified from `hdiutil` metadata. A copied
helper outside the mounted volume waits for the installer to exit, rechecks image identity,
ejects and uses macOS Trash. Cleanup failures preserve the image and show a message. No
permanent deletion is used for the downloaded DMG.

## Verification

Run the focused installer core tests with the full app tests on the supported Xcode:

```sh
make app-tests
make scriptcheck runcheck native-installercheck
```

`scripts/test-native-installer.sh` runs an additional standalone smoke suite against the
production core sources without depending on the full app test bundle. It uses generated
signing keys and temporary app roots, leaving installed apps and game data alone.

For visual review, the executable supports deterministic, non-mutating preview states:

```sh
app/.build/debug/BridgeplayInstaller --preview update --screenshot /tmp/installer-update.png
```

For an isolated GUI test, a debug build also accepts `--test-destination` with a
`Bridgeplay.app` path inside the macOS temporary directory. Release builds always use
Applications. Do not open the installed test app unless you intend to exercise real setup.

States are `review`, `update`, `download`, `install`, `done`, `current`, and `error`.
Preview screenshots establish appearance; they do not establish install/update success.

Before public rollout, exercise a fresh install, older/current/newer app, real component
setup, offline/retry, rejected signatures, low disk/permission failures, concurrent
install/update, interrupted replacement, multiple macOS users, external/case-sensitive
volumes, supported OS versions, all locales, keyboard/VoiceOver, and cleanup enabled/disabled.
Record the actual packaged size and separate local ad hoc verification from maintainer-signed
release validation. The contributor writes the PR description personally per CONTRIBUTING.md;
release publishing and keys remain with the maintainer.
