# TiBareKit Android Hyperswarm Spike -- Design

**Date:** 2026-07-10
**Status:** Design (pending implementation plan)
**Counterpart:** the iOS hyperswarm spike (commits 2be8eed..d0bdae0 on `main`).

## Goal

Get the `BareKitDemo` hyperswarm spike running on an Android emulator,
matching the iOS spike's four success criteria, with the Android
emulator and the existing iOS simulator as the two peers joining the
same hyperswarm topic and round-tripping a message (Android <-> iOS).

This proves the `ti.barekit` module's native runtime path works on
Android (sodium-native + udx-native `.bare` addons dlopen'd by the Bare
worklet) and that the IPC + hyperswarm bridge interoperates across
platforms.

## Starting point (already built -- no work needed)

The Android module is substantially built. These exist and are real, not
stubs:

- `android/src/ti/barekit/TiBareWorkletProxy.java` -- wrapper over
  `to.holepunch.bare.kit.Worklet`. Maps `memoryLimit`/`assets` options,
  handles `.bundle` loading from APK assets, `push` with
  TiBlob/ByteBuffer conversion + main-looper callback dispatch.
- `android/src/ti/barekit/TiBareIPCProxy.java` -- wrapper over
  `to.holepunch.bare.kit.IPC`. `setReadable`/`setWritable`/`read`/
  `write`/`close`.
- `lib/bare-kit.jar` + `platform/android/jniLibs/{arm64-v8a,
  armeabi-v7a,x86,x86_64}/libbare-kit.so` -- prebuilt, 4 ABIs shipped.
- sodium-native + udx-native prebuilds for `android-arm`,
  `android-arm64`, `android-ia32`, `android-x64` in
  `DemoApp/BareKitDemo/worklet/node_modules/<pkg>/prebuilds/`.
- `DemoApp/BareKitDemo/worklet/spike.js` + `Resources/app.js` -- the
  spike's worklet + UI/IPC bridging. Platform-agnostic; run unchanged
  on Android.

## What the design adds

Four changes, scoped to the spike.

### 1. `TiBareKitModule.java` -- `createWorklet` / `createIPC` factories

The module class is still the auto-generated scaffold (`example()`,
`getExampleProp`). It does not expose the factory methods that let JS
construct `new Worklet(...)` / `new IPC(worklet)`. This is the single
blocking gap: without the factories, the spike's JS cannot create the
worklet or the IPC channel on Android.

Add two factory methods mirroring the iOS `TiBarekitModule.m`
`createWorklet:` / `createIPC:`:

- `createWorklet(options)` -- returns a `TiBareWorkletProxy` configured
  with the options dict (`memoryLimit`, `assets`).
- `createIPC(worklet)` -- returns a `TiBareIPCProxy` attached to the
  given worklet proxy; `[NSNull null]` / `null` if the argument is not a
  worklet proxy.

### 2. `TiBareIPCProxy.java` `setWritable` -- one-shot pattern

The iOS spike found a ~170 MB/s idle memory leak: the native
`BareIPC` writable source is a level-triggered poll that fires
continuously while the outgoing fd has buffer space (always, when
idle), and the wrapper's `setWritable` block stayed armed forever,
dispatching to the main thread + invoking the JS callback on every
fire. The iOS fix (commit `09726b0`) deregisters the native writable
block on first fire, before delivering the JS callback -- matching
BareKit's own async `read:` self-deregister pattern.

Apply the same one-shot pattern to `TiBareIPCProxy.java setWritable`
proactively. The Java `to.holepunch.bare.kit.IPC` uses an analogous
level-triggered mechanism; without the fix, Android would re-introduce
the same leak. The `ipc.writable` JS callback delivers exactly one
"ready to write" notification; if a consumer needs another signal, it
reassigns `ipc.writable`. This is a semantic-preserving change.

### 3. `plugin.js` -- Android branch (all-4-ABIs, full B)

The build plugin (`plugins/tibarekit-spike/1.0.0/plugin.js`) is
iOS-only: it hardcodes `const host = 'ios-arm64-simulator'` and
produces a single `Resources/spike.bundle`. Add an Android branch.

`bare-pack --host <host>` is host-specific: the bundle's bytecode and
its `--offload-addons` addon-resolution paths target one host. For
all-4-ABIs, the plugin runs `bare-pack` four times, once per android
host:

| Android ABI | bare-pack host | bundle output |
|-------------|----------------|---------------|
| `arm64-v8a` | `android-arm64` | `Resources/spike-android-arm64.bundle` |
| `armeabi-v7a` | `android-arm` | `Resources/spike-android-arm.bundle` |
| `x86` | `android-ia32` | `Resources/spike-android-ia32.bundle` |
| `x86_64` | `android-x64` | `Resources/spike-android-x64.bundle` |

Each run uses `--offload-addons` so the `.bare` prebuilds are written as
real files next to the bundle and file: URLs are recorded in the bundle.
The plugin then copies each host's `.bare` prebuilds from
`worklet/node_modules/<pkg>/prebuilds/<host>/` to
`Resources/node_modules/<pkg>/prebuilds/<host>/` so every ABI's native
addons ship in the APK. All four bundles + all four prebuild sets are
packaged.

The iOS branch stays unchanged (single `spike.bundle`,
`ios-arm64-simulator`).

