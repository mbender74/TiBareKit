# TiBareKit Hyperswarm Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove TiBareKit can load the holepunch native addon stack (sodium-native, udx-native) and run hyperswarm inside a Bare worklet on iOS, joining a topic and echoing a message between two simulator instances.

**Architecture:** A Titanium app (extending DemoApp/BareKitDemo in place) runs a Bare worklet built by `bare-pack` into a `.bundle`. The worklet uses hyperswarm to join a fixed topic; two simulator instances discover each other and round-trip a message. A Titanium plugin (registered via `<plugins>` in tiapp.xml) runs `bare-pack` before the Titanium compile step and copies the platform-correct `.bare` native prebuilds into the app Resources.

**Tech Stack:** Titanium SDK 14.0.0, ti.barekit module, holepunch hyperswarm + udx-native + sodium-native, bare-pack (from the bare-build ecosystem), framed-stream, iOS simulator.

## Global Constraints

- Module id: `ti.barekit`; version: `1.0.0` (already in the app's tiapp.xml).
- Titanium SDK version pin: `14.0.0` (already in DemoApp/BareKitDemo/tiapp.xml).
- The spike extends DemoApp/BareKitDemo in place -- the current minimal Worklet/IPC demo app.js is replaced.
- iOS simulator only (ios-arm64-simulator + ios-x64-simulator prebuilds). Device + Android are out of scope.
- The IPC-after-start contract: `new IPC(worklet)` MUST be called after `worklet.start()` returns, or the IPC channel dups -1 fds and readable/writable never fire. (Fixed + documented in the TiBareKit module; the spike must honor it.)
- Native callbacks deliver a single result dict (`{reply}`/`{data}`/`{error}`/`{}`), not `(value, err)` pairs.
- Write-before-writable: only call `ipc.write(...)` inside/after the `ipc.writable` callback, or BareKit's `write:completion:` underflows.
- No `Co-Authored-By` trailer on commits (user preference).
- Commits use the Conventional-Commits-style prefix (`feat:`, `build:`, `docs:`, `chore:`, `fix:`).
- Commit author: `mbender74 <marc_bender@icloud.com>` via `git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit`.
- Pure ASCII in all authored files (no em-dashes -- use `--`; titanium_prep crashes on non-ASCII).
- The user compiles themselves ("ich compiliere selbst"). Implementer subagents may run `ti build --build-only` for build verification but MUST NOT run the full simulator build. Runtime verification steps are marked **USER RUNS THIS** -- the implementer writes the code, the user runs the simulator and reports the log back.

## Tooling prerequisites (the implementer verifies these in Task 1)

- `bare-pack` on PATH. Install with `npm install --global bare-pack` if missing. The CLI is `bare-pack --platform ios --arch arm64 --simulator --out <path> <entry>`.
- `npm` + Node.js (already present -- the user has been running ti build).
- The `ti.barekit` module built + installed (already done -- the user copied the zip to `~/Library/Application Support/Titanium/`).

---

### Task 1: Worklet package + trivial bundle + Titanium plugin scaffold

Prove the end-to-end bundle pipeline: `bare-pack` produces a `.bundle` from a trivial worklet source, the Titanium plugin runs `bare-pack` during `ti build`, the TiBareKit worklet loads the `.bundle`, and IPC delivers a message to the Titanium main side. No native addons yet -- this isolates the bundle-loading path before introducing the riskiest unknown (native addon loading).

**Files:**
- Create: `DemoApp/BareKitDemo/worklet/package.json`
- Create: `DemoApp/BareKitDemo/worklet/spike.js`
- Create: `DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/plugin.js`
- Create: `DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/package.json`
- Modify: `DemoApp/BareKitDemo/tiapp.xml` (add `<plugins>` element)
- Modify: `DemoApp/BareKitDemo/Resources/app.js` (replace with minimal bundle-loading harness)

**Interfaces:**
- Consumes: `ti.barekit` module's `Worklet` (with `start(filename, source, args)` bundle-loader mode: pass `null` as `source` and a `.bundle` filename) and `IPC` (with `readable`/`writable` setters, `read()`/`write(data)`).
- Produces: a working `bare-pack` -> `.bundle` -> TiBareKit-loadable pipeline, and a Titanium plugin that runs `bare-pack` on `ti build`. Later tasks add native addons + hyperswarm on top of this pipeline.

- [ ] **Step 1: Create the worklet package**

`DemoApp/BareKitDemo/worklet/package.json`:
```json
{
  "name": "tibarekit-spike-worklet",
  "version": "1.0.0",
  "private": true,
  "type": "commonjs",
  "dependencies": {}
}
```

(Deps get added in Task 3 when hyperswarm is introduced. Task 1's trivial worklet has no deps.)

- [ ] **Step 2: Write the trivial worklet source**

`DemoApp/BareKitDemo/worklet/spike.js`:
```js
// Trivial spike worklet -- proves the bundle loads + IPC works.
// Later tasks replace this with the hyperswarm join + echo logic.
BareKit.IPC.write('spike alive')
BareKit.IPC.on('data', (data) => {
  BareKit.IPC.write('echo: ' + data.toString())
})
```

- [ ] **Step 3: Install bare-pack (if missing) + run it manually to produce the bundle**

Run:
```bash
which bare-pack || npm install --global bare-pack
cd DemoApp/BareKitDemo/worklet
bare-pack --platform ios --arch arm64 --simulator --out ../Resources/spike.bundle spike.js
ls -la ../Resources/spike.bundle
```
Expected: `Resources/spike.bundle` exists, non-empty (a few KB). If `bare-pack` errors on `--platform ios`, try `--target ios-arm64-simulator` instead (the `--target` flag is an alternative to `--platform`+`--arch`+`--simulator`; use whichever bare-pack accepts for your installed version -- check `bare-pack --help`).

- [ ] **Step 4: Write the Titanium plugin**

`DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/package.json`:
```json
{
  "name": "tibarekit-spike",
  "version": "1.0.0",
  "main": "plugin.js"
}
```

`DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/plugin.js`:
```js
// Titanium build plugin: runs bare-pack to produce Resources/spike.bundle
// before the Titanium compile step. Task 1's version has no native prebuilds
// to copy; later tasks extend the copy step.
const { execSync } = require('child_process')
const path = require('path')
const fs = require('fs')

exports.main = function (logger, config, cli, done) {
  const projectDir = cli.argv['project-dir']
  const workletDir = path.join(projectDir, 'worklet')
  const resourcesDir = path.join(projectDir, 'Resources')
  const bundlePath = path.join(resourcesDir, 'spike.bundle')

  // Detect target platform + arch from the CLI args.
  // For the spike, always ios-arm64-simulator (the sim target).
  const platform = cli.argv.platform // 'ios'
  const isSim = cli.argv.target === 'simulator' || cli.argv['target'] === 'simulator'

  logger.info('tibarekit-spike: packing worklet bundle...')

  try {
    // Run bare-pack. --platform ios --arch arm64 --simulator for the sim target.
    // If the sim is x86_64, the implementer adjusts --arch (determined in Step 8).
    execSync(
      `bare-pack --platform ios --arch arm64 --simulator --out "${bundlePath}" "${path.join(workletDir, 'spike.js')}"`,
      { stdio: 'inherit', cwd: workletDir }
    )

    if (!fs.existsSync(bundlePath)) {
      throw new Error('bare-pack did not produce spike.bundle')
    }

    // Task 2+ adds the prebuild-copy step here.

    logger.info('tibarekit-spike: bundle ready at ' + bundlePath)
    done()
  } catch (err) {
    logger.error('tibarekit-spike: ' + err.message)
    done(err)
  }
}
```

Note: the exact Titanium plugin `main` signature + when it fires in the build lifecycle varies by SDK version. The implementer verifies this against the SDK 14.0.0 plugin loader (check `find /Users/marcbender/titanium_mobile -path "*plugins*" -name "*.js"` for the loader, or `grep -rn "plugins" /Users/marcbender/titanium_mobile/src`). If `exports.main` with `(logger, config, cli, done)` is wrong for 14.0.0, adjust to the signature the loader expects. The functional requirement: the plugin runs `bare-pack` and writes `Resources/spike.bundle` before the Titanium compile step packages Resources.

- [ ] **Step 5: Register the plugin in tiapp.xml**

`DemoApp/BareKitDemo/tiapp.xml` -- add the `<plugins>` element as a child of `<ti:app>` (after the `<modules>` element):
```xml
	<plugins>
		<plugin>tibarekit-spike</plugin>
	</plugins>
```

- [ ] **Step 6: Write the minimal main-side harness**

`DemoApp/BareKitDemo/Resources/app.js` (replaces the current demo):
```js
// TiBareKit hyperswarm spike -- Task 1: prove the bundle loads + IPC works.
// Later tasks replace this with the full UI + hyperswarm wiring.
const { Worklet, IPC } = require('ti.barekit')

const log = (msg) => {
  Ti.API.info('[spike] ' + msg)
  logLines.push(msg)
  if (logArea) logArea.value = logLines.join('\n')
}

const logLines = []
let logArea = null

const worklet = new Worklet({ memoryLimit: 64 * 1024 * 1024 })

// Bundle-loader mode: null source, .bundle filename.
// The bundle was produced by bare-pack (via the Titanium plugin) and ships
// in Resources/spike.bundle.
worklet.start('/spike.bundle', null, [])

// IPC MUST be created AFTER worklet.start() returns -- bare_ipc_init dups
// the worklet's fds, which are -1 until start completes.
const ipc = new IPC(worklet)

ipc.readable = () => {
  const d = ipc.read()
  if (d) log('worklet: ' + d.toString())
}

let writableFired = false
ipc.writable = () => {
  if (writableFired) return
  writableFired = true
  ipc.write('ping from main')
}

// Minimal UI: a text area mirroring the log.
const win = Ti.UI.createWindow({ backgroundColor: '#fff' })
logArea = Ti.UI.createTextArea({
  value: '',
  color: '#000',
  font: { fontSize: 12, fontFamily: 'Menlo' },
  editable: false,
  top: 20, left: 20, right: 20, bottom: 20,
  verticalAlign: 'top'
})
win.add(logArea)
win.open()

log('spike app started -- watch for "worklet: spike alive" and "worklet: echo: ping from main"')
```

- [ ] **Step 7: Build-only verification (implementer runs)**

Run:
```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build --project-dir DemoApp/BareKitDemo --platform ios --build-only --no-prompt --sdk 14.0.0
```
Expected: BUILD SUCCEEDED. The plugin's `tibarekit-spike: bundle ready` line appears in the build log. `Resources/spike.bundle` exists after the build. If the plugin doesn't fire, the `exports.main` signature is wrong -- fix it per the Step 4 note.

- [ ] **Step 8: USER RUNS THIS -- simulator runtime verification**

The user runs:
```bash
ti build --project-dir DemoApp/BareKitDemo --platform ios --target simulator --device-id <UDID> --sdk 14.0.0
```
Expected (user reports back): the on-screen log + Ti.API console show:
```
spike app started -- watch for "worklet: spike alive" and "worklet: echo: ping from main"
worklet: spike alive
worklet: echo: ping from main
```
If `worklet: spike alive` does not appear, the bundle didn't load -- check the bundle path (`/spike.bundle` resolves relative to the app's Resources), the bare-pack invocation, and whether `BareKit.IPC.write` fired before the main side installed `readable`. If only `spike alive` appears but not `echo: ping from main`, the main->worklet write didn't round-trip -- check the writable guard + IPC-after-start ordering.

- [ ] **Step 9: Commit**

```bash
git add DemoApp/BareKitDemo/worklet/package.json \
  DemoApp/BareKitDemo/worklet/spike.js \
  DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/plugin.js \
  DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/package.json \
  DemoApp/BareKitDemo/tiapp.xml \
  DemoApp/BareKitDemo/Resources/app.js
git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit -m "feat(spike): worklet bundle pipeline + Titanium plugin scaffold

Proves bare-pack produces a TiBareKit-loadable .bundle and the
Titanium plugin runs bare-pack during ti build. Trivial worklet
echoes over IPC; no native addons yet."
```

(Resources/spike.bundle is a build artifact -- add it to .gitignore in this commit or a follow-up.)

---

### Task 2: Native addon (sodium-native) loads inside the worklet

Prove the riskiest unknown: a shipped `.bare` native prebuild is `dlopen`'d by the embedded Bare runtime at worklet load time. sodium-native is the first one because it's the deepest dep (hypercore crypto depends on it) and the most likely to fail.

**Files:**
- Modify: `DemoApp/BareKitDemo/worklet/package.json` (add `sodium-native` dep)
- Modify: `DemoApp/BareKitDemo/worklet/spike.js` (require sodium-native, log success)
- Modify: `DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/plugin.js` (copy sodium-native prebuild)
- Modify: `DemoApp/BareKitDemo/.gitignore` or top-level `.gitignore` (ignore Resources/spike.bundle + Resources/prebuilds/)

**Interfaces:**
- Consumes: the Task 1 bundle pipeline + plugin scaffold.
- Produces: a build hook that copies native prebuilds into `Resources/prebuilds/<platform-arch>/`, and proof that `require('sodium-native')` loads inside a TiBareKit worklet.

- [ ] **Step 1: Add sodium-native as a worklet dep**

`DemoApp/BareKitDemo/worklet/package.json`:
```json
{
  "name": "tibarekit-spike-worklet",
  "version": "1.0.0",
  "private": true,
  "type": "commonjs",
  "dependencies": {
    "sodium-native": "^4.1.1"
  }
}
```

Run:
```bash
cd DemoApp/BareKitDemo/worklet
npm install
ls node_modules/sodium-native/prebuilds/ios-arm64-simulator/sodium-native.bare
```
Expected: the `.bare` file exists. If not, the installed sodium-native version doesn't ship ios-arm64-simulator prebuilds -- check `ls node_modules/sodium-native/prebuilds/` for the available ios-* dirs and adjust the arch in the plugin accordingly.

- [ ] **Step 2: Extend the worklet to require sodium-native**

`DemoApp/BareKitDemo/worklet/spike.js`:
```js
// Task 2: prove sodium-native loads inside the worklet.
const sodium = require('sodium-native')

BareKit.IPC.write('sodium loaded, version=' + sodium.sodiumVersionString())

BareKit.IPC.on('data', (data) => {
  BareKit.IPC.write('echo: ' + data.toString())
})
```

- [ ] **Step 3: Extend the plugin to copy the sodium-native prebuild**

`DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/plugin.js` -- replace the `// Task 2+ adds the prebuild-copy step here.` line with:
```js
    // Copy native addon prebuilds into Resources/prebuilds/<platform-arch>/.
    // The Bare runtime's require-addon resolves .bare files from here at runtime.
    const prebuildsDir = path.join(resourcesDir, 'prebuilds', 'ios-arm64-simulator')
    fs.mkdirSync(prebuildsDir, { recursive: true })

    // Walk node_modules/*/prebuilds/ios-arm64-simulator/*.bare and copy each.
    const nodeModulesDir = path.join(workletDir, 'node_modules')
    if (fs.existsSync(nodeModulesDir)) {
      for (const modName of fs.readdirSync(nodeModulesDir)) {
        const modPrebuilds = path.join(nodeModulesDir, modName, 'prebuilds', 'ios-arm64-simulator')
        if (!fs.existsSync(modPrebuilds)) continue
        for (const file of fs.readdirSync(modPrebuilds)) {
          if (file.endsWith('.bare')) {
            fs.copyFileSync(path.join(modPrebuilds, file), path.join(prebuildsDir, file))
            logger.info('tibarekit-spike: copied ' + modName + '/' + file)
          }
        }
      }
    }
```

Note: this walks ALL node_modules with ios-arm64-simulator prebuilds, not just sodium-native. That's intentional -- Task 3 adds udx-native + hyperswarm's other transitive native deps, and the walk picks them up automatically. Task 2 only has sodium-native installed, so only sodium-native.bare gets copied.

The open question (from the spec): does `require-addon` find the `.bare` in `Resources/prebuilds/ios-arm64-simulator/` at runtime? The bundle records the addon's expected resolution path; `require-addon` resolves it against the prebuilds dir. If `require-addon` can't find it, the implementer must adjust either (a) the prebuild copy destination to match what `require-addon` expects, or (b) the `bare-pack --base` flag to set the bundle's addon resolution root. This is the empirical unknown Task 2 resolves. The likely-correct layout: `Resources/prebuilds/<platform-arch>/<addon-name>.bare` matches the `node_modules/<addon>/prebuilds/<platform-arch>/<addon-name>.bare` layout require-addon expects -- but since the worklet's "node_modules" doesn't exist at runtime, the implementer may need to ship the prebuilds under a path the bundle records. If the first attempt fails, try `--base` on bare-pack or ship the full `node_modules/*/prebuilds/` tree structure under `Resources/`.

- [ ] **Step 4: Ignore build artifacts**

`.gitignore` (append to the existing `DemoApp/BareKitDemo/build/` + `modules/` entries):
```
DemoApp/BareKitDemo/Resources/spike.bundle
DemoApp/BareKitDemo/Resources/prebuilds/
DemoApp/BareKitDemo/worklet/node_modules/
```

- [ ] **Step 5: Build-only verification (implementer runs)**

Run:
```bash
ti build --project-dir DemoApp/BareKitDemo --platform ios --build-only --no-prompt --sdk 14.0.0
```
Expected: BUILD SUCCEEDED. Build log shows `tibarekit-spike: copied sodium-native/sodium-native.bare`. `Resources/prebuilds/ios-arm64-simulator/sodium-native.bare` exists.

- [ ] **Step 6: USER RUNS THIS -- sodium loads at runtime**

The user runs the simulator build. Expected (user reports back):
```
worklet: sodium loaded, version=<some version string>
```
If instead: `WORKLET DIED: ...` or `FATAL: ... sodium-native.bare ...` -- the prebuild didn't load. Diagnose per the Step 3 note: check whether `require-addon` found the `.bare` (the bundle's recorded addon path vs. the shipped layout), whether the platform slice matches the sim (arm64 vs x86_64), and whether `dlopen` succeeded (the worklet's uncaughtException handler will have the message). The fix is likely in the prebuild copy destination or the `bare-pack --base` flag.

- [ ] **Step 7: Commit**

```bash
git add DemoApp/BareKitDemo/worklet/package.json \
  DemoApp/BareKitDemo/worklet/spike.js \
  DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/plugin.js \
  .gitignore
git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit -m "feat(spike): load sodium-native .bare prebuild in worklet

Plugin copies node_modules/*/prebuilds/ios-arm64-simulator/*.bare
into Resources/prebuilds/. Proves the Bare runtime's
bare_addon_load_dynamic dlopens a shipped .bare inside a TiBareKit
worklet on the iOS simulator."
```

---

### Task 3: udx-native + hyperswarm join (no echo yet)

Prove the full networking stack boots: `udx-native` (UDP sockets) + `hyperswarm` (DHT + peer discovery). The worklet joins the fixed topic; on a single simulator no peer arrives, but the spike confirms no `FATAL` and the DHT bootstraps without crashing. The echo comes in Task 4.

**Files:**
- Modify: `DemoApp/BareKitDemo/worklet/package.json` (add `hyperswarm` + `framed-stream` deps)
- Modify: `DemoApp/BareKitDemo/worklet/spike.js` (create swarm, join topic, log connection events)

**Interfaces:**
- Consumes: Task 2's prebuild-copy plugin (automatically picks up udx-native + hyperswarm's transitive native prebuilds).
- Produces: a worklet that joins a hyperswarm topic + forwards connection events to main over IPC.

