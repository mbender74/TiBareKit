# Titanium SDK Module Project

This is a skeleton Titanium Mobile Mobile module project.

## Module Naming

Choose a unique module id for your module.  This ID usually follows a namespace
convention using DNS notation.  For example, com.appcelerator.module.test.  This
ID can only be used once by all public modules in Titanium.

## Getting Started

1. Edit the `manifest` with the appropriate details about your module.
2. Edit the `LICENSE` to add your license details.
3. Place any assets (such as PNG files) that are required anywhere in the module folder.
4. Edit the `timodule.xml` and configure desired settings.
5. Code and build.

## Documentation
-----------------------------

You should provide at least minimal documentation for your module in `documentation` folder using the Markdown syntax.

For more information on the Markdown syntax, refer to this documentation at:

<http://daringfireball.net/projects/markdown/>

## Example

The `example` directory contains a skeleton application test harness that can be
used for testing and providing an example of usage to the users of your module.

## Building

Simply run `ti build -p [ios|android] --build-only` which will compile and package your module.

## Linting

You can use `clang` to lint your code. A default linting style is included inside the module main folder.
Run `clang-format -style=file -i SRC_FILE` in the module root to lint the `SRC_FILE`. You can also patterns,
like `clang-format -style=file -i Classes/*`

## Install

To use your module locally inside an app you can copy the zip file into the app root folder and compile your app.
The file will automatically be extracted and copied into the correct `modules/` folder.

If you want to use your module globally in all your apps you have to do the following:

### macOS

Copy the distribution zip file into the `~/Library/Application Support/Titanium` folder

### Linux

Copy the distribution zip file into the `~/.titanium` folder

### Windows
Copy the distribution zip file into the `C:\ProgramData\Titanium` folder

## Project Usage

Register your module with your application by editing `tiapp.xml` and adding your module.
Example:

<modules>
  <module version="1.0.0">ti.barekit</module>
</modules>

When you run your project, the compiler will combine your module along with its dependencies
and assets into the application.

## Example Usage

To use your module in code, you will need to require it. The module exports
`{ Worklet, IPC }`.

### ES6+ (recommended)

```js
import { Worklet, IPC } from 'ti.barekit';

const worklet = new Worklet({ memoryLimit: 24 * 1024 * 1024 });
const ipc = new IPC(worklet);

worklet.start('/app.js', "BareKit.IPC.on('data', (d) => BareKit.IPC.write('echo: ' + d.toString()));", []);

ipc.writable = () => { ipc.write('hello from main'); };
ipc.readable = () => { Ti.API.info('worklet: ' + ipc.read().toString()); };
```

### ES5

```js
var TiBareKit = require('ti.barekit');
var Worklet = TiBareKit.Worklet;
var IPC = TiBareKit.IPC;

var worklet = new Worklet({ memoryLimit: 24 * 1024 * 1024 });
var ipc = new IPC(worklet);

worklet.start('/app.js', "BareKit.IPC.on('data', (d) => BareKit.IPC.write('echo: ' + d.toString()));", []);

ipc.writable = function () { ipc.write('hello from main'); };
ipc.readable = function () { Ti.API.info('worklet: ' + ipc.read().toString()); };
```

See `documentation/index.md` for the full API reference, including the
single-dict callback contract and the write-before-writable constraint.

## Testing

To test your module with the example, use:

```js
ti build -p [ios|android]
```

This will execute the app.js in the example/ folder as a Titanium application.

Code strong!

## Prebuild (maintainers)

Native binaries are checked in. Rebuild them when upgrading bare-kit. The
flow mirrors bare-kit's upstream `publish.yml` workflow.

Prerequisites: CMake 4.0+, Xcode, Android SDK + NDK 28.x, Node.js, and the
`bare-make` npm package (`npm install --global bare-make`).

### iOS

```bash
cd /path/to/bare-kit
npm install                      # first time only

# Build each slice (the prebuilds/Makefile only assembles; slices are built
# with bare-make per the upstream publish.yml flow):
for spec in "ios arm64" "ios arm64 --simulator" "ios x86_64 --simulator"; do
  set -- $spec
  rm -rf build
  bare-make generate --platform "$1" --arch "$2" ${3:+$3} --with-debug-symbols
  bare-make build
  slice="$1-$2${3:+-simulator}"
  mkdir -p "prebuilds/$slice"
  cp -a build/apple/BareKit.framework "prebuilds/$slice/BareKit.framework"
done

cd prebuilds && make ios/BareKit.xcframework

cp -R ios/BareKit.xcframework /path/to/TiBareKit/ios/platform/BareKit.xcframework
```

### Mac Catalyst

The Catalyst slice is built by re-stamping bare's iOS prebuilds to
`platform macCatalyst` with a binary patch, then linking. This is a workaround
because `bare-make` has no `maccatalyst` toolchain and the drive mirror
publishes no Catalyst prebuilds. The binaries retain iOS semantics; only the
platform stamp in each `LC_BUILD_VERSION` load command is changed. This may
have subtle runtime/ABI implications — verify in a Catalyst app before
shipping.

`vtool -set-build-version maccatalyst ...` fails on these object files
("not enough space to hold load commands"), so the re-stamp is done with a
small Python script that patches the `platform` field of each
`LC_BUILD_VERSION` load command from `IOS` (2) / `IOSSIMULATOR` (7) to
`MACCATALYST` (6) in every `.o` member of the prebuilt archives. See
`scripts/maccatalyst/toolchain_stamp.py` (patches `LC_BUILD_VERSION` platform
field: IOS(2)/IOSSIMULATOR(7) → MACCATALYST(6) in every `.o` member of a
static archive, then re-archives with `ar rcs` + ranlib).

