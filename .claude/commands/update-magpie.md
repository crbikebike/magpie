Update Magpie to the latest version. Run these shell commands in order:

1. Ensure `whisper-cpp` is installed. Magpie switched from yap to whisper.cpp in `a5bb851`, so existing installs need the new runtime dependency. This is idempotent — a no-op if it's already present:
   ```bash
   brew list whisper-cpp &>/dev/null || brew install whisper-cpp
   ```

2. Pull and rebuild. The build downloads the ~180MB transcription model the first time it runs after the switch, then caches it for subsequent rebuilds:
   ```bash
   cd ~/magpie && git pull && bash bin/build.sh
   ```

3. Bounce the watcher so it picks up the new watcher.py from the bundle:
   ```bash
   PLIST="$HOME/Library/LaunchAgents/com.crbikebike.magpie.watcher.plist"
   if [ -f "$PLIST" ]; then
     launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
     launchctl bootstrap "gui/$(id -u)" "$PLIST"
     echo "Watcher restarted."
   else
     echo "No watcher plist found — skipping (it will be installed on next app launch)."
   fi
   ```

4. Restart the app so it runs the new binary:
   ```bash
   pkill -x Magpie 2>/dev/null || true
   sleep 1
   open ~/Applications/Magpie.app
   ```

Your output folder, permissions, and watcher configuration are not affected by the update.

If ~/magpie doesn't exist yet, run /install-magpie instead.
