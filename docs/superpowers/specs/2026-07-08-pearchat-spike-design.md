# TiBareKit Hyperswarm Spike Design

**Goal:** Prove TiBareKit can load the holepunch native addon stack
(sodium-native, udx-native) and run hyperswarm inside a Bare worklet
on iOS, joining a topic and echoing a message between two simulator
instances.

**Architecture:** A Titanium app (extending DemoApp/BareKitDemo in
place) runs a Bare worklet built by bare-build into a .bundle. The
worklet uses hyperswarm to join a fixed topic; two simulator
instances discover each other and round-trip a message. A tiapp.xml
build hook runs bare-build before the Titanium compile step and copies
the platform-correct .bare native prebuilds into the app Resources.

**Tech Stack:** Titanium SDK 14.0.0, ti.barekit module, holepunch
hyperswarm + udx-native + sodium-native, bare-build, framed-stream,
iOS simulator.

## Scope

This is the **spike** -- a minimal proof that the native-addon loading
and mobile networking path works through TiBareKit. It is not the full
pear-chat port. The full port (autobase, blind-pairing, hyperdb, chat
UI) is a separate, later spec/plan/implementation cycle that depends
on this spike proving the foundation.

**In scope:**
- bare-build bundle pipeline for a hyperswarm-using worklet
- Shipping .bare native prebuilds for ios-arm64-simulator + ios-x64-simulator
- Loading sodium-native + udx-native + hyperswarm inside a TiBareKit worklet
- Joining a hyperswarm topic on two iOS simulator instances
- Echoing one message between them with a round-trip
- Minimal Titanium UI (log view + text field + send button)

**Out of scope (deferred to the full port):**
- Android (iOS first; Android follows once iOS proves the path)
- autobase, blind-pairing, hyperdb, corestore persistence
- The pear-runtime updater worker (not applicable to Titanium)
- The full chat UI (message list with names, invite generation/paste, multi-room)
- Device builds (simulator only for the spike)
- Persistent storage (ephemeral in-memory hyperswarm state is fine)
- Mac Catalyst

## Key Technical Findings (from the feasibility investigation)

These are the facts that make the spike feasible rather than a
research project:

