Install Magpie from source. Run these shell commands:

1. Install dependencies if not already present:
   ```bash
   brew install yap
   ```

2. Clone the repo (skip if ~/magpie already exists):
   ```bash
   git clone https://github.com/crbikebike/magpie.git ~/magpie
   ```

3. Build and install:
   ```bash
   bash ~/magpie/bin/build.sh
   ```

After the build completes, open ~/Applications/Magpie.app and follow the first-launch setup: grant Microphone permission, optionally grant Screen & System Audio Recording, then choose an output folder.

If ~/magpie already exists, run /update-magpie instead.
