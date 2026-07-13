# How to build a chat app with social-network features on TiBareKit

A practical guide to building a decentralized, end-to-end-encrypted chat +
social-feed app on iOS and Android with TiBareKit. The holepunch stack
(hyperswarm, hypercore, autobase, hyperbee, sodium-native) runs inside a
Bare worklet; Titanium drives the UI and bridges to the worklet over IPC.

This guide is a roadmap with working code snippets, not a complete
copy-paste app. The spike in `DemoApp/BareKitDemo/` proved the networking
layer (hyperswarm + framed-stream + sodium-native + udx-native) end to end
on iOS + Android arm64. Persistence (hypercore/autobase/hyperbee) and the
social graph are the next layer -- standard holepunch, but the
TiBareKit-specific integration is unproven in this module context. Build
incrementally and verify each layer before stacking the next.

## What you're building

A peer-to-peer app with no central server:

- **Chat** -- real-time direct and group messages over framed streams,
  replicated peer-to-peer through hyperswarm's DHT.
- **Social feed** -- longer-form posts (like tweets/toots), persisted in
  per-user hypercores, linearized across followed authors via autobase.
- **Social graph** -- follow/unfollow, profiles, replicated via hyperbee.
- **Identity** -- a sodium-native keypair per user, persisted on device,
  bootstrap-authenticated via blind-pairing.

## Why TiBareKit

- The holepunch stack is Node-flavored JS that needs libuv + native addons.
  Titanium's V8/Hermes host can't run it directly. TiBareKit gives it an
  isolated Bare worklet (own thread, own heap, own libuv loop) with the
  native addon prebuilds shipped in the bundle.
- The UI stays on the Titanium main thread; CPU-heavy crypto + networking
  + storage run off-main-thread in the worklet.
- One codebase ships to iOS + Android. The build plugin handles the
  per-ABI native addon resolution (see `architecture.md` -- the non-obvious
  part).

## Architecture: what lives where

```
  Titanium host (UI + IPC bridging)            Bare worklet (holepunch stack)
  ----------------------------------          ----------------------------------------
  Resources/app.js                            worklet/app.js
    + chat / feed / profile views               + identity (sodium keypair)
    + IPC readable/writable handlers           + hyperswarm (DHT peer discovery)
    + sendToWorklet / handleWorkletMessage      + framed-stream (peer msg framing)
                                               + corestore + hypercore (message logs)
                                               + autobase (multi-writer ordering)
                                               + hyperbee (profiles + social graph)
                                               + blind-pairing (bootstrap auth)
                        |
                        |  IPC byte stream (readable / writable)
                        |  -- JSON messages, one line per frame
                        v
  [OS main thread]                            [Bare thread: own heap + libuv loop]
```

| Concern | Host (Titanium) | Worklet (Bare) |
|---|---|---|
| UI rendering | yes | never |
| Keypair storage | yes (Ti.Filesystem) | no (worklet gets bytes via IPC) |
| Networking | no | yes (hyperswarm + udx-native) |
| Crypto | no | yes (sodium-native) |
| Storage (cores, bees) | no | yes (worklet assets dir) |
| Peer protocol | no | yes (framed-stream + hypercore replication) |
| App state / views | Ti UI state | autobase views |

The split exists so the UI thread never blocks on crypto or network IO.
All native-to-JS callbacks (IPC readable/writable) are dispatched back onto
the platform main thread, so the JS side never thinks about thread affinity.

## Prerequisites

- TiBareKit module built + installed (see `README.md` -> Prebuild).
- `bare-pack` on PATH (`npm install --global bare-pack`).
- The build plugin copied from `DemoApp/BareKitDemo/plugins/tibarekit-spike/`
  and adapted (see Step 9). It runs `bare-pack` and the Android addon
  relocation at `build.pre.compile`.
- Worklet npm deps: `hyperswarm`, `corestore`, `hypercore`, `autobase`,
  `hyperbee`, `sodium-native`, `framed-stream`, `blind-pairing`, `b4a`.
  Pin versions in `worklet/package.json`.

## Project layout

