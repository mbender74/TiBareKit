# Android Hyperswarm Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get the `BareKitDemo` hyperswarm spike running on an Android arm64 emulator, cross-platform echoing a message with the existing iOS simulator (Android <-> iOS), proving the `ti.barekit` native runtime path works on Android.

**Architecture:** The Android module is already built (Java proxies + 4-ABI `libbare-kit.so` + sodium-native/udx-native `.bare` prebuilds for all 4 android hosts). Four targeted changes close the spike: (1) override `handleCreationArgs` in `TiBareIPCProxy` so `new IPC(worklet)` actually wires the native IPC (the auto-generated Kroll factory early-returns on a bare-proxy arg); (2) apply the one-shot `setWritable` fix proactively so Android does not re-introduce the iOS writable-leak; (3) extend the build plugin with an Android branch that runs `bare-pack` for all 4 android hosts and copies each host's `.bare` prebuilds; (4) select the runtime ABI's bundle in `app.js`. Plus a `minsdk` drop to match iOS.

**Tech Stack:** Titanium SDK 13.3.0, `ti.barekit` Android module (Java + `to.holepunch.bare.kit` JNI), `bare-pack` (host-specific bundling + `--offload-addons`), hyperswarm/framed-stream/sodium-native/udx-native, Android emulator API 31+ (bare-kit upstream `minSdk 31`).

## Global Constraints

- Titanium SDK **13.3.0** (pinned in `tiapp.xml` `<sdk-version>`; module `minsdk` must be `13.3.0`, not `14.0.0`).
- bare-kit upstream sets `minSdk 31` (Android 12) -- the Android emulator MUST be API 31+.
- All 4 Android ABIs ship: `arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64` (`android/manifest` `architectures`).
- bare-pack host names (verbatim): `android-arm64`, `android-arm`, `android-ia32`, `android-x64`. ABI-to-host mapping: `arm64-v8a` -> `android-arm64`, `armeabi-v7a` -> `android-arm`, `x86` -> `android-ia32`, `x86_64` -> `android-x64`.
- Bundle naming: `Resources/spike-android-<host>.bundle` (one per android host). The iOS `Resources/spike.bundle` stays unchanged.
- `--offload-addons` is mandatory on every `bare-pack` run (the Bare bundle protocol does not extract embedded addons to disk before dlopen; without it, dlopen fails and the worklet SIGABRTs).
- Prebuilds copy source: `worklet/node_modules/<pkg>/prebuilds/<host>/`. Copy dest: `Resources/node_modules/<pkg>/prebuilds/<host>/`. The plugin copies; it does NOT build prebuilds.
- Pure ASCII in all authored files (no em-dashes -- use `--`; `titanium_prep` crashes on non-ASCII).
- Commit author: `mbender74 <marc_bender@icloud.com>` via `git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit`. NEVER append a `Co-Authored-By` trailer.
- Work on `main` branch (user consent given). Pre-existing uncommitted changes to `example/app.js` and `ios/Classes/TiBarekitModuleAssets.m` are the user's in-progress work -- leave untouched, do not modify or commit.
- `ipc.writable` is one-shot: it fires exactly once; a consumer that needs another signal reassigns `ipc.writable`. This matches the iOS fix (commit `09726b0`) and the module docs.
- `Ti.Platform.architecture` on Android returns `Build.SUPPORTED_ABIS[0]` -- a string like `arm64-v8a`/`armeabi-v7a`/`x86`/`x86_64` (verified in `titanium_mobile` `TiSessionMeta.java`). This is the runtime ABI source for `app.js`.
- No unit-test framework exists for this Titanium native module + build plugin + JS app. Each code task's "verify" step is a build/compile check; the end-to-end spike verification is the final task.

---

### Task 1: `TiBareIPCProxy.handleCreationArgs` -- make `new IPC(worklet)` wire the native IPC

