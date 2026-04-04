# digitalis

The arm64-to-x86_64 binary translation based on Berberis framework.

## Init

```
mkdir digitalis
cd digitalis
repo init -b android-latest-release -u git@github.com:DigitalisX64/manifest.git
```

## Sync code

```
repo sync -c -d --no-tags --force-sync
```

## Build

```
source build/envsetup.sh
lunch sdk_phone64_x86_64_digitalis-trunk_staging-userdebug
m
```

## Run

```
emulator
# And then build and install sample/hellodigitalis with Gradle to test
```