```
MyChatApp/
  tiapp.xml                  # registers ti.barekit module + your build plugin
  Resources/
    app.js                    # Titanium UI + IPC bridging
  worklet/
    app.js                    # worklet entry -- wires IPC, boots the stack
    identity.js               # sodium keypair + blind-pairing
    network.js                # hyperswarm join + peer connection handling
    chat.js                   # message log + chat protocol
    social.js                 # profiles + follows + feed aggregation
    package.json              # holepunch deps
  plugins/
    mychatapp-bundle/
      1.0.0/
        plugin.js             # adapted from tibarekit-spike plugin
        hooks/
          mychatapp-bundle.js # re-export for SDK 14.0.0 loader (see spike)
```

## Step 1: Identity + key management

Each user has a sodium-native signing keypair. The host persists the secret
key in `Ti.Filesystem.applicationDataDirectory` (NOT in the worklet -- the
worklet's storage is for cores/bees, not for the master key). On startup the
host loads the key and sends the secret bytes to the worklet over IPC.

```js
// worklet/identity.js
const sodium = require('sodium-native')

let identity = null

exports.boot = function (secretKeyBytes) {
  if (secretKeyBytes) {
    // restore from host
    const publicKey = sodium.crypto_sign_ed25519_pk_to_curve25519(/* derive */)
    identity = { publicKey: /* from secret */, secretKey: secretKeyBytes }
  } else {
    const kp = sodium.crypto_sign_keypair()
    identity = { publicKey: kp.publicKey, secretKey: kp.secretKey }
    // send publicKey back to host for persistence + display
    emit('identity', { publicKey: b4a.toString(identity.publicKey, 'hex') })
  }
}

exports.get = () => identity
```

```js
// Resources/app.js -- host side
const keyPath = Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'identity.key')
let storedKey = null
if (keyPath.exists()) {
  storedKey = keyPath.read().text  // hex or base64 of the secret key
}
// after worklet start + writable fires:
sendToWorklet({ type: 'boot-identity', secretKey: storedKey })
```

**Blind-pairing** for first-time peer auth: bootstrap a connection without
exchanging keys in the clear. See `holepunchto/blind-pairing` for the
sender/receiver API; it rides on top of hyperswarm.

## Step 2: Networking with hyperswarm

Generalized from the spike's `worklet/spike.js`. Join a fixed topic (derived
from a shared string via blake2b), accept connections, wrap each peer socket
in a framed stream, and replicate the corestore over it.

```js
// worklet/network.js
const Hyperswarm = require('hyperswarm')
const FramedStream = require('framed-stream')
const sodium = require('sodium-native')
const b4a = require('b4a')

const swarm = new Hyperswarm()
const topic = b4a.allocUnsafe(32)
sodium.crypto_generichash(topic, b4a.from('mychatapp-v1'))

exports.boot = function (corestore) {
  swarm.join(topic, { server: true, client: true })
  swarm.on('connection', (socket, info) => {
    emit('peer', { host: info.host, port: info.port })
    // Replicate all cores in the store over this socket
    corestore.replicate(socket, { live: true })
    // Framed stream for ad-hoc control messages (not core replication)
    const fr = new FramedStream(socket)
    fr.on('data', (msg) => handleControlMessage(msg, fr, info))
    socket.on('close', () => emit('peer-closed', { host: info.host }))
  })
  return swarm.flush()
}

exports.leave = () => swarm.leave(topic)
exports.destroy = () => swarm.destroy()
```

The topic string (`mychatapp-v1`) is shared across all users -- anyone who
knows it can join. For private conversations, derive a per-conversation topic
from the participants' public keys so only they can discover each other.

## Step 3: Message log with hypercore

