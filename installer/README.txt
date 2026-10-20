Installing Bridgeplay

You need:
- An Apple Silicon Mac (M1 or later) with macOS 26 or later.
- An administrator account (the installer writes to Applications).
- Internet (for Rosetta and Steam).

1. Double-click "Install.command". macOS blocks it because Apple has not
   notarized it. Click Done.
2. Open System Settings > Privacy & Security. Scroll down to Security and
   click "Open Anyway" next to "Install.command".
3. Click "Open Anyway" again and confirm with your Mac password or Touch ID.
   The installer runs in a Terminal window. If Steam is missing, it downloads
   Steam directly from Valve.
4. Bridgeplay opens with its Setup Assistant. Follow it:
   - Your Mac: click Install for Rosetta if asked (needs your Mac password).
   - Graphics: already done, click Continue.
   - Steam: sign in to your Steam account.
   - Set Up: click Set Up. If asked for App Management, turn on Bridgeplay in
     the Settings window that opens. Setup then continues by itself.
5. Click Open Steam, pick a Windows game, Install, Play.

Updating from Bridgeplay 2.x: the first time 3.0.0 opens, it moves its files
from the old "notproton" folders to "bridgeplay" and keeps a backup. Quit Steam
and any game first; it waits until they are closed.

Controllers: the first time you use a controller, Steam asks for Input
Monitoring. Click Allow (or turn on Steam in System Settings > Privacy &
Security > Input Monitoring).

Licensing: Bridgeplay is licensed under GPL-3.0 (see LICENSE and NOTICE). The installer includes Apple's Game Porting Toolkit
redistributables under Apple's license, which allows non-commercial
distribution only. Bridgeplay is free and non-commercial. Apple's license is
in GPTK-License.rtf.