Toolchain files: `scripts/maccatalyst/ios-arm64-maccatalyst.cmake` and
`ios-x86_64-maccatalyst.cmake` (substitute `<MACOSX_SDK>` with your MacOSX
SDK path, and `<BARE_MAKE_CMAKE_TOOLCHAINS>` with the path to the
`cmake-toolchains` dir shipped with `bare-make`, e.g.
`$(npm root -g)/bare-make/node_modules/cmake-toolchains`). They model the
upstream `cmake-toolchains/ios-$arch.cmake` but set the target to
`*-apple-ios14.0-macabi`, `CMAKE_OSX_SYSROOT=macosx`, and add
`-iframework <macosx-sdk>/System/iOSSupport/System/Library/Frameworks
-Wno-incompatible-sysroot` to `CMAKE_*_FLAGS_INIT` plus
`-Wl,-undefined,dynamic_lookup` to `CMAKE_*_LINKER_FLAGS_INIT` (the
`dynamic_lookup` flag is required because the V8 prebuilds have
internally-undefined symbols that ld64 rejects by default on macCatalyst;
iOS accepts them implicitly).

```bash
cd /path/to/bare-kit

for arch in arm64 x86_64; do
  # Always start from a clean build dir — incremental reconfigure does not
  # pick up CMAKE_*_LINKER_FLAGS_INIT changes, and the arm64 link will fail
  # without the dynamic_lookup flag.
  rm -rf build-catalyst-$arch
  cmake -S . -B build-catalyst-$arch -G Ninja \
    -DCMAKE_MAKE_PROGRAM=$(npm root -g)/bare-make/node_modules/ninja-runtime-darwin-*/bin/ninja \
    -DCMAKE_TOOLCHAIN_FILE=/path/to/TiBareKit/scripts/maccatalyst/ios-$arch-maccatalyst.cmake \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo

  # Re-stamp fetched prebuilds from IOS/IOSSIMULATOR to MACCATALYST.
  # arm64: ios-arm64 prebuilds (platform IOS) are fetched automatically.
  # x86_64: no ios-x64 prebuild exists — copy ios-x64-simulator prebuilds
  #         into _deps/.../ios-x64/ before re-stamping.
  if [ "$arch" = "x86_64" ]; then
    src=build/_deps/github+holepunchto+bare-build/ios-x64-simulator
    if [ ! -d "$src" ]; then
      echo "ios-x64-simulator prebuilds not found at $src — run the iOS simulator build first (see iOS section above)" >&2
      exit 1
    fi
    dst=build-catalyst-x86_64/_deps/github+holepunchto+bare-build/ios-x64
    mkdir -p "$dst" && cp -a "$src"/libjs.a "$src"/libv8.a "$src"/libc++.a "$dst"/
    cmake -S . -B build-catalyst-x86_64  # reconfigure so find_library sees them
  fi
  python3 /path/to/TiBareKit/scripts/maccatalyst/toolchain_stamp.py \
    build-catalyst-$arch/_deps/github+holepunchto+bare-build/ios-*/libjs.a \
    build-catalyst-$arch/_deps/github+holepunchto+bare-build/ios-*/libv8.a \
    build-catalyst-$arch/_deps/github+holepunchto+bare-build/ios-*/libc++.a

  cmake --build build-catalyst-$arch --target bare_kit --config RelWithDebInfo
  # NOTE: if cmake re-fetches prebuilds (overwriting re-stamped ones), re-run
  # toolchain_stamp.py then re-link with `cmake --build` again.
done

# Lipo the two per-arch frameworks into a universal Catalyst framework.
rm -rf /tmp/BareKit.framework && mkdir /tmp/BareKit.framework
cp -a build-catalyst-arm64/apple/BareKit.framework/ /tmp/BareKit.framework/
lipo -create \
  build-catalyst-arm64/apple/BareKit.framework/Versions/A/BareKit \
  build-catalyst-x86_64/apple/BareKit.framework/Versions/A/BareKit \
  -output /tmp/BareKit.framework/Versions/A/BareKit

# Add the Catalyst slice to the xcframework.
cd /path/to/TiBareKit/ios/platform
xcodebuild -create-xcframework \
  -framework BareKit.xcframework/ios-arm64/BareKit.framework \
  -framework BareKit.xcframework/ios-arm64_x86_64-simulator/BareKit.framework \
  -framework /tmp/BareKit.framework \
  -output /tmp/BareKit.xcframework
mv BareKit.xcframework BareKit.xcframework.old
mv /tmp/BareKit.xcframework BareKit.xcframework
rm -rf BareKit.xcframework.old
```

### Android

The AAR is extracted into the module: `classes.jar` goes to `android/lib/bare-kit.jar`
(compiled into the module's classes) and the native libs go to
`android/platform/android/jniLibs/<abi>/libbare-kit.so` (bundled into the module's
AAR via Titanium's jniLibs support). The module's AAR is self-contained — no
app-side AAR needed.

```bash
cd /path/to/bare-kit
npm install                      # first time only
export ANDROID_HOME=<your-android-sdk>
export ANDROID_NDK_HOME=<your-android-sdk>/ndk/28.1.13356709
./gradlew :bare-kit:assembleRelease

# Extract the AAR into the module.
cd /path/to/TiBareKit/android
rm -f lib/bare-kit.jar
rm -rf platform/android/jniLibs
mkdir -p /tmp/barekit-aar-extract
unzip -o /path/to/bare-kit/android/build/outputs/aar/bare-kit-release.aar -d /tmp/barekit-aar-extract
cp /tmp/barekit-aar-extract/classes.jar lib/bare-kit.jar
mkdir -p platform/android/jniLibs
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  mkdir -p platform/android/jniLibs/$abi
  cp /tmp/barekit-aar-extract/jni/$abi/libbare-kit.so platform/android/jniLibs/$abi/
done
```