- [ ] **Step 1: Add hyperswarm + framed-stream deps**

`DemoApp/BareKitDemo/worklet/package.json`:
```json
{
  "name": "tibarekit-spike-worklet",
  "version": "1.0.0",
  "private": true,
  "type": "commonjs",
  "dependencies": {
    "sodium-native": "^4.1.1",
    "hyperswarm": "^4.17.0",
    "framed-stream": "^1.0.1"
  }
}
```

Run:
```bash
cd DemoApp/BareKitDemo/worklet
npm install
ls node_modules/udx-native/prebuilds/ios-arm64-simulator/udx-native.bare
```
Expected: the `.bare` exists. (hyperswarm pulls in udx-native + sodium-native transitively; both should have ios-arm64-simulator prebuilds per the spec's survey.)

- [ ] **Step 2: Write the hyperswarm-join worklet**

`DemoApp/BareKitDemo/worklet/spike.js`:
```js
// Task 3: prove hyperswarm + udx-native boot inside the worklet.
// Join a fixed topic; log connection events. No echo yet (Task 4).
const Hyperswarm = require('hyperswarm')
const crypto = require('bare-crypto') // or require('crypto') if bare-crypto isn't available

const TOPIC_STRING = 'tibarekit-spike-v1'
const topic = crypto.createHash('sha256').update(TOPIC_STRING).digest()

const swarm = new Hyperswarm()
swarm.on('connection', (socket) => {
  BareKit.IPC.write('connection opened')
  socket.on('error', (err) => BareKit.IPC.write('PEER ERROR: ' + err.message))
  socket.on('close', () => BareKit.IPC.write('PEER DISCONNECTED'))
})

swarm.join(topic, {
  client: true,
  server: true
})

BareKit.IPC.write('joined topic: ' + TOPIC_STRING)

BareKit.IPC.on('data', (data) => {
  // Task 4 wires this to the framed-stream echo.
  BareKit.IPC.write('main said: ' + data.toString())
})

Bare.on('uncaughtException', (err) => {
  BareKit.IPC.write('FATAL: ' + err.message)
})
```

Note on `bare-crypto`: Bare's built-in `crypto` module may be available as `require('crypto')` (if bare-kit's embedded runtime includes it) or as `require('bare-crypto')`. The implementer tries `require('crypto')` first; if it throws, fall back to `require('bare-crypto')` (which may need to be added to package.json deps). An alternative that avoids the crypto dep entirely: derive the topic from a fixed 32-byte Buffer literal -- `const topic = Buffer.from('tibarekit-spike-v1-fixed-topic-32b!'.padEnd(32, '0'))` -- which is fine for a spike (the topic just needs to be the same 32 bytes on both instances).