**Files:**
- Modify: `/Users/marcbender/Titanium-Modules/TiBareKit/android/src/ti/barekit/TiBareIPCProxy.java` (add `handleCreationArgs` override; keep existing `handleCreationDict`).

**Interfaces:**
- Consumes: `TiBareWorkletProxy.getWorklet()` (returns `to.holepunch.bare.kit.Worklet`) -- already defined in `TiBareWorkletProxy.java:26`.
- Produces: a non-null `ipc` field on every `TiBareIPCProxy` created via `new IPC(worklet)`, so `setReadable`/`setWritable`/`read`/`write`/`close` function. Later tasks (Task 2 onward) rely on this.

**Context for the implementer:** The `@Kroll.proxy(creatableInModule = TiBareKitModule.class)` annotation auto-generates a `createIPC()` factory on the module. When JS does `new IPC(worklet)`, Kroll calls `KrollProxy.handleCreationArgs(module, [workletProxy])`. The base implementation (`titanium_mobile` `KrollProxy.java:187`) early-returns when `args[0]` is not a `HashMap`, so `handleCreationDict` is never called and `ipc` stays `null`. The fix is the idiomatic Titanium override pattern (see `titanium_mobile` `BufferProxy.java:54` for the same override). Do NOT touch `TiBareKitModule.java` -- the auto-generated factory is correct.

- [ ] **Step 1: Add the `handleCreationArgs` override**

Open `/Users/marcbender/Titanium-Modules/TiBareKit/android/src/ti/barekit/TiBareIPCProxy.java`. Add this method immediately after the existing `handleCreationDict` method (after the closing brace of `handleCreationDict`, before `private ByteBuffer toBuffer`):

```java
  // `new IPC(worklet)` passes the worklet proxy as args[0], NOT a dict. The base
  // KrollProxy.handleCreationArgs early-returns when args[0] is not a HashMap,
  // so handleCreationDict never runs and `ipc` stays null. Override to detect
  // the bare-worklet-arg case and construct the native IPC directly. Mirrors the
  // idiomatic Titanium pattern (titanium_mobile BufferProxy.handleCreationArgs).
  @Override
  public void handleCreationArgs(org.appcelerator.kroll.KrollModule createdInModule, Object[] args) {
    if (args != null && args.length > 0 && args[0] instanceof TiBareWorkletProxy) {
      ipc = new IPC(((TiBareWorkletProxy) args[0]).getWorklet());
      return;
    }
    super.handleCreationArgs(createdInModule, args);
  }
```

Leave `handleCreationDict` intact (it still handles the `new IPC({worklet: w})` dict form, which is not used by the spike but is the documented module API).

- [ ] **Step 2: Verify the module compiles**

Run from the module root:

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build --build-only --sdk 13.3.0 --platform android
```

Expected: build succeeds (the `dist/ti.barekit-android-1.0.0.zip` is produced, or at minimum no Java compile errors). A compile failure here means the override signature or imports are wrong -- fix before proceeding.

- [ ] **Step 3: Commit**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
git add android/src/ti/barekit/TiBareIPCProxy.java
git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit -m "fix(android): override TiBareIPCProxy.handleCreationArgs so new IPC(worklet) wires the native IPC"
```

---

### Task 2: `TiBareIPCProxy.setWritable` -- proactive one-shot fix (mirror iOS `09726b0`)

**Files:**
- Modify: `/Users/marcbender/Titanium-Modules/TiBareKit/android/src/ti/barekit/TiBareIPCProxy.java` (`setWritable` method only).

**Interfaces:**
- Consumes: `to.holepunch.bare.kit.IPC.writable(PollCallback)` and `IPC.writable(null)` (the deregister call) -- defined in `/Users/marcbender/bare-kit/android/src/main/java/to/holepunch/bare/kit/IPC.java:77-82`. `IPC.writable(null)` sets the field to null and calls `update()` which stops the native writable poll.
- Produces: `ipc.writable` JS callback fires exactly once per assignment (one-shot). Task 4's `app.js` already codes to this contract (`writableFired` guard at app.js:66).