1. **The holepunch native stack ships mobile prebuilds.** Every
   native module hyperswarm depends on has prebuilds for ios-arm64,
   ios-arm64-simulator, ios-x64-simulator, and android-*:
   sodium-native (crypto), udx-native (UDP transport for the DHT),
   bare-tcp, bare-fs, rocksdb-native, rabin-native, quickbit-native,
   simdle-native, fs-native-extensions, and the bare-* runtime
   modules. Verified in
   /Users/marcbender/p2pchat/pear-docs/examples/getting-started/pear-chat/node_modules/*/prebuilds/.

2. **The .bare files are real native shared libraries.** sodium-native's
   ios-arm64/sodium-native.bare is a Mach-O arm64 dylib, LC_BUILD_VERSION
   platform 2 (iOS), minos 14.0, sdk 17.5, linking only libc++ and
   libSystem (self-contained). The ios-arm64-simulator slice is
   platform 7 (iOS Simulator). The .bare extension is Bare's
   native-addon convention (analogous to Node's .node).

3. **The Bare runtime embedded in TiBareKit can load .bare files.**
   BareKit.framework exports _bare_addon_load_dynamic,
   _bare_addon_load_static, _bare_addon_get_dynamic, _bare_addon_get_static,
   _bare_addon_teardown, _bare_module_find, _bare_module_register.
   _bare_addon_load_dynamic is the C entry point that dlopens a .bare
   file. This is the same loader Pear desktop uses; there is nothing
   desktop-only about it. sodium-native's binding.js calls
   require.addon('.', __filename) which resolves to this loader.

4. **Bare.IPC and BareKit.IPC are the same object inside a worklet.**
   bare-kit/shared/worklet.js:21 sets Bare.IPC = ipc and BareKit.IPC = ipc
   to the same instance. pear-chat's workers use new FramedStream(Bare.IPC);
   the same pattern works unchanged inside a TiBareKit worklet using
   BareKit.IPC.

5. **The IPC-after-start contract.** bare_worklet_init sets
   worklet->incoming = -1, worklet->outgoing = -1 (worklet.c:90-91).
   bare_ipc_init does ipc->incoming = dup(worklet->incoming) immediately
   (posix/ipc.c:7-8). bare_worklet_start blocks on a uv_barrier until
   the worklet thread has set valid fds (worklet.c:530-551). So new IPC(worklet)
   MUST be called AFTER worklet.start() returns, or the IPC channel
   dups -1 fds and readable/writable never fire. This was the root cause
   of the IPC echo lines being absent in the original BareKitDemo runtime
   log; the fix (create IPC after start) is already committed and documented.

## Architecture

Three layers:

1. **Titanium main side** (DemoApp/BareKitDemo/Resources/app.js) --
   creates a Worklet with the bundled spike source, opens an IPC
   channel, renders a minimal UI (log view + text field + send button).
   Sends typed messages over IPC to the worklet; displays lines received
   from the worklet in the log.

2. **Bare worklet** (spike.bundle, built by bare-build) -- runs inside
   the embedded Bare runtime. Uses hyperswarm to join a fixed topic
   derived from the shared string 'tibarekit-spike-v1'. On each peer
   connection, writes queued outbound messages and reads inbound
   messages, forwarding them to main over BareKit.IPC wrapped in
   framed-stream for message framing (matching pear-chat's worker
   pattern).

3. **Build pipeline** (tiapp.xml build hook) -- a <build-hook> in
   tiapp.xml runs bare-build before the Titanium compile step,
   producing Resources/spike.bundle and copying the platform-correct
   .bare prebuilds (sodium-native, udx-native, and any other native
   deps hyperswarm pulls in) into Resources/prebuilds/<platform-arch>/.
   ti build is a single command that runs everything. Requires every
   build machine to have bare-build + the bare-make toolchain
   installed.

## Components

Four files, each with one clear responsibility.

### 1. DemoApp/BareKitDemo/build-hook.js

The tiapp.xml build hook. Runs bare-build on the worklet source,
producing spike.bundle. Then copies the platform-correct .bare
prebuilds from node_modules/*/prebuilds/<platform-arch>/ into
Resources/prebuilds/<platform-arch>/. Detects target platform + arch
from the Titanium build context (iOS simulator vs iOS device,
arm64 vs x86_64). Exits non-zero on failure so ti build surfaces the
error. One responsibility: produce the bundle + prebuilds before the
Titanium compile.

