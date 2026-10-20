// Build version string
#ifndef NOTPROTON_VERSION_H
#define NOTPROTON_VERSION_H

#define NOTPROTON_VERSION "1.2.0"

// Bridgeplay's own version, independent of the NotProton release above, which stays
// exactly as upstream ships it so merging upstream never conflicts here.
//   BRIDGEPLAY_VERSION  semver people see: patch for fixes, minor for an upstream merge
//                       or new features (CFBundleShortVersionString, sparkle:shortVersionString)
//   BRIDGEPLAY_BUILD    +1 on every release, continuing the old "-ray.N" counter; Sparkle
//                       orders updates by it (CFBundleVersion, sparkle:version)
// Change both with scripts/bump-version.sh, see docs/RELEASING.md.
#define BRIDGEPLAY_VERSION "2.0.0"
#define BRIDGEPLAY_BUILD 32

#endif // NOTPROTON_VERSION_H