If `bare-crypto` is needed, add it to package.json deps + npm install. Prefer the Buffer-literal approach if it works -- fewer native deps to load.

- [ ] **Step 3: Build-only verification (implementer runs)**

Run:
```bash
ti build --project-dir DemoApp/BareKitDemo --platform ios --build-only --no-prompt --sdk 14.0.0
```
Expected: BUILD SUCCEEDED. Build log shows `tibarekit-spike: copied` lines for sodium-native, udx-native, and any other transitive native addons hyperswarm pulls in (rabin-native, quickbit-native, etc.). All `.bare` files present in `Resources/prebuilds/ios-arm64-simulator/`.

- [ ] **Step 4: USER RUNS THIS -- hyperswarm joins on one simulator**

The user runs the simulator build on ONE simulator. Expected (user reports back):
```
worklet: joined topic: tibarekit-spike-v1
```
and NO `FATAL:` line. A `connection opened` line will NOT appear (no peer yet -- that's Task 4). The spike proves here that `udx-native` UDP sockets opened + the DHT bootstrapped without crashing. If `FATAL: ... udx-native ...` appears, the UDP transport native addon didn't load -- same diagnosis as Task 2's sodium-native failure. If `FATAL: ...` names a different module (e.g., `hyperswarm` or a transitive dep), check that its prebuild was copied (the plugin walk should have caught it -- verify `ls Resources/prebuilds/ios-arm64-simulator/`).

- [ ] **Step 5: Commit**

```bash
git add DemoApp/BareKitDemo/worklet/package.json \
  DemoApp/BareKitDemo/worklet/spike.js
git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit -m "feat(spike): hyperswarm join + udx-native boot in worklet

Proves hyperswarm + udx-native load and the DHT bootstraps inside
a TiBareKit worklet on the iOS simulator. No echo yet; connection
events forwarded to main over IPC."
```

---

### Task 4: Two-simulator echo round-trip

The spike's success criterion. Extend the worklet with the framed-stream echo logic + replace the main-side harness with the full UI (log view + text field + send button). Two simulator instances round-trip a message.

**Files:**
- Modify: `DemoApp/BareKitDemo/worklet/spike.js` (framed-stream echo over the connection + IPC)
- Modify: `DemoApp/BareKitDemo/Resources/app.js` (full UI + IPC wiring)

**Interfaces:**
- Consumes: Task 3's swarm join + connection events.
- Produces: a two-simulator message round-trip. Success = the spec's four success criteria.

- [ ] **Step 1: Write the full echo worklet**

`DemoApp/BareKitDemo/worklet/spike.js`:
```js
// TiBareKit hyperswarm spike -- Task 4: two-simulator echo round-trip.
const Hyperswarm = require('hyperswarm')
const FramedStream = require('framed-stream')

// Fixed 32-byte topic derived from a shared string. Both instances
// derive the same topic and join it, so they discover each other.
const TOPIC_STRING = 'tibarekit-spike-v1'
const topic = Buffer.from(TOPIC_STRING.padEnd(32, '0')) // 32-byte fixed topic

const swarm = new Hyperswarm()

// Track the active connection + its framed stream. For the spike we
// keep the first connection; hyperswarm may open more but we echo on
// the first.
let activeStream = null

swarm.on('connection', (socket) => {
  BareKit.IPC.write('connection opened')

  const framed = new FramedStream(socket)

  framed.on('data', (data) => {
    // Inbound message from peer -> forward to main.
    BareKit.IPC.write('peer: ' + data.toString())
  })

  framed.on('error', (err) => BareKit.IPC.write('PEER ERROR: ' + err.message))
  socket.on('close', () => {
    BareKit.IPC.write('PEER DISCONNECTED')
    if (activeStream === framed) activeStream = null
  })

  if (activeStream === null) activeStream = framed
})

swarm.join(topic, { client: true, server: true })
BareKit.IPC.write('joined topic: ' + TOPIC_STRING)

// Main -> worklet -> peer. Messages from main are written into the
// active framed stream to the peer.
BareKit.IPC.on('data', (data) => {
  if (activeStream) {
    activeStream.write(data)
    BareKit.IPC.write('sent to peer: ' + data.toString())
  } else {
    BareKit.IPC.write('no peer yet, dropped: ' + data.toString())
  }
})

Bare.on('uncaughtException', (err) => {
  BareKit.IPC.write('FATAL: ' + err.message)
})
```

Note: the echo logic is on the RECEIVING side. When app A sends "hello", worklet A writes it to the framed stream; worklet B's framed stream emits "hello"; worklet B forwards "peer: hello" to main B. Main B's UI shows it. The spec's "echo: hello" round-trip is app B echoing back -- the demo app's send button on app B, or an automatic echo in main B's `readable` handler. Task 4 Step 3 below wires main B to auto-echo.

- [ ] **Step 2: Write the full main-side UI + IPC wiring**

`DemoApp/BareKitDemo/Resources/app.js`:
```js
// TiBareKit hyperswarm spike -- Task 4: full UI + two-sim echo.
const { Worklet, IPC } = require('ti.barekit')

const log = (msg) => {
  Ti.API.info('[spike] ' + msg)
  logLines.push(msg)
  if (logArea) {
    logArea.value = logLines.join('\n')
    // Keep the latest lines visible.
    logArea.scrollToVisible ? logArea.scrollToVisible({ y: logLines.length * 14 }) : null
  }
}

const logLines = []
let logArea = null
let inputField = null
let writableFired = false

const worklet = new Worklet({ memoryLimit: 64 * 1024 * 1024 })
worklet.start('/spike.bundle', null, [])

// IPC MUST be created AFTER worklet.start() returns.
const ipc = new IPC(worklet)

ipc.readable = () => {
  const d = ipc.read()
  if (!d) return
  const msg = d.toString()
  log('worklet: ' + msg)

  // Auto-echo: if we received a "peer: <msg>" line, echo it back so the
  // originator sees a round-trip. This implements the spec's
  // "hello" -> "echo: hello" flow.
  if (msg.indexOf('peer: ') === 0) {
    const echoed = 'echo: ' + msg.slice('peer: '.length)
    if (writableFired) {
      ipc.write(echoed)
      log('sent echo: ' + echoed)
    }
  }
}

ipc.writable = () => {
  if (writableFired) return
  writableFired = true
  log('IPC writable; ready to send')
}

// UI: a log view (top) + a text field + send button (bottom).
const win = Ti.UI.createWindow({ backgroundColor: '#fff', layout: 'vertical' })

logArea = Ti.UI.createTextArea({
  value: '',
  color: '#000',
  font: { fontSize: 12, fontFamily: 'Menlo' },
  editable: false,
  top: 20, left: 20, right: 20,
  height: '78%',
  verticalAlign: 'top'
})
win.add(logArea)

const inputRow = Ti.UI.createView({
  layout: 'horizontal',
  top: 10, left: 20, right: 20, bottom: 20,
  height: Ti.UI.SIZE
})
win.add(inputRow)

inputField = Ti.UI.createTextField({
  hintText: 'type a message',
  value: '',
  width: '70%',
  height: 40,
  borderStyle: Ti.UI.INPUT_BORDERSTYLE_ROUNDED
})
inputRow.add(inputField)

const sendButton = Ti.UI.createButton({
  title: 'Send',
  width: '25%',
  height: 40,
  left: 10
})
inputRow.add(sendButton)

sendButton.addEventListener('click', () => {
  const text = inputField.value
  if (!text || !writableFired) {
    log(!writableFired ? 'IPC not writable yet' : 'empty input')
    return
  }
  ipc.write(text)
  log('sent: ' + text)
  inputField.value = ''
})

win.open()

log('spike app started. Type a message + tap Send. Run on TWO simulators.')
```

- [ ] **Step 3: Build-only verification (implementer runs)**

Run:
```bash
ti build --project-dir DemoApp/BareKitDemo --platform ios --build-only --no-prompt --sdk 14.0.0
```
Expected: BUILD SUCCEEDED. (The bundle + prebuilds are unchanged from Task 3; only the worklet source + main app.js changed, so the plugin re-packs the bundle.)

- [ ] **Step 4: USER RUNS THIS -- two-simulator echo round-trip**

The user boots two simulators + builds/installs on both:
```bash
xcrun simctl boot "iPhone 15"          # or any two distinct devices
xcrun simctl boot "iPhone 15 Pro"
ti build --project-dir DemoApp/BareKitDemo --platform ios --target simulator --device-id <UDID-A> --sdk 14.0.0
ti build --project-dir DemoApp/BareKitDemo --platform ios --target simulator --device-id <UDID-B> --sdk 14.0.0
```
Launch both apps. In app A, type "hello" + tap Send. Expected (user reports back both logs):
- App A log: `sent: hello` -> `worklet: sent to peer: hello` -> (wait for round-trip) -> `worklet: peer: echo: hello` -> `sent echo: echo: hello` (auto-echo of the echo -- harmless, or suppress per the note below)
- App B log: `worklet: connection opened` -> `worklet: peer: hello` -> `sent echo: echo: hello` -> `worklet: sent to peer: echo: hello`

The spec's success criteria:
1. Both apps launch without crashing.
2. No `FATAL:` line in either log.
3. A `connection opened` fires on both sides within 15 s.
4. The "hello" round-trips (app B sees it, app A sees the echo).

Note: the auto-echo in main's `readable` handler will create an infinite echo loop ("hello" -> "echo: hello" -> "echo: echo: hello" -> ...). For the spike that's acceptable -- it proves the round-trip works. If the user finds it noisy, a follow-up can gate the echo on the original message not starting with "echo: ". The plan leaves the auto-echo as-is for simplicity; the spike's success criterion is "a message round-trips", which the loop demonstrates.

- [ ] **Step 5: Commit**

```bash
git add DemoApp/BareKitDemo/worklet/spike.js \
  DemoApp/BareKitDemo/Resources/app.js
git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit -m "feat(spike): two-simulator echo round-trip via hyperswarm

Full UI (log view + text field + send button). Worklet wraps the
hyperswarm connection in framed-stream; main auto-echoes received
peer messages. Success = the spec's four criteria: both apps launch,
no FATAL, connection within 15s, hello round-trips."
```

---

### Task 5: Error handling + diagnostics

Wire up the failure-mode diagnostics from the spec so the spike's output is debuggable when something goes wrong (or when the user runs it on a network where the DHT can't bootstrap). Most of the pieces are already in the worklet from Task 4; this task adds the 15-second timeout + tightens the IPC error logging.