The hook needs a node_modules tree to copy prebuilds from. It runs
npm install (or expects an existing node_modules) in a working dir
(likely DemoApp/BareKitDemo/worklet/ where spike.js lives) that
contains hyperswarm as a dependency. The hook's prebuild-copy step
walks node_modules/*/prebuilds/<target-arch>/*.bare and copies each
into Resources/prebuilds/<target-arch>/.

### 2. DemoApp/BareKitDemo/worklet/spike.js

The worklet source (input to bare-build). Creates a hyperswarm,
joins a fixed topic (a discovery key both instances derive the same
way from the shared string 'tibarekit-spike-v1'). On
swarm.on('connection', (socket) => ...), wraps the socket in a
framed-stream, reads inbound messages and forwards them to main via
BareKit.IPC.write(...), and writes outbound messages (received from
main via BareKit.IPC.on('data', ...)) into the stream. Installs
Bare.on('uncaughtException', ...) to forward FATAL:<msg> to main.
One responsibility: the hyperswarm join + echo loop.

### 3. DemoApp/BareKitDemo/Resources/app.js

The Titanium main side (replaces the current minimal demo). Creates a
Worklet with memoryLimit: 64 * 1024 * 1024 (hyperswarm + native addons
need more headroom than the 24 MB the old demo used). Starts it with
worklet.start('/spike.bundle', null, []) (bundle-loader mode -- null
source, .bundle filename). Creates IPC AFTER start (per the
IPC-after-start contract). Wires readable/writable. Renders the UI:
a Ti.UI.ListView for the log, a Ti.UI.TextField for input, a button
to send. Writes typed messages to the worklet via ipc.write(...) inside
the writable callback; displays lines received via readable in the
log. One responsibility: the Titanium UI + IPC bridging.

### 4. DemoApp/BareKitDemo/tiapp.xml

Register the build hook + confirm the module dep. Adds
<build-hook>build-hook.js</build-hook> under <ti:app>. The
<module version="1.0.0">ti.barekit</module> entry is already there
from the original BareKitDemo. One responsibility: wire the build
hook into the Titanium build.

## Data Flow

**Connection setup (both apps on launch):**

1. App A and App B both worklet.start('/spike.bundle', null, []).
2. Both worklets create a hyperswarm and swarm.join(topic) where
   topic is the discovery key derived from the shared string
   'tibarekit-spike-v1'.
3. udx-native opens UDP sockets; the DHT bootstraps against holepunch's
   public DHT nodes; the two swarms discover each other on the topic;
   a connection opens (over udx-native or raw TCP, hyperswarm handles
   the choice).
4. Each side's swarm.on('connection', (socket) => ...) fires; both
   wrap the socket in a framed-stream.

**Message round-trip (App A sends "hello"):**

1. App A main: user types "hello" in the TextField, taps send.
   ipc.write(framed('hello')) runs inside the writable callback.
2. Worklet A: BareKit.IPC.on('data', ...) receives the framed bytes,
   deframes to "hello", writes "hello" into the framed-stream to peer B.
3. Hyperswarm transports the frame over the connection to worklet B.
4. Worklet B: the framed-stream emits "hello"; worklet B does
   BareKit.IPC.write(framed('hello')) to main B.
5. App B main: readable fires; ipc.read() returns the framed bytes;
   deframe to "hello"; append "< B: hello" to the log. Then echo back:
   ipc.write(framed('echo: hello')).
6. Worklet B: receives "echo: hello" from main, writes into the
   framed-stream to peer A.
7. Hyperswarm transports the frame to worklet A.
8. Worklet A: framed-stream emits "echo: hello";
   BareKit.IPC.write(framed('echo: hello')) to main A.
9. App A main: readable fires; ipc.read() returns the frame; deframe;
   append "> A: echo: hello" to the log.

**Framing note:** both the main<->worklet IPC and the worklet<->peer
socket use framed-stream so message boundaries survive. The main side
uses framed-stream on the ipc.read()/ipc.write() byte stream; the
worklet side uses it on both BareKit.IPC and the hyperswarm socket.
The framing lib is pure JS (no native deps) so it loads cheaply on
both ends.

## Error Handling

Six failure modes the spike handles explicitly. Each surfaces to the
on-screen log + console (not a silent swallow).

1. **Native addon fails to load.** If sodium-native.bare or
   udx-native.bare can't be dlopen'd (missing prebuild, wrong platform
   slice, link error), the worklet's require('hyperswarm') throws on
   the first native-binding load. The worklet's
   Bare.on('uncaughtException', ...) handler catches it and forwards
   FATAL:<err.message> to main over IPC. Main displays it in the log.
   This is the single most likely spike failure -- the whole point is
   to see if it happens.

2. **DHT bootstrap / UDP failure.** udx-native opens UDP sockets to
   holepunch's public DHT bootstrap nodes. If the simulator has no
   network or UDP is blocked, swarm.join(...) won't error synchronously
   but no peers arrive. The spike sets a 15-second timer after join;
   if no connection event fires, main logs
   "TIMEOUT: no peer discovered (check network / DHT bootstrap)". Not
   a crash -- a visible diagnostic.

3. **Peer connection drops.** socket.on('error', ...) and
   socket.on('close', ...) on the framed-stream; worklet forwards
   "PEER DISCONNECTED" to main. Hyperswarm auto-reconnects; the spike
   doesn't retry manually. Visible in the log.

4. **IPC errors.** Write-before-writable is already prevented by the
   IPC-after-start contract + the writable guard. Async read/write
   callback {error} results are logged as "IPC ERR:<msg>". Sync write
   returning a negative byte count (shouldn't happen post-writable)
   is logged as a warning.

5. **Build-hook failure.** build-hook.js exits non-zero if bare-build
   isn't on PATH, if the worklet source has a syntax error, or if the
   target platform's prebuilds are missing from
   node_modules/*/prebuilds/. ti build surfaces the exit code + stderr.
   The hook prints which step failed and what to install.

