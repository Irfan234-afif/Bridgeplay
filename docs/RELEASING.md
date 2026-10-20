# Releasing Bridgeplay

Every release is a GitHub release of `raymondchins/Bridgeplay` carrying `Bridgeplay.zip`
and `appcast.xml`. Installed apps read
`https://github.com/raymondchins/Bridgeplay/releases/latest/download/appcast.xml`
(`SUFeedURL`), so whatever release is marked **Latest** is the update feed.

## Version scheme

`dylib/version.h` holds three numbers; `make app` stamps them into the app.

| Define | Meaning | In the app | In the appcast |
|---|---|---|---|
| `BRIDGEPLAY_VERSION` | Bridgeplay semver: patch for fixes, minor for an upstream NotProton merge or new features, major for breaks | `CFBundleShortVersionString`, About, Status | `sparkle:shortVersionString`, tag `v<version>` |
| `BRIDGEPLAY_BUILD` | +1 on every release; Sparkle orders updates by it | `CFBundleVersion` | `sparkle:version` |
| `NOTPROTON_VERSION` | the upstream release this is based on, exactly as upstream ships it | `NotProtonVersion`, About ("based on NotProton 1.2.0") | release notes |

The build number continues the old counter, so the first Bridgeplay release orders after
every NotProton-WineHQ build:

| Old release | Old `CFBundleVersion` | New |
|---|---|---|
| `1.1.9-winehq.1-ray.31` (last shipped) | `1.1.9.31` | — |
| `1.2.0-winehq.1-ray.32` (never released) | `1.2.0.32` | Bridgeplay `2.0.0`, build `32` |
| next fix | — | `2.0.1`, build `33` |
| next upstream merge | — | `2.1.0`, build `34` |

Sparkle compares `32` with `1.1.9.31` part by part, so `32 > 1` makes it newer. The semver
starts at 2.0.0 because the app compares the build recorded in Steam numerically
(`DeploymentContent`): a 1.0.0 would read as older than the installed 1.2.0-… and block
installation. `VersioningTests` guards both.

## Steps

1. Bump and commit:
   ```sh
   scripts/bump-version.sh patch        # or minor / major
   git commit -m "chore(release): Bridgeplay X.Y.Z" dylib/version.h
   ```
   `scripts/sync-upstream.sh` already bumps the minor after an upstream merge.
2. Push to `main` of `raymondchins/Bridgeplay` (the script refuses anything else).
3. Optionally rehearse: `scripts/release-local.sh --dry-run` writes the zip and appcast to
   `out/release/` from an app already built with `make app`, without publishing or reading
   the keychain.
4. Release: `scripts/release-local.sh` (notes default to the commit subjects since the
   previous `vX.Y.Z` release; pass a string to override). It builds with
   `scripts/build-local.sh --checks`, signs the zip with the EdDSA key in the login
   keychain, writes an appcast with `minimumSystemVersion` 26.0 and publishes `vX.Y.Z` as
   Latest.

Any other release in the repository (a DXMT build, say) must be created with
`--latest=false`, or the feed URL stops serving `appcast.xml` until the next app release.

## What users see

- The app checks once a day (`SUScheduledCheckInterval` 86400), downloads the update in
  the background and installs it when Bridgeplay quits (`SUAutomaticallyUpdate`). Check
  for Updates… in the app menu does it on demand.
- On the next launch, if the patch inside Steam is from an older Bridgeplay, the app
  re-applies it by itself once Steam and every game are closed. If Steam is open, the
  Status row shows "Update available" until the user installs it or relaunches with Steam
  closed.

## Signing

Sparkle trusts an update when its EdDSA signature matches `SUPublicEDKey`; the archive is
checked before extraction (`SUVerifyUpdateBeforeExtraction`). Apple code signing only has
to be valid, not the same identity: an ad hoc build updates an ad hoc build, and a later
build signed with "NotProton Local Signing" is accepted as well. Losing the keychain key
means no installed copy can update again, so keep a backup (`generate_keys -x`).

## Moving NotProton users over

NotProton builds up to `1.1.9-winehq.1-ray.31` read the feed of
`raymondchins/NotProton-WineHQ`, look for `NotProton.app` or `com.notproton.NotProton` in the
archive, and never check on their own (`SUEnableAutomaticChecks` was false).
`scripts/release-local.sh --legacy-feed` also publishes the release there as Latest, with
the same app zipped as `NotProton.app`. Those users get it from Check for Updates…; it
installs over `/Applications/NotProton.app`, and later updates come from the Bridgeplay
feed, matched by bundle identifier.

## The 3.0.0 rename

3.0.0 renames everything on disk from `notproton` to `bridgeplay`:

| Before | From 3.0.0 |
|---|---|
| `~/Library/Application Support/notproton` | `~/Library/Application Support/bridgeplay` |
| `~/Library/Caches/notproton` | `~/Library/Caches/bridgeplay` |
| `~/.notproton` (np-native, libnp_gamepad.dylib) | `~/.bridgeplay` |
| Steam tools `notproton-winecx-11.17`, `notproton-winehq`, … | `bridgeplay-winecx-11.17`, `bridgeplay-winehq`, … |
| `notproton-run.log`, `notproton-wine.log`, `notproton.log` | `bridgeplay-run.log`, `bridgeplay-wine.log`, `bridgeplay.log` |
| `NOTPROTON_*` in launch options and conf files | `BRIDGEPLAY_*` (the old spelling still works) |

Unchanged: `notproton.dylib`, `lib/notproton-backends`, the prefix markers in `compatdata`
(`notproton-build`, `notproton-backend`), the launcher bundle ids
`com.notproton.launcher.<appid>` and the `NOTPROTON_VERSION` define.

The app migrates on its first launch after the update, once Steam and every game are
closed: it moves the folders and switches games mapped to a `notproton*` tool to its
`bridgeplay*` name. What it replaces is backed up under
`~/Library/Application Support/bridgeplay/backups/migration-3.0.0/`. Nothing is needed in the
release steps; `scripts/release-local.sh` and `scripts/package-installer.sh` fall back to the
`notproton` folders on a Mac that has not migrated yet.