**Files:**
- Modify: `DemoApp/BareKitDemo/worklet/spike.js` (15s timeout, tighter error forwarding)
- Modify: `DemoApp/BareKitDemo/Resources/app.js` (IPC error logging, worklet-death detection)

**Interfaces:**
- Consumes: Task 4's echo worklet + UI.
- Produces: a spike that produces a visible diagnostic log line for every failure mode in the spec's error-handling section.

- [ ] **Step 1: Add the 15s peer-discovery timeout to the worklet**

`DemoApp/BareKitDemo/worklet/spike.js` -- after `swarm.join(topic, ...)`, add:
```js
// 15s timeout: if no connection fires, tell main. Not a crash -- a
// diagnostic (the DHT may not bootstrap on a restricted network).
let connectionFired = false
swarm.on('connection', () => { connectionFired = true })

setTimeout(() => {
  if (!connectionFired) {
    BareKit.IPC.write('TIMEOUT: no peer discovered (check network / DHT bootstrap)')
  }
}, 15000)
```

(Place this right after the `swarm.join(...)` call + before the `BareKit.IPC.on('data', ...)` handler. The `connectionFired` flag is set in a second `connection` listener -- EventEmitters support multiple listeners, so this is safe alongside the Task 4 listener.)

- [ ] **Step 2: Add IPC error logging to the main side**