6. **Worklet crash.** Bare.on('uncaughtException', ...) in the worklet
   forwards the message to main; main also observes the worklet
   terminating (no more readable events). The spike logs
   "WORKLET DIED:<msg>" and does not auto-restart (a spike -- the user
   re-runs).

No silent error swallowing anywhere. Every failure path produces a
log line the user can paste back.

## Testing

The spike has no automated test suite -- it's a manual two-simulator
verification. "Testing" means: run the spike on two simulators, observe
the log, confirm the message round-tripped. The build itself has one
mechanical check.

**Build verification (mechanical):**
- ti build -p ios --project-dir DemoApp/BareKitDemo --build-only
  succeeds. This proves the build hook ran bare-build, produced
  Resources/spike.bundle, copied the .bare prebuilds for
  ios-arm64-simulator (or ios-x64-simulator depending on the sim),
  and the Titanium compile packaged them. If the hook fails, ti build
  exits non-zero with the hook's stderr.

**Runtime verification (two-simulator procedure):**
1. Boot two iOS simulator instances: xcrun simctl boot "iPhone 15"
   and xcrun simctl boot "iPhone 15 Pro" (or any two distinct devices).
2. Build + install on both:
   ti build -p ios --project-dir DemoApp/BareKitDemo --target simulator
     --device-id <UDID-A>
   and the same for <UDID-B>.
3. Launch both apps.
4. In app A, type "hello" in the text field, tap send.
5. Observe: app B's log shows "< B: hello"; app A's log shows
   "> A: echo: hello".

**Success criteria** -- the spike is proven when all of these hold:
- App launches on both sims without crashing (native addons loaded).
- No FATAL: line in either log (no dlopen failure, no require throw).
- A connection event fires on both sides within 15 s (DHT bootstrap +
  peer discovery worked over udx-native).
- The "hello" -> "echo: hello" round-trip completes on the two-sim pair.

**What each failure tells us** (the spike's diagnostic value):
- FATAL: ... sodium-native.bare ... -> native prebuild shipping/loading
  path is broken; the build hook isn't copying the right slice, or
  require-addon can't resolve it in the Titanium asset layout.
- FATAL: ... udx-native ... -> UDP transport native addon broken; same
  shipping/loading issue, different module.
- TIMEOUT: no peer discovered -> native addons loaded but the DHT can't
  bootstrap (network, firewall, or udx-native sockets not working on
  the sim). Narrowing: try a desktop peer to isolate sim-vs-DHT.
- connection fires but no echo -> framing or IPC bridging bug; fixable
  in the worklet/main source, not a native-addon issue (the good case --
  the hard path is proven).

The spike's output is a paste of both logs back; that's the
verification artifact.

## Platform Support

iOS simulator only for the spike. ios-arm64-simulator + ios-x64-simulator
prebuilds (whichever matches the booted simulator). Device (ios-arm64)
and Android are deferred to the full port.

## Dependencies the spike introduces

- hyperswarm (and its transitive deps: hypercore, bare-stream, etc.)
- sodium-native (native, .bare prebuild)
- udx-native (native, .bare prebuild)
- framed-stream (pure JS)
- bare-build (build-time only, global npm install)

The worklet's package.json (in DemoApp/BareKitDemo/worklet/) lists
hyperswarm + framed-stream as deps; bare-build pulls in the transitive
native addons' prebuilds automatically via npm install.

## Open questions for the implementation plan

These are details the plan should nail down, not design-level unknowns:

- The exact bare-build CLI invocation and flags for producing a
  Titanium-loadable .bundle (vs a Pear-shaped .bundle). May need
  bare-build's --platform / --arch flags targeting ios-arm64-simulator.
- How the worklet's require() resolves the shipped prebuilds at runtime
  -- whether require-addon finds them in Resources/prebuilds/ as-is or
  needs a path/filename convention match with the bundle's recorded
  addon paths.
- Whether the build hook runs npm install itself or expects a
  pre-existing node_modules in DemoApp/BareKitDemo/worklet/.
- The exact Titanium build-hook API (the callback signature for a
  pre-compile hook in Titanium SDK 14.0.0).
- Whether hyperswarm on the iOS simulator can actually reach holepunch's
  public DHT bootstrap nodes (simulator networking is usually
  host-NAT'd; UDP egress should work but is unverified).