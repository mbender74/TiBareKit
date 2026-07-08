# TiBareKit — Design Spec

**Date:** 2026-07-08
**Module ID:** `ti.barekit`
**Version:** 1.0.0
**Scope:** Wrap [bare-kit](https://github.com/holepunchto/bare-kit) for both iOS and Android as a Titanium module.

## Goal

Expose the bare-kit `Worklet` and `IPC` APIs to Titanium JavaScript so app developers can spawn isolated Bare worklet threads, communicate with them over IPC, and issue host→worklet `push` request/reply calls. The native side is a thin bridge; the JS side mirrors the native API 1:1 with `new`-style constructors.

## Non-goals

- Building bare-kit from source during `ti build`. Native binaries are prebuilt locally and checked into the module.
- High-level abstractions beyond the low-level mirror (no EventEmitter wrapper, no Promise wrapping of polling APIs). `react-native-bare-kit`-style sugar is intentionally out of scope.
- Layering `bare-rpc` or other schema messaging on top of the raw byte channel.

## Source layout

- **bare-kit source** (read-only reference): `/Users/marcbender/bare-kit`
  - iOS API header: `apple/BareKit/BareKit.h` — `BareWorklet`, `BareWorkletConfiguration`, `BareIPC`
  - Android API: `android/src/main/java/to/holepunch/bare/kit/Worklet.java`, `IPC.java`
  - Build: top-level `CMakeLists.txt`, fetches `bare@1.29.4` via cmake-fetch; iOS via `apple/CMakeLists.txt`, Android via `android/build.gradle` (NDK 28.x, CMake 4.0+)
- **Module repo**: `/Users/marcbender/Titanium-Modules/TiBareKit`
  - iOS scaffold: `ios/Classes/TiBarekitModule.{h,m}`, `ios/manifest`, `ios/module.xcconfig`, `ios/titanium.xcconfig`
  - Android scaffold: `android/src/ti/barekit/TiBareKitModule.java`, `android/manifest`, `android/build.gradle`, `android/root.build.gradle`
  - Existing example: `example/app.js` (skeleton — will be replaced)

## Architecture

Three layers per platform, identical JS surface:

1. **Native library (prebuilt, checked in).**
   - iOS: `ios/platform/BareKit.xcframework` (arm64 iphoneos + arm64/x86_64 iphonesimulator)
   - Android: `android/lib/bare-kit.aar` (arm64-v8a, armeabi-v7a, x86, x86_64)
   - Built once from `/Users/marcbender/bare-kit` via its Makefile/CMake; copied into the module; committed. No CMake run during `ti build`.

2. **Native bridge (module code).**
   - iOS: `TiBarekitModule` exports `createWorklet`/`createIPC` factories; proxies `TiBareWorkletProxy`, `TiBareIPCProxy` wrap `BareWorklet`/`BareIPC`.
   - Android: `TiBareKitModule` exports `createWorklet`/`createIPC` factories; proxies `TiBareWorkletProxy`, `TiBareIPCProxy` wrap `to.holepunch.bare.kit.Worklet`/`IPC`.
   - Marshalling: JS Ti.Blob ↔ NSData (iOS) / ByteBuffer (Android); JS String → UTF-8 bytes; integers passed straight through.
   - All callbacks (IPC `readable`/`writable`, async `read`/`write`, `push` completion) are dispatched to the platform main thread before firing JS:
     - iOS: `dispatch_async(dispatch_get_main_queue(), …)` from `BareIPC`'s internal queue; `push` completion via `NSOperationQueue.mainQueue`.
     - Android: `Handler.createAsync(Looper.getMainLooper()).post(…)`.

3. **JS API (CommonJS).** `assets/ti.barekit.js` exports `{ Worklet, IPC }`. Constructors call into native factories; the wrapper forms class-style `new` semantics over the returned proxies.

## JS API

```js
const { Worklet, IPC } = require('ti.barekit');

const worklet = new Worklet({ memoryLimit: 24 * 1024 * 1024, assets: '<optional path>' });

// Source: String | Ti.Blob | null (null + .bundle filename → bundle loader)
worklet.start('/app.js', "console.log('hi')", ['arg1', 'arg2']);
worklet.start('/my.bundle');                   // bundle loader
worklet.start('/my.bundle', null, ['--flag']);  // bundle + args

worklet.suspend();
worklet.suspend(5000);   // suspendWithLinger (ms)
worklet.resume();
worklet.terminate();

worklet.push(payloadBlobOrString, (reply /* Ti.Blob */, error /* String|null */) => { ... });

const ipc = new IPC(worklet);
ipc.readable = () => { const d = ipc.read(); /* Ti.Blob|null */ };
ipc.writable = () => { ipc.write(myBlobOrString); /* → bytesWritten:int */ };
ipc.read((data, error) => { ... });
ipc.write(myBlobOrString, (error) => { ... });
ipc.close();
```

### Constructor conventions
- `new Worklet(options?)` — `options: { memoryLimit?: int, assets?: string }`. Maps to `BareWorkletConfiguration` / `Worklet.Options`.
- `new IPC(worklet)` — couples to a running worklet.
- `push` accepts String (UTF-8 encoded) or Ti.Blob; reply is always Ti.Blob.
- Bundle loader: when `source` is `null` and `filename` ends in `.bundle`, the native side loads the file from the app's resources — iOS via `[worklet start:name ofType:@"bundle" inBundle:[NSBundle mainBundle] arguments:]`, Android via AssetManager + `worklet.start(filename, InputStream, arguments)`.

### Data types
- `read()` returns Ti.Blob or `null`.
- `write(data)` accepts Ti.Blob or String (UTF-8); returns bytes-written `int`.
- `push(payload, cb)` accepts Ti.Blob or String; reply is Ti.Blob.

### Error handling
- All callbacks receive an `error` argument (String on Android, NSError.localizedDescription on iOS).
- Uncaught exceptions / unhandled rejections inside a worklet follow bare-kit's default: they print to stderr and abort the host process. This is by design and documented; the module does not intercept it. Developers override `Bare.on('uncaughtException', …)` inside the worklet to recover.

## iOS bridge

**Prebuilt framework setup:**
- `ios/platform/BareKit.xcframework` checked in.
- `ios/module.xcconfig` appends:
  ```
  FRAMEWORK_SEARCH_PATHS = $(inherited) "$(SRCROOT)/platform"
  OTHER_LDFLAGS = $(inherited) -framework BareKit
  ```

**Classes (in `ios/Classes/`):**
- `TiBarekitModule.{h,m}` — existing module entry; export `createWorklet:(id)args` and `createIPC:(id)args` factory methods returning proxies.
- `TiBareWorkletProxy.{h,m}` — `KrollProxy` holding a `BareWorklet *`. Methods: `start`, `suspend`, `suspendWithLinger:` (mapped from JS `suspend(int)`), `resume`, `terminate`, `push:completion:`. Marshalling via `TiBlob` ↔ `NSData`. Bundle loader uses `start:name:ofType:inBundle:arguments:` when `source` is null and filename ends in `.bundle`.
- `TiBareIPCProxy.{h,m}` — `KrollProxy` holding a `BareIPC *`. Methods: `read`, `write:`, `readWithCompletion:`, `write:completion:`, `close`. Properties `readable`/`writable` are Kroll callbacks; the native `BareIPC.readable`/`writable` blocks dispatch to main before invoking them.

**Thread safety:** IPC callbacks fire on a dedicated `BareIPC` queue — proxy wraps with `dispatch_async(dispatch_get_main_queue(), …)`. `push` completion uses `NSOperationQueue.mainQueue`.

## Android bridge

**Prebuilt AAR setup:**
- `android/lib/bare-kit.aar` checked in.
- `android/build.gradle` adds: `dependencies { releaseImplementation files('lib/bare-kit.aar') }` (or a `flatDir`-based repo). The AAR packs the JNI `.so`s; `System.loadLibrary("bare-kit")` runs in `to.holepunch.bare.kit.Worklet`'s static initializer.

**Classes (in `android/src/ti/barekit/`):**
- `TiBareKitModule.java` — existing `@Kroll.module`; export `createWorklet(options)` and `createIPC(workletProxy)` factories. `@Kroll.onAppCreate` left empty (AAR handles `loadLibrary`).
- `TiBareWorkletProxy.java` — `KrollProxy` holding `to.holepunch.bare.kit.Worklet`. Methods: `start`, `suspend`, `suspend(int)`, `resume`, `terminate`, `push`. Marshalling: JS Ti.Blob → `ByteBuffer.allocateDirect`, JS String → UTF-8 `ByteBuffer`. Bundle loader uses `TiApplication`'s AssetManager + `worklet.start(filename, InputStream, arguments)`. All `PushCallback`s wrapped with `Handler.createAsync(Looper.getMainLooper())`.
- `TiBareIPCProxy.java` — `KrollProxy` holding `to.holepunch.bare.kit.IPC`. Methods: `read`, `write`, `read(callback)`, `write(data, callback)`, `close`. `readable`/`writable` set via `PollCallback`, wrapped to post on the main looper.

**Lifecycle:** `terminate()` nulls the worklet handle; subsequent calls throw. `IPC.close()` calls `destroy(handle)`.

## Build & packaging

**Prebuild (once, manual; documented in `README.md`):**
- iOS: `cd /Users/marcbender/bare-kit && make ios/BareKit.xcframework`, copy result to `TiBareKit/ios/platform/BareKit.xcframework`.
- Android: `cd /Users/marcbender/bare-kit && make android/bare-kit` (or `./gradlew :bare-kit:assembleRelease`), copy the `.aar` to `TiBareKit/android/lib/bare-kit.aar`.
- Binaries committed directly (LFS optional).

**Manifests:** both already present with `moduleid: ti.barekit`, `version: 1.0.0`. Architecture lists kept: iOS `arm64 x86_64`, Android `arm64-v8a armeabi-v7a x86 x86_64`. `timodule.xml` left default — no extra permissions (worklets run in-process).

**Build command:** `ti build -p ios --build-only` / `ti build -p android --build-only`. No CMake involved.

**JS wrapper (`assets/ti.barekit.js`):** `require('ti.barekit')` returns `{ Worklet, IPC }`. The wrapper calls native `createWorklet`/`createIPC` factories and presents class-style constructors so users write `new Worklet(...)`.

## Example app (`example/app.js`)

Replaces the skeleton. Demonstrates every API surface:

```js
import { Worklet, IPC } from 'ti.barekit';

const worklet = new Worklet({ memoryLimit: 24 * 1024 * 1024 });
const ipc = new IPC(worklet);

const src = `
  console.log('hello from the worklet');
  Bare.on('uncaughtException', (err) => {
    BareKit.IPC.write('FATAL: ' + err.message);
  });
  BareKit.IPC.on('data', (data) => {
    BareKit.IPC.write('echo: ' + data.toString());
  });
`;

worklet.start('/app.js', src, ['--flag']);

ipc.readable = () => {
  const d = ipc.read();
  if (d) Ti.API.info('[polling] worklet: ' + d.toString());
};
ipc.writable = () => {
  ipc.write('ping from main (polling)');
  ipc.writable = null;
};

ipc.write('async hello', (err) => {
  if (err) return Ti.API.error('write err: ' + err);
  ipc.read((data, err) => {
    if (err) return Ti.API.error('read err: ' + err);
    Ti.API.info('[async] worklet: ' + data.toString());
  });
});

worklet.push('check', (reply, err) => {
  if (err) return Ti.API.error('push err: ' + err);
  Ti.API.info('[push] reply: ' + reply.toString());
});

// Bundle loader (uncomment when app.bundle is present):
// const bundled = new Worklet();
// bundled.start('/app.bundle', null, ['--prod']);

setTimeout(() => { worklet.suspend(); Ti.API.info('suspended'); }, 2000);
setTimeout(() => { worklet.resume();  Ti.API.info('resumed');  }, 4000);
setTimeout(() => { worklet.terminate(); Ti.API.info('terminated'); }, 6000);

const win = Ti.UI.createWindow({ backgroundColor: '#fff' });
win.add(Ti.UI.createLabel({ text: 'TiBareKit — see console for output' }));
win.open();
```

## Documentation (`documentation/index.md`)

Covers:
- Installation (`<modules><module version="1.0.0">ti.barekit</module></modules>` in `tiapp.xml`).
- `require('ti.barekit')` / ES import.
- Worklet lifecycle: `start`, `suspend`, `suspend(linger)`, `resume`, `terminate`.
- IPC: polling (`readable`/`writable`/`read`/`write`) and async (`read(cb)`/`write(data, cb)`), `close`.
- `push` request/reply.
- Bundle loader (`.bundle` filename + `null` source).
- `memoryLimit` / `assets` configuration.
- uncaughtException behavior — link to bare-kit README, include the `Bare.on('uncaughtException', …)` snippet.

## Verification

- `ti build -p ios --build-only` and `ti build -p android --build-only` produce a packaged module zip without errors.
- `ti build -p ios` (and `-p android`) with the example app: console shows `hello from the worklet`, polling + async IPC round-trips, and a `push` reply. Lifecycle log lines appear at 2s/4s/6s.
- Manual prebuild: developer runs the documented make/gradle step whenever `ios/platform/` or `android/lib/` is missing or stale.

## Open items / out of scope

- CI automation for prebuild refresh (manual for now).
- `Ti.Buffer` type support (deferred — Ti.Blob + String covers the common cases).
- Promise-based sugar / EventEmitter wrapper on top of IPC (deferred — low-level mirror first).
- Windows / Linux targets (bare-kit supports them, but the Titanium module targets iOS + Android only).