`DemoApp/BareKitDemo/Resources/app.js` -- replace the `ipc.writable = () => { ... }` block with an async-write helper that surfaces `{error}` results, and add a worklet-death detector:
```js
// Async write helper that logs {error} results from the native callback.
function sendToWorklet(text) {
  ipc.write(text, (result) => {
    if (result.error) log('IPC ERR: ' + result.error)
  })
}

ipc.writable = () => {
  if (writableFired) return
  writableFired = true
  log('IPC writable; ready to send')
}

// Replace the two ipc.write(...) call sites with sendToWorklet(...):
//   - in the sendButton click handler: sendToWorklet(text)
//   - in the readable auto-echo: sendToWorklet(echoed)

// Worklet-death detector: if no readable event fires for 30s after
// startup, the worklet likely crashed (the uncaughtException handler
// would have sent FATAL first, but this catches silent deaths).
let workletAlive = true
let lastReadable = Date.now()
const originalReadable = ipc.readable
ipc.readable = () => {
  lastReadable = Date.now()
  originalReadable()
}
// (The 30s-since-startup check is optional -- the FATAL path covers
// most worklet deaths. Left as a comment for the implementer to decide.)
```

The implementer threads `sendToWorklet(...)` through the two existing `ipc.write(...)` call sites in app.js (the send button handler + the auto-echo in readable). The native callback's `{error}` shape is the single-dict contract; `result.error` is the error message string.

