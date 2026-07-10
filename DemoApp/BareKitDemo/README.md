# BareKitDemo -- Hyperswarm Spike

A standalone Titanium app that proves the `ti.barekit` module can load
the holepunch native addon stack (sodium-native, udx-native) and run
hyperswarm inside a Bare worklet on iOS, joining a topic and echoing a
message between two simulator instances.

This is a spike, not a production app. The full pear-chat port
(autobase, blind-pairing, hyperdb, chat UI) is a separate later cycle.
The spike's job is to prove the native runtime path works end to end.

## What it does

On launch, the app:

1. Creates a `Worklet` with a 64 MB memory limit.
2. Starts it with a pre-built `.bundle` (produced by `bare-pack` during
   the Titanium build via the `tibarekit-spike` plugin).
3. The worklet joins a fixed hyperswarm topic (`tibarekit-spike-v1`,
   a 32-byte Buffer derived from the shared string).
4. Two simulator instances discover each other through the DHT and open
   a framed-stream connection.
5. Messages typed in the UI round-trip: app A -> worklet A -> peer ->
   worklet B -> app B, which auto-echoes back. The echo guard stops
   `echo: echo: ...` from amplifying forever.

## Prerequisites

- Titanium SDK 13.3.0 (set as `<sdk-version>` in `tiapp.xml`; the
  module `minsdk` is also 13.3.0).
- The `ti.barekit` module built and installed. Build it from the
  module root:

  ```bash
  cd /Users/marcbender/Titanium-Modules/TiBareKit/ios
  ti build --build-only --sdk 13.3.0 --platform iphone
  # -> ios/dist/ti.barekit-iphone-1.0.0.zip
  ```

  Install it so this app can find it. The simplest path is to unzip
  the module directly into the app's local modules dir (this is what
  the spike uses):

  ```bash
  cd DemoApp/BareKitDemo
  unzip ../../ios/dist/ti.barekit-iphone-1.0.0.zip \
    -d modules/iphone/ti.barekit/1.0.0
  # the zip nests modules/iphone/ti.barekit/1.0.0/<contents>; flatten:
  cp -R modules/iphone/ti.barekit/1.0.0/modules/iphone/ti.barekit/1.0.0/* \
    modules/iphone/ti.barekit/1.0.0/
  rm -rf modules/iphone/ti.barekit/1.0.0/modules
  ```

  Alternatively copy the zip into the global Titanium modules dir
  (`~/Library/Application Support/Titanium/`) and `ti build` will
  pick it up.

- `bare-pack` on PATH: `npm install --global bare-pack`. The build
  plugin invokes it automatically.
- The worklet's npm deps installed:

  ```bash
  cd DemoApp/BareKitDemo/worklet
  npm install
  ```

## Build + run on two simulators

```bash
# Boot two simulators (any two iPhone-class devices work; use
# different models so you can tell them apart visually).
xcrun simctl boot "iPhone 17 Pro Max"
xcrun simctl boot "iPhone 17 Pro"
open -a Simulator   # bring the Simulator app to the front

# Build + install on each. The Titanium plugin runs bare-pack +
# copies the .bare prebuilds into Resources/ automatically during
# the build. Get the UDIDs via `xcrun simctl list devices booted`.
ti build --project-dir DemoApp/BareKitDemo --platform ios \
  --target simulator --device-id <UDID-A> --sdk 13.3.0
ti build --project-dir DemoApp/BareKitDemo --platform ios \
  --target simulator --device-id <UDID-B> --sdk 13.3.0
```

Launch both apps. In app A, type `hello` + tap Send (or press Return).
App B's log shows `peer: hello` and auto-echoes `echo: hello`; app A's
log receives the echo back.

## Success criteria

The spike is proven when all four hold:

1. Both apps launch without crashing (native addons loaded).
2. No `FATAL:` line in either log.
3. A `connection opened` fires on both sides within 15 s.
4. A message round-trips between the two sims (A -> B -> A).

## Failure-mode diagnostics

The spike emits a visible log line for every failure mode:

- `FATAL: ... sodium-native.bare ...` -- native prebuild
  shipping/loading broken; check
  `Resources/node_modules/<pkg>/prebuilds/ios-arm64-simulator/` and
  the `--offload-addons` flag in the plugin's `bare-pack` invocation.
- `FATAL: ... udx-native ...` -- UDP transport native addon broken.
- `TIMEOUT: no peer discovered (check network / DHT bootstrap)` --
  native addons loaded but the DHT can't bootstrap in 15 s
  (network/firewall/sim UDP egress). Not a crash.
- `WATCHDOG: worklet produced no IPC output for 30s -- likely crashed
  before startup` -- the worklet died silently before sending anything
  (e.g. a native addon crash during load). This only fires if the
  worklet produced zero IPC output; silence after initial output is
  treated as "idle / no peer", not "dead".
- `IPC ERR: ...` -- an `ipc.write` returned an error in its native
  callback. Surfaced by the `sendToWorklet` helper.
- `connection opened` but no echo -- framing or IPC bridging bug
  (the good case; the hard native path is proven).

## Architecture

- `Resources/app.js` -- Titanium main side. UI (log area + input row
  + send button), IPC bridging, auto-echo, appmem reporter, watchdog.
- `worklet/spike.js` -- the worklet source (input to `bare-pack`).
  Creates the hyperswarm, joins the topic, wraps peer sockets in
  framed streams, forwards peer data to main as `peer: <msg>`,
  forwards main data to the peer, 15 s discovery timeout, uncaught
  exception FATAL forwarder.
- `worklet/package.json` -- hyperswarm + framed-stream + sodium-native
  deps (sodium-native comes in transitively via hyperswarm/hyperdht).
- `plugins/tibarekit-spike/1.0.0/plugin.js` -- Titanium build plugin
  that runs `bare-pack --platform ios --offload-addons` on the worklet
  source and copies the `.bare` prebuilds into `Resources/` before the
  Titanium compile.
- `tiapp.xml` -- registers the `tibarekit-spike` plugin + the
  `ti.barekit` module, pins SDK 13.3.0.

## Notes

- **IPC MUST be created AFTER `worklet.start()` returns.** Creating
  the IPC channel before the worklet is started is a contract
  violation. See the module docs (`documentation/index.md`).
- **The writable callback is one-shot.** The native `BareIPC` writable
  source is a level-triggered GCD `DISPATCH_SOURCE_TYPE_WRITE` that
  fires continuously while the outgoing fd has buffer space (always,
  when idle). `ti.barekit` deregisters the native writable block on
  first fire, so `ipc.writable` delivers exactly one "ready to write"
  notification. Do not expect it to fire again; if you need another
  writable signal, reassign `ipc.writable`.
- **Worklet `console.log` routes to the Bare/OS logger, NOT
  `Ti.API.info`.** The spike uses `BareKit.IPC.write(...)` to surface
  worklet messages in the `Ti.API` log via the main-side `readable`
  callback.
- **The spike targets ios-arm64-simulator.** For an x86_64 simulator,
  adjust the arch in the plugin. Device + Android are out of scope for
  the spike.
- **`Ti.Platform.availableMemory` returns real values on 13.3.0** (it
  was silent/zero on 14.0.0 in our testing). The appmem reporter logs
  it every 5 s for diagnostics.