**Context for the implementer:** The iOS spike found a ~170 MB/s idle memory leak: the native `BareIPC` writable source is level-triggered and fires continuously while the outgoing fd has buffer space (always, when idle); the wrapper's `setWritable` block stayed armed forever, dispatching to the main thread + invoking the JS callback on every fire. The iOS fix (commit `09726b0`) deregisters the native writable block on first fire, before delivering the JS callback. The Java `to.holepunch.bare.kit.IPC` uses an analogous level-triggered mechanism (`IPC.java:77-82` + native `update`). Apply the same one-shot proactively so Android does not re-discover the leak. This is semantic-preserving: `ipc.writable` delivers exactly one "ready to write" notification; a consumer that needs another signal reassigns `ipc.writable`.

- [ ] **Step 1: Replace `setWritable` with the one-shot version**

Open `/Users/marcbender/Titanium-Modules/TiBareKit/android/src/ti/barekit/TiBareIPCProxy.java`. Replace the existing `setWritable` method (the whole method, `@Kroll.setProperty @Kroll.method` annotation through the closing brace) with:

```java
  @Kroll.setProperty @Kroll.method
  public void setWritable(KrollFunction cb) {
    writableCb = cb;
    if (ipc == null) return;
    ipc.writable(() -> {
      // One-shot: deregister the native writable poll before delivering the JS
      // callback. The native writable source is level-triggered -- it fires
      // continuously while the outgoing fd has buffer space (always, when idle).
      // Leaving it armed makes this callback + the main-looper dispatch + the
      // KrollFunction call run on every fire -> unbounded native memory growth
      // (~170 MB/s observed on iOS before fix 09726b0). Mirrors the iOS one-shot.
      ipc.writable(null);
      if (writableCb != null) {
        new Handler(Looper.getMainLooper()).post(() ->
          writableCb.call(getKrollObject(), new Object[] { this }));
      }
    });
  }
```

Do NOT change `setReadable` -- the readable source is level-triggered on data buffered (fires only when there is data), so continuous-fire is the correct behavior there.

- [ ] **Step 2: Verify the module compiles**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build --build-only --sdk 13.3.0 --platform android
```

Expected: build succeeds. If it fails, the `ipc.writable(null)` call or the lambda is malformed -- fix before proceeding.

- [ ] **Step 3: Commit**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
git add android/src/ti/barekit/TiBareIPCProxy.java
git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit -m "fix(android): one-shot TiBareIPCProxy.setWritable to prevent level-triggered writable leak (mirrors ios 09726b0)"
```

---

### Task 3: `android/manifest` -- drop `minsdk` to 13.3.0

**Files:**
- Modify: `/Users/marcbender/Titanium-Modules/TiBareKit/android/manifest` (`minsdk` line only).

**Interfaces:**
- Consumes: nothing.
- Produces: the Android module declares `minsdk 13.3.0`, matching the iOS module (`ios/manifest` `minsdk: 13.3.0`) and the demo's pinned `<sdk-version>13.3.0</sdk-version>`. Required so `ti build --sdk 13.3.0 --platform android` does not reject the module for a too-high `minsdk`.

- [ ] **Step 1: Edit the `minsdk` line**

In `/Users/marcbender/Titanium-Modules/TiBareKit/android/manifest`, change:

```
minsdk: 14.0.0
```

to:

```
minsdk: 13.3.0
```

Do NOT change any other line (`architectures`, `version`, `moduleid`, `guid`, etc. stay verbatim).

- [ ] **Step 2: Verify the module builds against 13.3.0**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build --build-only --sdk 13.3.0 --platform android
```

Expected: build succeeds with no "module requires SDK X or later" warning. If `ti` complains the module `minsdk` is higher than the build SDK, the edit did not apply -- re-check.

- [ ] **Step 3: Commit**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
git add android/manifest
git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit -m "chore(android): drop minsdk 14.0.0 -> 13.3.0 to match ios module + demo"
```