Branch selection: the plugin reads `cli.argv.platform` (`'iphone'` vs
`'android'`) and runs the corresponding branch. Shared setup (worklet
dir, resources dir, the `bare-pack` invocation shape, error handling)
is factored out so the two branches differ only in host list + output
naming.

### 4. `app.js` -- runtime ABI selection

`app.js` currently calls `worklet.start('/spike.bundle', null, [])`
unconditionally. On Android this must start the bundle matching the
runtime ABI. Add a platform check + ABI-to-host mapping:

- iOS: `worklet.start('/spike.bundle', null, [])` (unchanged).
- Android: read the runtime ABI, map to the bare-pack host, start
  `/spike-<host>.bundle`.

Mapping (`Ti.Platform` exposes the ABI; the exact property is
verified during implementation -- likely `Ti.Platform.architecture`):
`arm64-v8a` -> `android-arm64`, `armeabi-v7a` -> `android-arm`,
`x86` -> `android-ia32`, `x86_64` -> `android-x64`.

If the ABI is unrecognized, log a diagnostic and fall back to
`android-arm64` (the emulator target + the most common device ABI).
Do not crash -- a misread platform property must not kill the worklet
at startup.

### Module config

Drop `android/manifest` `minsdk` from `14.0.0` to `13.3.0` to match
the iOS module + the demo's pinned SDK. Runtime requirement (not
config): the Android emulator must be API 31+ because bare-kit
upstream sets `minSdk 31` (Android 12).

## Data flow

Build-time (Android): the plugin's `build.pre.compile` hook detects
`cli.argv.platform === 'android'`, loops over the four android hosts,
runs `bare-pack --host <host> --offload-addons --out
Resources/spike-<host>.bundle spike.js` from the worklet dir, then
copies each host's `.bare` prebuilds into
`Resources/node_modules/<pkg>/prebuilds/<host>/`. The four bundles +
four prebuild sets ship in the APK `assets/`.

Runtime: `app.js` detects platform + ABI, picks the bundle, calls
`worklet.start(bundle, null, [])`. The Android `TiBareWorkletProxy`
resolves the `.bundle` from APK assets (already handled by the proxy)
and the bare-kit runtime dlopens the matching `.bare` addons. From
there the data flow is identical to iOS:

`ipc.write(text)` -> worklet `BareKit.IPC.on('data')` -> `activeStream.write(data)` -> peer worklet `framed.on('data')` -> `BareKit.IPC.write('peer: ' + msg)` -> peer main `ipc.readable` -> auto-echo `sendToWorklet('echo: ' + payload)` -> back to originator, echo guard stops amplification.

## Error handling

No new error-handling code. The spike's four diagnostics live in
`spike.js` + `app.js` and are platform-agnostic; they run unchanged on
Android:

- 15 s peer-discovery `TIMEOUT` (worklet).
- `FATAL` / `STACK` uncaught-exception forwarder (worklet).
- `WATCHDOG` -- fires only if the worklet produced zero IPC output for
  30 s (silent crash, e.g. a native addon crash during load).
- `IPC ERR` -- `sendToWorklet` surfaces native `{error}` results from
  `ipc.write`.

The one Android-specific error path: the ABI-to-bundle mapping's
unrecognized-ABI fallback (log + fall back to `android-arm64`, do not
crash).

The proactive `setWritable` one-shot is itself an error-handling fix
(prevents the continuous-fire leak that would otherwise drive
unbounded native memory growth).

## Verification (success criteria)

Peer setup: one Android arm64 emulator (API 31+) + the existing iOS
simulator, both joining `tibarekit-spike-v1`.

The spike is proven when all four hold:

1. The Android app launches without crashing (native addons loaded on
   Android -- sodium-native + udx-native `.bare` dlopen'd by the Bare
   worklet).
2. No `FATAL:` line in either the Android or iOS log.
3. `connection opened` fires on both sides within 15 s.
4. A message round-trips Android <-> iOS (A -> B -> A), with the echo
   guard stopping `echo: echo: ...` amplification.

Plus one leak-fix check: Android RSS flat over ~60 s at idle (confirms
the proactive `setWritable` one-shot holds on Android). The `appmem`
reporter already logs `Ti.Platform.availableMemory` every 5 s on
Android.

## Out of scope

- The 3 non-arm64 bundles' runtime verification (they build but only
  `android-arm64` is exercised by the emulator).
- Real-device signing + deployment.
- Android backgrounding / lifecycle behavior (`suspend` / `resume` /
  `terminate` exist on the proxy but are not part of the spike's
  success criteria).
- The full pear-chat port (autobase, blind-pairing, hyperdb, chat UI)
  -- separate later cycle.
- iOS-side changes beyond what the cross-platform echo exercises
  (the iOS spike is done).

## Key technical findings (carry into the plan)

- `bare-pack --host <host>` is host-specific: the bundle's bytecode +
  `--offload-addons` resolution paths target one host. All-4-ABIs =
  4 `bare-pack` runs + 4 bundles + runtime ABI selection in `app.js`.
- The `.bare` addon prebuilds for all 4 android targets already exist
  in `node_modules` -- the plugin copies them, it does not build them.
- The Android `TiBareWorkletProxy` already resolves `.bundle` from APK
  assets -- no new asset-loading code is needed.
- The iOS writable-leak fix (`09726b0`) must be mirrored on the Java
  side proactively; do not re-discover the leak.
- bare-kit upstream `minSdk 31` (Android 12) -- the emulator must be
  API 31+.