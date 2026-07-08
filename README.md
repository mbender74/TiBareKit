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

To use your module in code, you will need to require it.

### ES6+ (recommended)

```js
import MyModule from 'ti.barekit';
MyModule.foo();
```

### ES5

```js
var MyModule = require('ti.barekit');
MyModule.foo();
```

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

### Android

```bash
cd /path/to/bare-kit
npm install                      # first time only
export ANDROID_HOME=<your-android-sdk>
export ANDROID_NDK_HOME=<your-android-sdk>/ndk/28.1.13356709
./gradlew :bare-kit:assembleRelease
cp android/build/outputs/aar/bare-kit-release.aar \
   /path/to/TiBareKit/android/lib/bare-kit.aar
```