---

### Task 4: Build plugin -- Android branch (4 bare-pack runs + prebuild copy)

**Files:**
- Modify: `/Users/marcbender/Titanium-Modules/TiBareKit/DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/plugin.js`.

**Interfaces:**
- Consumes: `bare-pack` on PATH (the `bare-pack --host <host> --offload-addons --out <bundle> spike.js` invocation shape already used by the iOS branch). `cli.argv.platform` (`'android'` vs `'iphone'`) for branch selection. The prebuild source tree `worklet/node_modules/<pkg>/prebuilds/<host>/*.bare` (verified present for `sodium-native` + `udx-native` across all 4 android hosts).
- Produces, on Android builds: `Resources/spike-android-arm64.bundle`, `Resources/spike-android-arm.bundle`, `Resources/spike-android-ia32.bundle`, `Resources/spike-android-x64.bundle`, plus `Resources/node_modules/<pkg>/prebuilds/<host>/*.bare` for each of the 4 hosts. Task 5's `app.js` selects among these bundles at runtime.

**Context for the implementer:** `bare-pack --host <host>` is host-specific: the bundle's bytecode AND its `--offload-addons` addon-resolution paths target one host. All-4-ABIs means 4 `bare-pack` runs. The prebuilds already exist in `node_modules`; the plugin copies them to `Resources/` so they ship in the APK. The iOS branch (the existing `host = 'ios-arm64-simulator'` single-run path) stays unchanged. Branch selection reads `cli.argv.platform`. Factor shared setup (worklet dir, resources dir, the `bare-pack` invocation shape, error handling) so the two branches differ only in host list + output naming.

- [ ] **Step 1: Read the current plugin**

Read `/Users/marcbender/Titanium-Modules/TiBareKit/DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/plugin.js` in full. The current file is iOS-only: it hardcodes `const host = 'ios-arm64-simulator'`, runs `bare-pack` once, produces `Resources/spike.bundle`. The whole logic lives inside `cli.on('build.pre.compile', { priority: 900, async post() { ... } })`.

- [ ] **Step 2: Rewrite the plugin with both branches**

Replace the entire file with:

