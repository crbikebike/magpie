Update Magpie to the latest version. Run these shell commands:

```bash
cd ~/magpie && git pull && bash bin/build.sh
```

This pulls the latest source and rebuilds the app in place. The existing ~/Applications/Magpie.app is replaced. Your output folder, permissions, and watcher configuration are not affected.

If ~/magpie doesn't exist yet, run /install-magpie instead.