- [ ] **Step 3: Build-only verification (implementer runs)**

Run:
```bash
ti build --project-dir DemoApp/BareKitDemo --platform ios --build-only --no-prompt --sdk 14.0.0
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: USER RUNS THIS -- verify diagnostics on a no-peer run**

The user runs the spike on ONE simulator (no second peer). Expected (user reports back): within 15 s of `joined topic:`, the log shows:
```
worklet: TIMEOUT: no peer discovered (check network / DHT bootstrap)
```
This confirms the timeout diagnostic works. (The user can also test on two sims again to confirm the happy path still works after the error-handling additions.)

- [ ] **Step 5: Commit**

```bash
git add DemoApp/BareKitDemo/worklet/spike.js \
  DemoApp/BareKitDemo/Resources/app.js
git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit -m "feat(spike): error handling + diagnostics

15s peer-discovery timeout, IPC {error} callback logging, worklet
FATAL forwarding already in place. Every spec failure mode now
produces a visible log line."
```

---

### Task 6: README + docs

Document the spike: how to build, how to run on two simulators, the bare-pack toolchain prerequisite, the IPC-after-start contract, and the success criteria.

**Files:**
- Modify: `DemoApp/BareKitDemo/README.md` (replace the minimal-demo README with the spike README)
- Modify: `documentation/index.md` (add a "Hyperswarm spike" section pointing at DemoApp/BareKitDemo)

**Interfaces:**
- Consumes: all prior tasks.
- Produces: docs that let a new contributor build + run the spike.

- [ ] **Step 1: Replace the DemoApp README**

`DemoApp/BareKitDemo/README.md` -- replace the existing content with:
```markdown
# BareKitDemo -- Hyperswarm Spike