```js
// Titanium build plugin: runs bare-pack to produce Resources/spike*.bundle
// + offloads native addon .bare prebuilds to Resources/node_modules/ before
// the Titanium compile step.
//
// --offload-addons writes .bare files as real files next to the bundle
// (Resources/node_modules/<pkg>/prebuilds/<host>/<addon>.bare) and records
// file: URLs in the bundle that resolve to those real paths at runtime.
// This is required because the Bare bundle protocol does not extract
// embedded addons to disk before dlopen -- the .bare must be a real file
// at a path the bundle can resolve. Without --offload-addons, the .bare is
// embedded in the bundle as a virtual path, dlopen fails, and the worklet
// aborts (SIGABRT).
//
// iOS: one host (ios-arm64-simulator), one bundle (Resources/spike.bundle).
// Android: all 4 ABIs -- bare-pack runs once per android host, producing
// Resources/spike-android-<host>.bundle for each. The plugin copies each
// host's .bare prebuilds from worklet/node_modules/<pkg>/prebuilds/<host>/
// to Resources/node_modules/<pkg>/prebuilds/<host>/ so every ABI's native
// addons ship in the APK. app.js picks the bundle matching the runtime ABI.
//
// Note on mechanism: SDK 14.0.0 loads project plugins via cli.scanHooks() on
// the plugin's hooks/ directory (see node-titanium-sdk/lib/titanium.js
// loadPlugins). hooks/tibarekit-spike.js re-exports this module's id/init so
// the loader picks it up. The package.json "type": "module" makes the .js
// files ESM, which is what scanHooks (await import()) expects in 14.0.0.
import { execSync } from 'node:child_process'
import path from 'node:path'
import fs from 'node:fs'

export const id = 'tibarekit-spike'

// Map each android ABI to its bare-pack host + bundle name. All 4 ship in the
// APK; app.js selects the one matching the runtime ABI.
const ANDROID_TARGETS = [
  { host: 'android-arm64', bundle: 'spike-android-arm64.bundle' },
  { host: 'android-arm',   bundle: 'spike-android-arm.bundle' },
  { host: 'android-ia32',  bundle: 'spike-android-ia32.bundle' },
  { host: 'android-x64',   bundle: 'spike-android-x64.bundle' }
]

// Copy every <pkg>/prebuilds/<host>/*.bare from the worklet node_modules into
// Resources/node_modules/<pkg>/prebuilds/<host>/ so the offloaded file: URLs
// in the bundle resolve to real files in the APK assets.
function copyPrebuilds(workletDir, resourcesDir, host) {
  const nmSrc = path.join(workletDir, 'node_modules')
  const nmDst = path.join(resourcesDir, 'node_modules')
  if (!fs.existsSync(nmSrc)) return
  for (const pkg of fs.readdirSync(nmSrc)) {
    const pbSrc = path.join(nmSrc, pkg, 'prebuilds', host)
    if (!fs.existsSync(pbSrc)) continue
    const pbDst = path.join(nmDst, pkg, 'prebuilds', host)
    fs.mkdirSync(pbDst, { recursive: true })
    for (const f of fs.readdirSync(pbSrc)) {
      if (!f.endsWith('.bare')) continue
      fs.copyFileSync(path.join(pbSrc, f), path.join(pbDst, f))
    }
  }
}

export function init(logger, config, cli) {
  cli.on('build.pre.compile', {
    priority: 900,
    async post() {
      const projectDir = cli.argv['project-dir']
      const workletDir = path.join(projectDir, 'worklet')
      const resourcesDir = path.join(projectDir, 'Resources')
      const platform = cli.argv.platform

      logger.info('tibarekit-spike: packing worklet bundle + offloading addons...')

      try {
        if (platform === 'android') {
          for (const t of ANDROID_TARGETS) {
            const bundlePath = path.join(resourcesDir, t.bundle)
            execSync(
              `bare-pack --host ${t.host} --offload-addons --out "${bundlePath}" spike.js`,
              { stdio: 'inherit', cwd: workletDir }
            )
            if (!fs.existsSync(bundlePath)) {
              throw new Error('bare-pack did not produce ' + t.bundle)
            }
            copyPrebuilds(workletDir, resourcesDir, t.host)
            logger.info('tibarekit-spike: ' + t.bundle + ' ready (host ' + t.host + ')')
          }
        } else {
          // iOS branch: single host, single bundle (unchanged from the original
          // spike plugin).
          const host = 'ios-arm64-simulator'
          const bundlePath = path.join(resourcesDir, 'spike.bundle')
          execSync(
            `bare-pack --host ${host} --offload-addons --out "${bundlePath}" spike.js`,
            { stdio: 'inherit', cwd: workletDir }
          )
          if (!fs.existsSync(bundlePath)) {
            throw new Error('bare-pack did not produce spike.bundle')
          }
          logger.info('tibarekit-spike: bundle ready at ' + bundlePath)
        }
      } catch (err) {
        logger.error('tibarekit-spike: ' + err.message)
        throw err
      }
    }
  })
}
```

- [ ] **Step 3: Verify the plugin produces all 4 Android bundles + copies prebuilds**