Each user's messages live in their own single-writer hypercore. The corestore
holds all the cores (yours + your peers' replicated ones). A peer's core is
fetched by key when you follow them.

```js
// worklet/chat.js
const Corestore = require('corestore')
const b4a = require('b4a')

let store, myMessages

exports.init = function (assetsDir, identity) {
  store = new Corestore(path.join(assetsDir, 'corestore'))
  myMessages = store.get({ name: 'my-messages', keyPair: identity })
}

exports.send = function (text, conversation) {
  const msg = { type: 'chat', conversation, text, ts: Date.now() }
  return myMessages.append(b4a.from(JSON.stringify(msg)))
}

exports.getPeerCore = function (peerPublicKey) {
  // Replicate a peer's message core by key
  return store.get({ key: peerPublicKey })
}

exports.replicateOver = function (socket) {
  store.replicate(socket, { live: true })
}

// Watch your own core for new appends and notify the host
myMessages.on('append', async () => {
  const len = myMessages.length
  const node = await myMessages.get(len - 1)
  emit('message', { ...JSON.parse(node.toString()), mine: true })
})
```

## Step 4: Multi-writer ordering with autobase

A conversation has multiple writers (each participant appends to their own
core). Autobase linearizes them into a single ordered view with causal merge.

```js
// worklet/chat.js (continued)
const Autobase = require('autobase')

let chatBase

exports.startConversation = function (participantCores, identity) {
  chatBase = new Autobase(store.session(), null, {
    inputs: participantCores,
    localOutput: store.get({ name: 'chat-output' }),
    apply: async (nodes) => {
      for (const node of nodes) {
        const msg = JSON.parse(node.value.toString())
        // dedupe + write to the linearized view
        await chatBase.view.append(node.value)
      }
    }
  })
}

exports.append = function (text) {
  return chatBase.append(b4a.from(JSON.stringify({ text, ts: Date.now() })))
}

exports.recent = async function (n) {
  await chatBase.view.update()
  const out = []
  const len = chatBase.view.length
  for (let i = Math.max(0, len - n); i < len; i++) {
    out.push(JSON.parse((await chatBase.view.get(i)).toString()))
  }
  return out
}
```

## Step 5: Social graph with hyperbee

Profiles and the follow graph live in hyperbees (key-value stores backed by
hypercores). Your profile bee is single-writer; you replicate peers' profile
bees by key.

```js
// worklet/social.js
const Hyperbee = require('hyperbee')

let profileBee, followsBee

exports.init = function (store, identity) {
  profileBee = new Hyperbee(store.get({ name: 'profile', keyPair: identity }), {
    keyEncoding: 'utf-8', valueEncoding: 'json'
  })
  followsBee = new Hyperbee(store.get({ name: 'follows' }), {
    keyEncoding: 'utf-8', valueEncoding: 'json'
  })
}

exports.setProfile = function (field, value) {
  return profileBee.put('profile/' + field, value)
}

exports.getProfile = function (field) {
  return profileBee.get('profile/' + field)
}

exports.follow = function (peerPublicKeyHex) {
  return followsBee.put(peerPublicKeyHex, { since: Date.now() })
}

exports.unfollow = function (peerPublicKeyHex) {
  return followsBee.del(peerPublicKeyHex)
}

exports.isFollowing = async function (peerPublicKeyHex) {
  return (await followsBee.get(peerPublicKeyHex)) !== null
}

// Stream all follows -- used to build the feed
exports.followedKeys = async function* () {
  for await (const { key } of followsBee.createReadStream()) yield key
}
```

## Step 6: The feed

The feed is an autobase over the message cores of everyone you follow,
linearized by timestamp. Update it whenever a followed core appends or you
follow/unfollow someone.

```js
// worklet/social.js (continued)
const Autobase = require('autobase')

let feedBase

exports.rebuildFeed = async function (store) {
  const inputs = []
  for await (const key of exports.followedKeys()) {
    inputs.push(store.get({ key: b4a.from(key, 'hex') }))
  }
  feedBase = new Autobase(store.session(), null, {
    inputs,
    localOutput: store.get({ name: 'feed-output' }),
    apply: async (nodes) => {
      for (const node of nodes) {
        const post = JSON.parse(node.value.toString())
        // filter by ts window, dedupe by (author + ts + hash)
        await feedBase.view.append(node.value)
      }
    }
  })
  await feedBase.view.update()
}

exports.recentFeed = async function (n) {
  const len = feedBase.view.length
  const out = []
  for (let i = Math.max(0, len - n); i < len; i++) {
    out.push(JSON.parse((await feedBase.view.get(i)).toString()))
  }
  return out
}
```

## Step 7: IPC protocol host <-> worklet

This is where the two worlds talk. Use newline-delimited JSON over the IPC
byte stream. The worklet side dispatches on `msg.type`; the host side does
the same for messages coming back.

```js
// worklet/app.js
const b4a = require('b4a')

BareKit.IPC.on('data', (buf) => {
  let msg
  try { msg = JSON.parse(buf.toString()) } catch (e) { return }
  switch (msg.type) {
    case 'boot-identity': identity.boot(msg.secretKey); break
    case 'send':          chat.send(msg.text, msg.conversation); break
    case 'post':          social.post(msg.text); break
    case 'follow':        social.follow(msg.peerKey); break
    case 'unfollow':      social.unfollow(msg.peerKey); break
    case 'set-profile':  social.setProfile(msg.field, msg.value); break
    case 'get-feed':      emit('feed', { items: await social.recentFeed(msg.n) }); break
    default:              emit('error', { message: 'unknown msg type ' + msg.type })
  }
})

function emit(type, payload) {
  BareKit.IPC.write(b4a.from(JSON.stringify({ type, ...payload })))
}
```

```js
// Resources/app.js -- host side
const { Worklet, IPC } = require('ti.barekit')

const worklet = new Worklet({
  memoryLimit: 128 * 1024 * 1024,  // chat + feed cores can grow; tune up
  ...(Ti.Platform.osname === 'android'
    ? { assets: Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'bare-assets').nativePath }
    : {})
})
worklet.start('/app.bundle', null, [])

const ipc = new IPC(worklet)  // AFTER start -- see contracts in index.md

const pending = []
let writableFired = false

ipc.writable = () => {
  if (writableFired) return
  writableFired = true
  while (pending.length) ipc.write(pending.shift())
}

ipc.readable = () => {
  let buf
  while ((buf = ipc.read())) {
    let msg
    try { msg = JSON.parse(buf.toString()) } catch (e) { Ti.API.error('bad msg: ' + e); continue }
    handleWorkletMessage(msg)
  }
}

function sendToWorklet(msg) {
  const bytes = JSON.stringify(msg)
  if (!writableFired) { pending.push(bytes); return }
  ipc.write(bytes)
}

function handleWorkletMessage(msg) {
  switch (msg.type) {
    case 'peer':        ui.addPeer(msg); break
    case 'peer-closed': ui.removePeer(msg); break
    case 'message':     ui.appendMessage(msg); break
    case 'feed':        ui.renderFeed(msg.items); break
    case 'identity':    ui.showMyKey(msg.publicKey); break
    case 'error':       Ti.API.error('worklet: ' + msg.message); break
  }
}
```

**IPC contracts to honor** (see `documentation/index.md` for the full list):

1. **Create `new IPC(worklet)` AFTER `worklet.start()` returns.** The IPC dups
   fds that are invalid until start. Creating before yields a channel whose
   callbacks never fire.
2. **`ipc.writable` is one-shot.** It fires once; the native source is
   level-triggered but the proxy deregisters on first fire. Queue writes
   before it fires (the `pending` array above), reassign if you need another.
3. **Never `ipc.write(...)` before `writable` has fired.** Writing into a
   not-yet-armed fd crashes the worklet. The `writableFired` guard above.
4. **Single-dict callback.** Async `push` and `ipc.write(data, cb)` callbacks
   deliver one dict: `{error}` on failure, `{reply}` / `{}` on success.
5. **Worklet `console.log` does NOT route to `Ti.API`.** Use `BareKit.IPC.write`
   to surface worklet log lines in the Titanium log via the readable callback.

## Step 8: The Titanium UI

The UI is plain Titanium. Keep it thin -- state lives in the worklet
(autobase views, hyperbee gets); the UI just renders what the worklet emits
and forwards user input back.

```js
// Resources/app.js (continued) -- sketch
const win = Ti.UI.createWindow({ backgroundColor: '#fff' })
const feedList = Ti.UI.createListView({ sections: [{ items: [] }] })
const input = Ti.UI.createTextField({ hintText: 'say something...' })
const sendBtn = Ti.UI.createButton({ title: 'Send' })

sendBtn.addEventListener('click', () => {
  const text = input.value.trim()
  if (!text) return
  sendToWorklet({ type: 'send', text, conversation: 'general' })
  input.value = ''
})

win.add(feedList); win.add(input); win.add(sendBtn)
win.open()

const ui = {
  appendMessage({ text, mine }) { /* update feedList */ },
  renderFeed(items)              { /* replace feedList items */ },
  addPeer({ host })              { /* status bar */ },
  removePeer({ host })           { /* status bar */ },
  showMyKey(publicKey)           { /* profile screen */ }
}
```

## Step 9: Build plugin + bundle

Copy `DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/plugin.js` and adapt:
change the `id`, the worklet entry (`spike.js` -> `app.js`), and the bundle
names. The addon-resolution logic (iOS `--offload-addons`, Android embed +
`relocateAddonsToAssets`) is load-bearing -- keep it verbatim. See
`architecture.md` -> "Bundle + native addon resolution" for why.

```js
// plugins/mychatapp-bundle/1.0.0/plugin.js -- key changes from the spike
export const id = 'mychatapp-bundle'
// ... in init():
  execSync(`bare-pack --host ${t.host} --out "${bundlePath}" app.js`, { cwd: workletDir })
```

In `tiapp.xml`, register the plugin + the module:

```xml
<plugins>
  <plugin version="1.0.0">mychatapp-bundle</plugin>
</plugins>
<modules>
  <module version="1.0.0">ti.barekit</module>
</modules>
```

Run it on two devices/sims (the spike's flow generalizes):

```bash
# iOS -- two simulators
ti build --project-dir MyChatApp --platform ios --target simulator --device-id <UDID-A> --sdk 13.3.0.GA
ti build --project-dir MyChatApp --platform ios --target simulator --device-id <UDID-B> --sdk 13.3.0.GA

# Android arm64 emulator
ti build --project-dir MyChatApp --platform android --target emulator --sdk 13.3.0.GA
```

The plugin runs `bare-pack` at `build.pre.compile`, producing
`Resources/app.bundle` (iOS, one host) and `Resources/app-android-<host>.bundle`
(Android, four ABIs). `app.js` selects the Android bundle matching
`Ti.Platform.architecture` at runtime, falling back to `android-arm64`.

Bundle-loader mode: `worklet.start('/app.bundle', null, [])` -- the `null`
source means "load the bundle named by filename" (see `index.md` ->
"Bundle loader mode").

## Step 10: Verify each layer

Don't stack the next layer until the current one is proven. Build + run after
each step:

1. **Networking only** -- join the topic, log `peer` + `peer-closed` events
   on both devices. No storage yet. (This is what the spike proves.)
2. **Add hypercore** -- append a message on device A, confirm it replicates
   to device B's corestore. Read it back on B and log it.
3. **Add autobase** -- two writers, confirm the linearized view converges on
   both devices (same order, same count).
4. **Add hyperbee** -- follow on A, confirm B's profile bee replicates to A.
5. **Add the feed** -- follow on A, post on B, confirm A's feed updates.
6. **Add the UI** -- drive everything from the Titanium side.

The watchdog + FATAL forwarder pattern from the spike (`worklet/spike.js`)
is worth keeping: a 30s no-IPC-output watchdog catches silent worklet deaths
(native addon crash during load), and an uncaughtException -> `FATAL:` ->
IPC-write -> host-log path surfaces worklet crashes in `Ti.API`.

## Production considerations

- **Key persistence is mandatory.** Without persisting the identity keypair,
  every app launch creates a new identity and the user loses their follow
  graph + message history. Store the secret key in
  `Ti.Filesystem.applicationDataDirectory`; never log it; never send it
  anywhere except to the worklet over IPC at boot.
- **Worklet lifecycle.** `suspend()` when the app goes to background (iOS
  suspends background processes anyway; Android doze will kill the network).
  `resume()` on foreground. `terminate()` on logout (after persisting state).
  A worklet cannot be restarted after `terminate()` -- construct a new
  `Worklet`.
- **Background networking is OS-limited.** iOS suspends background UDP; the
  DHT will drop. Design for "online when foregrounded" unless you implement
  a background mode (voip/audio) which has app-store review implications.
- **Memory limit.** The spike uses 64 MB. A real chat app with hypercores +
  autobase views needs more -- start at 128 MB, watch `Ti.Platform.availableMemory`
  (the spike's appmem reporter), tune up if cores get large.
- **IPC error surfacing.** Use a `sendToWorklet` helper that threads
  `{error}` from the async write callback into a visible log line. Silent
  IPC errors are the worst failure mode -- the worklet looks alive but
  nothing reaches the host.
- **`setWritable` reassignment.** Now safe (the re-entrancy race is fixed --
  the native proxies capture the callback before the deferred dispatch), but
  reassigning `ipc.writable` still creates a new arming; do it deliberately,
  not on every message.
- **Addon resolution is platform-specific.** iOS uses `--offload-addons`
  (NSBundle resolves `file:` URLs at runtime). Android embeds + relocates
  `bundle.addons` -> `bundle.assets` (the stock worklet only extracts
  `bundle.assets`). The build plugin handles both -- do NOT strip the
  `relocateAddonsToAssets` call or the `--offload-addons` flag. See
  `architecture.md` -> "Bundle + native addon resolution" for the why.
- **3 of 4 Android ABIs are runtime-untested.** The plugin builds + relocates
  all four (arm64-v8a, armeabi-v7a, x86, x86_64) but only arm64-v8a is
  exercised by the spike. Verify the others on actual devices/emulators
  before shipping.

## What's proven vs what's the next layer

| Layer | Status in TiBareKit |
|---|---|
| Worklet + IPC API on iOS + Android | proven (module ships) |
| sodium-native loads on iOS + Android arm64 | proven (spike) |
| udx-native loads on iOS + Android arm64 | proven (spike) |
| hyperswarm join + DHT discovery + peer connection | proven (spike) |
| framed-stream message round-trip + echo guard | proven (spike) |
| `setWritable` re-entrancy race | fixed (commit `b3e0578`) |
| hypercore replication over the IPC-bridged connection | unproven -- Step 3 |
| autobase multi-writer ordering across two devices | unproven -- Step 4 |
| hyperbee profile + follow graph replication | unproven -- Step 5 |
| feed aggregation across followed authors | unproven -- Step 6 |
| blind-pairing bootstrap auth | unproven -- Step 1 |
| armeabi-v7a / x86 / x86_64 Android ABIs at runtime | unproven (3 of 4) |
| Mac Catalyst slice at runtime | unproven (binary-patched, may have ABI quirks) |

Build the unproven layers incrementally with the per-layer verification in
Step 10. If a layer doesn't behave, narrow the failure mode with the
spike's diagnostics (FATAL forwarder, watchdog, `IPC ERR` surfacing) before
stacking more on top.

## References

- [`documentation/index.md`](index.md) -- API reference (`Worklet`, `IPC`,
  configuration, bundle-loader mode, contracts).
- [`documentation/architecture.md`](architecture.md) -- the two-layer model,
  native bridge, addon resolution (the non-obvious part), build pipeline,
  spike dataflow, platform divergence.
- [`DemoApp/BareKitDemo/`](../DemoApp/BareKitDemo/) -- the spike that proves
  the networking layer. Read `worklet/spike.js` for the hyperswarm +
  framed-stream + echo-guard pattern this guide generalizes.
- holepunch packages: [hyperswarm](https://github.com/holepunchto/hyperswarm),
  [hypercore](https://github.com/holepunchto/hypercore),
  [autobase](https://github.com/holepunchto/autobase),
  [hyperbee](https://github.com/holepunchto/hyperbee),
  [blind-pairing](https://github.com/holepunchto/blind-pairing),
  [sodium-native](https://github.com/holepunchto/sodium-native),
  [framed-stream](https://github.com/holepunchto/framed-stream).
- [pear](https://github.com/holepunchto/pear) -- the reference holepunch
  desktop chat + social app. Its protocol design is the canonical example
  of the stack this guide describes; the TiBareKit port is the mobile slice.