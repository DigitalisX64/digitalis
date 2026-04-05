---
description: "Build, install, and test all hellodigitalis sample modules on the Digitalis emulator. Reports PASS/CRASH for each module with crash diagnostics. Use /test-samples to run the full suite, or /test-samples <module> to test a single module."
---

Build and test hellodigitalis sample modules on the Digitalis emulator.

## Steps

1. **Ensure the emulator is running.** If not, boot it:
```bash
source build/envsetup.sh && lunch sdk_phone64_x86_64_digitalis-trunk_staging-userdebug
pkill -9 -f qemu-system-x86_64 || true; sleep 2
nohup emulator -no-snapshot -writable-system > /tmp/emu.log 2>&1 &
n=0; while [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ] && [ $n -lt 90 ]; do sleep 2; n=$((n+1)); done
adb root && sleep 2 && adb remount
```

2. **Build all modules** (or a single one if specified):
```bash
cd sample/hellodigitalis
./gradlew assembleDebug          # all modules
# or: ./gradlew :<module>:assembleDebug
```

3. **Run the test script:**
```bash
.claude/scripts/test-samples.sh $ARGUMENTS
```

4. **Report results.** Summarize the PASS/CRASH table. For crashes, include:
   - The failing instruction (from JIT break logs)
   - The signal (SIGSEGV, SIGILL, etc.)
   - Root cause category (missing instruction, proxy gap, etc.)

5. **Update README.md** if the compatibility table changed.