Run a build-only for Android (this exercises the plugin's Android branch):

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build --project-dir DemoApp/BareKitDemo --platform android --build-only --sdk 13.3.0
```

Expected: the log shows four `tibarekit-spike: spike-android-<host>.bundle ready (host android-<host>)` lines (one per host). Then verify the artifacts exist:

```bash
ls DemoApp/BareKitDemo/Resources/spike-android-*.bundle
ls DemoApp/BareKitDemo/Resources/node_modules/sodium-native/prebuilds/android-arm64/
ls DemoApp/BareKitDemo/Resources/node_modules/udx-native/prebuilds/android-arm64/
```

Expected: 4 `spike-android-*.bundle` files; `sodium-native.bare` + `udx-native.bare` present under `android-arm64`. If a bundle is missing, the `bare-pack` run for that host failed -- check the build log. If the `.bare` files are missing under `Resources/node_modules/.../android-arm64/`, `copyPrebuilds` did not run -- check the `prebuilds/android-arm64/` source exists in `worklet/node_modules`.

- [ ] **Step 4: Commit**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
git add DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/plugin.js
git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit -m "feat(spike): android build-plugin branch -- 4 bare-pack runs + prebuild copy for all ABIs"
```

---

### Task 5: `app.js` -- runtime ABI selection (Android starts the matching bundle)

**Files:**
- Modify: `/Users/marcbender/Titanium-Modules/TiBareKit/DemoApp/BareKitDemo/Resources/app.js` (the `worklet.start(...)` call only).

**Interfaces:**
- Consumes: `Ti.Platform.osname` (`'android'` on Android; `'iphone'`/`'ipad'` on iOS) and `Ti.Platform.architecture` (on Android, `Build.SUPPORTED_ABIS[0]` -- e.g. `arm64-v8a`; verified in `titanium_mobile` `TiSessionMeta.java`). The 4 `Resources/spike-android-<host>.bundle` files produced by Task 4.
- Produces: on Android, `worklet.start('/spike-android-<host>.bundle', null, [])` with the host matching the runtime ABI; on iOS, `worklet.start('/spike.bundle', null, [])` unchanged.

**Context for the implementer:** `app.js` currently calls `worklet.start('/spike.bundle', null, [])` unconditionally. On Android this must start the bundle matching the runtime ABI (each bundle's bytecode + addon paths target one host). The ABI-to-host mapping is fixed. If the ABI is unrecognized, log a diagnostic and fall back to `android-arm64` (the emulator target + the most common device ABI) -- do NOT crash; a misread platform property must not kill the worklet at startup.

- [ ] **Step 1: Read the current `app.js`**

Read `/Users/marcbender/Titanium-Modules/TiBareKit/DemoApp/BareKitDemo/Resources/app.js`. The relevant lines are 36-37:

```js
const worklet = new Worklet({ memoryLimit: 64 * 1024 * 1024 })
worklet.start('/spike.bundle', null, [])
```

- [ ] **Step 2: Replace the `worklet.start` call with platform-aware bundle selection**

Replace lines 36-37 of `app.js` (the `const worklet = ...` + `worklet.start(...)` pair) with:

```js
const worklet = new Worklet({ memoryLimit: 64 * 1024 * 1024 })

// Pick the prebuilt bundle. iOS: single Resources/spike.bundle (ios-arm64-simulator).
// Android: one of Resources/spike-android-<host>.bundle, selected by runtime ABI.
// Each bare-pack bundle's bytecode + --offload-addons paths target one host, so
// starting the wrong host's bundle fails to dlopen the .bare addons. Unrecognized
// ABI falls back to android-arm64 (emulator target + most common device ABI) --
// do not crash on a misread platform property.
let bundleName
if (Ti.Platform.osname === 'android') {
  const abiToHost = {
    'arm64-v8a': 'android-arm64',
    'armeabi-v7a': 'android-arm',
    'x86': 'android-ia32',
    'x86_64': 'android-x64'
  }
  const host = abiToHost[Ti.Platform.architecture]
  if (!host) {
    log('unknown ABI: ' + Ti.Platform.architecture + ', falling back to android-arm64')
  }
  bundleName = '/spike-' + (host || 'android-arm64') + '.bundle'
} else {
  bundleName = '/spike.bundle'
}
worklet.start(bundleName, null, [])
```

Leave the rest of `app.js` unchanged -- the `log` helper (defined at the top of the file) is already in scope here. If `log` is NOT yet defined at this point in the file (it is defined at the top, lines 5-16, so it is), move the `bundleName` selection after the `log` helper instead of using it. (It is defined above; no move needed.)

- [ ] **Step 3: Verify the iOS build still works (regression check)**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build --project-dir DemoApp/BareKitDemo --platform ios --build-only --sdk 13.3.0
```

Expected: build succeeds. The iOS branch of `app.js` is unchanged behaviorally (`bundleName = '/spike.bundle'`), so this should pass. If it fails, the edit altered more than the `worklet.start` region -- re-check the diff.

- [ ] **Step 4: Commit**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
git add DemoApp/BareKitDemo/Resources/app.js
git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit -m "feat(spike): app.js selects runtime-ABI bundle on android (falls back to android-arm64)"
```

---

### Task 6: Build + runtime verification (Android arm64 emulator <-> iOS simulator)

**Files:**
- No file changes. This is the spike's end-to-end verification.

**Interfaces:**
- Consumes: Tasks 1-5 (Android module builds, plugin produces 4 bundles + prebuilds, app.js selects the right bundle, `minsdk` matches).
- Produces: evidence that the 4 success criteria + the leak-fix check hold. This is the spike's proof.

**Context for the implementer:** This is a manual spike verification, not an automated test. The spike is proven when all 4 success criteria hold (matching the iOS spike) plus the RSS-flat leak check. Peer setup: one Android arm64 emulator (API 31+) + the existing iOS simulator, both joining `tibarekit-spike-v1`. The spike's diagnostics (15 s `TIMEOUT`, `FATAL`/`STACK` forwarder, `WATCHDOG`, `IPC ERR`) are platform-agnostic and run unchanged on Android.

- [ ] **Step 1: Build the Android module**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build --build-only --sdk 13.3.0 --platform android
```

Expected: produces `android/dist/ti.barekit-android-1.0.0.zip`. If this fails, Tasks 1-3 have a compile error -- do not proceed until it builds.

- [ ] **Step 2: Install the Android module into the demo's local modules dir**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit/DemoApp/BareKitDemo
unzip ../../android/dist/ti.barekit-android-1.0.0.zip -d modules/android/ti.barekit/1.0.0
# the zip nests modules/android/ti.barekit/1.0.0/<contents>; flatten:
cp -R modules/android/ti.barekit/1.0.0/modules/android/ti.barekit/1.0.0/* \
  modules/android/ti.barekit/1.0.0/ 2>/dev/null || true
rm -rf modules/android/ti.barekit/1.0.0/modules
```

Expected: `modules/android/ti.barekit/1.0.0/` contains the module contents (the `.jar`, `libbare-kit.so` under each ABI's `lib/` subdir, `timodule.xml`, etc.) with no nested `modules/` dir. (Same flatten pattern the iOS README documents for the iOS module.)

- [ ] **Step 3: Boot an Android arm64 emulator (API 31+)**

```bash
# List available AVDs and boot an arm64 API 31+ one.
$ANDROID_HOME/emulator/emulator -list-avds
$ANDROID_HOME/emulator/emulator -avd <arm64-api31+-avd> -no-snapshot-load &
```

Expected: the emulator boots to the home screen. If no arm64 API 31+ AVD exists, create one via Android Studio's Device Manager or `avdmanager create avd -n tibarekit-arm64 -k "system-images;android-31;google_apis;arm64-v8a"`. The arm64 image is required because the spike's primary verification target is `android-arm64`; an x86_64 emulator would exercise the `android-x64` bundle instead (out of scope per the spec).

- [ ] **Step 4: Build + install the demo on the Android emulator**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build --project-dir DemoApp/BareKitDemo --platform android \
  --target emulator --sdk 13.3.0
```

Expected: the build runs the plugin's Android branch (4 `tibarekit-spike: spike-android-<host>.bundle ready` lines), produces + installs the APK on the emulator, and the app launches. The logcat should show `[spike] spike app started` and `[spike] IPC writable; ready to send` within a few seconds. If the app crashes on launch, check logcat for `FATAL:` + `sodium-native.bare` / `udx-native.bare` (addon loading broken) -- re-check Task 4's prebuild copy + the `--offload-addons` flag.

- [ ] **Step 5: Boot the iOS simulator + build + install the demo (the other peer)**

```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
open -a Simulator
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build --project-dir DemoApp/BareKitDemo --platform ios \
  --target simulator --device-id $(xcrun simctl list devices booted | grep -m1 'iPhone 17 Pro' | grep -oE '[0-9A-F-]{36}') \
  --sdk 13.3.0
```

Expected: the iOS build runs the plugin's iOS branch (single `spike.bundle`), installs on the simulator, and the app launches. The iOS log should show `[spike] spike app started` + `[spike] IPC writable; ready to send`.

- [ ] **Step 6: Wait for `connection opened` on BOTH sides (success criterion 3)**

Watch both logs (Android logcat + iOS Simulator log) for up to 15 s. Expected: both sides print `[spike] worklet: connection opened` within 15 s. If neither side prints it and the Android side prints `[spike] worklet: TIMEOUT: no peer discovered`, the DHT did not bootstrap -- check network egress (the Android emulator's UDP egress can be flaky; try toggling airplane mode off/on or restarting the emulator). If the Android side prints `FATAL:` + a native addon path, re-check Task 4.

- [ ] **Step 7: Round-trip a message Android -> iOS -> Android (success criteria 1, 2, 4)**

In the Android app, type `hello` + tap Send. Expected sequence:
- Android log: `[spike] sent: hello` then `[spike] worklet: sent to peer: hello`.
- iOS log: `[spike] worklet: peer: hello` then `[spike] sent echo: echo: hello` then `[spike] worklet: sent to peer: echo: hello`.
- Android log: `[spike] worklet: peer: echo: hello`. (The Android auto-echo guard sees `echo: hello` starts with `echo: ` and does NOT re-echo -- no amplification.)

Then reverse: in the iOS app, type `world` + tap Send. Expected: iOS -> Android -> iOS round-trip with the same echo-guard behavior.

- [ ] **Step 8: Verify RSS flat at idle (leak-fix check)**

Leave both apps idle for ~60 s. Watch the Android logcat for the `appmem` reporter (every 5 s): `[spike] appmem avail=<N>MB`. Expected: `avail` does not drop continuously, and neither side's native RSS climbs unboundedly at idle. If `avail` drops continuously while idle, the proactive `setWritable` one-shot (Task 2) is not holding on Android -- re-check Task 2.

- [ ] **Step 9: Record the verification result**

Append to the progress ledger (`.superpowers/sdd/progress.md`):

```
Android spike verified: criteria 1-4 + RSS-flat hold. Android arm64 emulator <-> iOS sim, topic tibarekit-spike-v1, message round-trip Android->iOS->Android + iOS->Android->iOS, echo guard held, RSS flat over 60s idle.
```

If any criterion failed, record the failure mode + the diagnostic line (`FATAL:` / `TIMEOUT` / `WATCHDOG` / `IPC ERR`) and do NOT mark the spike verified -- go back to the relevant task.

- [ ] **Step 10: Commit the ledger update**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
git add .superpowers/sdd/progress.md
git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit -m "docs: android spike verified -- 4 success criteria + RSS-flat hold"
```

---

## Post-implementation: comprehensive docs

After Task 6 verifies, update the docs (the user wants comprehensive docs after everything is done):

- `DemoApp/BareKitDemo/README.md` -- add an Android section (prerequisites: Android emulator API 31+, arm64 AVD; build + install commands; the 4-bundle ABI story; the runtime ABI selection; the success criteria unchanged).
- `documentation/index.md` -- add Android notes to the hyperswarm-spike section (the `new IPC(worklet)` dispatch story, the one-shot writable on Java, the 4-ABI plugin branch).

These are folded into the spike's final commit, not a separate task.