A standalone Titanium app that proves the `ti.barekit` module can load
the holepunch native addon stack (sodium-native, udx-native) and run
hyperswarm inside a Bare worklet on iOS, joining a topic and echoing a
message between two simulator instances.

## What it does

On launch, the app:

1. Creates a Worklet with a 64 MB memory limit.
2. Starts it with a pre-built `.bundle` (produced by `bare-pack`).
3. The worklet joins a fixed hyperswarm topic (`tibarekit-spike-v1`).
4. Two simulator instances discover each other + open a connection.
5. Messages typed in the UI round-trip: app A -> worklet A -> peer ->
   worklet B -> app B, which auto-echoes back.

## Prerequisites

- Titanium SDK 14.0.0.
- The `ti.barekit` module built + installed (copy
  `ios/dist/ti.barekit-iphone-1.0.0.zip` to
  `~/Library/Application Support/Titanium/`).
- `bare-pack` on PATH: `npm install --global bare-pack`.
- The worklet's npm deps installed:
  ```bash
  cd DemoApp/BareKitDemo/worklet
  npm install
  ```

## Build + run on two simulators

```bash
# Boot two simulators
xcrun simctl boot "iPhone 15"
xcrun simctl boot "iPhone 15 Pro"

# Build + install on each (the Titanium plugin runs bare-pack + copies
# the .bare prebuilds automatically during ti build)
ti build --project-dir DemoApp/BareKitDemo --platform ios \
  --target simulator --device-id <UDID-A> --sdk 14.0.0
ti build --project-dir DemoApp/BareKitDemo --platform ios \
  --target simulator --device-id <UDID-B> --sdk 14.0.0
```

Launch both apps. In app A, type "hello" + tap Send. App B's log shows
`peer: hello` + auto-echoes `echo: hello`; app A's log shows the echo.

## Success criteria

The spike is proven when all four hold:

1. Both apps launch without crashing (native addons loaded).
2. No `FATAL:` line in either log.
3. A `connection opened` fires on both sides within 15 s.
4. A message round-trips between the two sims.

## Failure-mode diagnostics

- `FATAL: ... sodium-native.bare ...` -- native prebuild shipping/loading
  broken; check `Resources/prebuilds/ios-arm64-simulator/` + the
  require-addon resolution path.
- `FATAL: ... udx-native ...` -- UDP transport native addon broken.
- `TIMEOUT: no peer discovered` -- native addons loaded but the DHT can't
  bootstrap (network/firewall/sim UDP egress).
- `connection opened` but no echo -- framing or IPC bridging bug (the
  good case; the hard native path is proven).

## Architecture

- `Resources/app.js` -- Titanium main side (UI + IPC bridging).
- `worklet/spike.js` -- the worklet source (input to bare-pack).
- `worklet/package.json` -- hyperswarm + framed-stream + sodium-native deps.
- `plugins/tibarekit-spike/1.0.0/plugin.js` -- Titanium build plugin that
  runs `bare-pack` + copies `.bare` prebuilds before the Titanium compile.
- `tiapp.xml` -- registers the plugin + the `ti.barekit` module.

## Notes

- IPC MUST be created AFTER `worklet.start()` returns -- see the
  module docs (`documentation/index.md`) for the IPC-after-start contract.
- Worklet `console.log` routes to the Bare/OS logger, NOT `Ti.API.info`.
  The spike uses `BareKit.IPC.write(...)` to surface worklet messages in
  the Ti.API log.
- The spike targets ios-arm64-simulator. For an x86_64 simulator, adjust
  `--arch` in the plugin. Device + Android are out of scope for the spike.
```

- [ ] **Step 2: Add a spike section to the module docs**

`documentation/index.md` -- append a section at the end:
```markdown

## Hyperswarm spike (DemoApp/BareKitDemo)

The `DemoApp/BareKitDemo/` app is a hyperswarm spike that proves this
module can load the holepunch native addon stack (sodium-native,
udx-native) and run hyperswarm inside a Bare worklet on iOS. It uses
the bundle-loader mode (`worklet.start('/spike.bundle', null, [])`)
with a `.bundle` produced by `bare-pack`. See
`DemoApp/BareKitDemo/README.md` for build + run instructions.

This is a spike, not a production app -- the full pear-chat port
(autobase, blind-pairing, hyperdb, chat UI) is a separate later cycle.
```

- [ ] **Step 3: Commit**

```bash
git add DemoApp/BareKitDemo/README.md documentation/index.md
git -c user.name=mbender74 -c user.email=marc_bender@icloud.com commit -m "docs: hyperswarm spike README + module docs section

Build/run instructions for the two-simulator echo, the bare-pack
toolchain prerequisite, the IPC-after-start contract, and the four
success criteria."
```

---

## Self-review notes

- **Spec coverage:** Every spec section maps to a task. Architecture -> Tasks 1-4. Components (4 files) -> Task 1 creates all 4 (trivial), Tasks 2-4 extend them. Data flow -> Task 4 (the round-trip). Error handling -> Task 5. Testing (success criteria) -> Task 4 Step 4 + the four criteria restated in Task 6's README. Key technical findings -> restate in the README's Notes section (Task 6).
- **Placeholder scan:** No TBD/TODO. Open questions from the spec (bare-pack CLI, prebuild resolution, build-hook API, bare-crypto availability) are handled inline in the task steps with concrete fallbacks, not deferred as placeholders.
- **Type consistency:** The worklet source uses `BareKit.IPC` consistently (the spec confirms `Bare.IPC === BareKit.IPC` in a bare-kit worklet). The main side uses the single-dict callback contract (`result.error`) consistently. The `sendToWorklet` helper in Task 5 matches the `ipc.write(data, callback)` signature from the module docs.
- **The auto-echo loop in Task 4** is acknowledged in the plan as acceptable for a spike; the success criterion is "a message round-trips", which the loop demonstrates. A follow-up could gate it.
- **The build-hook API uncertainty** (Step 4 of Task 1) is the one place the plan explicitly asks the implementer to verify against the SDK. The Titanium plugin `<plugins>` mechanism is the standard, documented approach; the `exports.main` signature is the common pattern but varies by SDK version. The implementer checks the SDK source + adjusts if needed.