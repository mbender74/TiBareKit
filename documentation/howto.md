# How to build a chat app with social-network features on TiBareKit

A comprehensive guide to building a decentralized, end-to-end-encrypted chat +
social-feed app on iOS and Android with TiBareKit. The holepunch stack
(hyperswarm, hypercore, autobase, hyperbee, sodium-native, blind-pairing)
runs inside a Bare worklet; Titanium drives the UI and bridges to the worklet
over IPC.

This guide is a roadmap with working code snippets, not a complete
copy-paste app. The spike in `DemoApp/BareKitDemo/` proves the networking
layer (hyperswarm + framed-stream + sodium-native + udx-native) end to end
on iOS + Android arm64. Persistence (hypercore/autobase/hyperbee), the
social graph, encryption, media, notifications, and distribution are the
next layers -- standard holepunch, but the TiBareKit-specific integration
is unproven in this module context. Build incrementally and verify each
layer before stacking the next (the ladder is in "Verify each layer").

## Contents

- [What you're building](#what-youre-building)
- [Why TiBareKit](#why-tibarekit)
- [Architecture: what lives where](#architecture-what-lives-where)
- [Holepunch primer](#holepunch-primer)
- [Prerequisites](#prerequisites)
- [Project layout](#project-layout)
- [Step 1: Identity + key management](#step-1-identity--key-management)
- [Step 2: Conversation model + topic derivation](#step-2-conversation-model--topic-derivation)
- [Step 3: Networking with hyperswarm](#step-3-networking-with-hyperswarm)
- [Step 4: Message log with hypercore](#step-4-message-log-with-hypercore)
- [Step 5: Multi-writer ordering with autobase](#step-5-multi-writer-ordering-with-autobase)
- [Step 6: Social graph with hyperbee](#step-6-social-graph-with-hyperbee)
- [Step 7: The feed](#step-7-the-feed)
- [Step 8: Encryption model](#step-8-encryption-model)
- [Step 9: Media attachments](#step-9-media-attachments)
- [Step 10: IPC protocol host <-> worklet](#step-10-ipc-protocol-host---worklet)
- [Step 11: The Titanium UI](#step-11-the-titanium-ui)
- [Step 12: Build plugin + bundle](#step-12-build-plugin--bundle)
- [Step 13: Verify each layer](#step-13-verify-each-layer)
- [Step 14: Testing + debugging](#step-14-testing--debugging)
- [Step 15: Notifications + background](#step-15-notifications--background)
- [Step 16: Persistence + storage layout](#step-16-persistence--storage-layout)
- [Production considerations](#production-considerations)
- [Security threat model](#security-threat-model)
- [Deployment + distribution](#deployment--distribution)
- [What's proven vs what's the next layer](#whats-proven-vs-whats-the-next-layer)
- [Worked example: a "general" chat room, end to end](#worked-example-a-general-chat-room-end-to-end)
- [References](#references)

## What you're building

A peer-to-peer app with no central server:

- **Chat** -- real-time direct and group messages over framed streams,
  replicated peer-to-peer through hyperswarm's DHT.
- **Social feed** -- longer-form posts (like tweets/toots), persisted in
  per-user hypercores, linearized across followed authors via autobase.
- **Social graph** -- follow/unfollow, profiles, replicated via hyperbee.
- **Identity** -- a sodium-native keypair per user, persisted on device,
  bootstrap-authenticated via blind-pairing.
- **Media** -- images (and short video) in a dedicated blob core,
  referenced from messages, fetched on demand.
- **Encryption** -- hypercores are signed (authentic) but not private;
  private conversations encrypt content with crypto_box, keys derived
  via ECDH between participants.
- **Notifications** -- foreground-driven; background P2P is OS-limited
  (see "Notifications + background").

The app is "online when foregrounded" by default. True background
networking requires OS background modes with app-store review implications.

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
    + chat / feed / profile / follow views      + identity (sodium keypair)
    + navigation + state                        + hyperswarm (DHT peer discovery)
    + IPC readable/writable handlers            + framed-stream (peer msg framing)
    + sendToWorklet / handleWorkletMessage      + corestore + hypercore (message logs)
    + key persistence (Ti.Filesystem)          + autobase (multi-writer ordering)
                                               + hyperbee (profiles + social graph)
                                               + blind-pairing (bootstrap auth)
                                               + blob core (media)
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

### Data flow: sending a message

```
  Host (UI)                   IPC               Worklet                    Peer
  --------                    ---               -------                    ----
  user types "hi"
  sendToWorklet({type:'send', ---->            parse, validate
   text:'hi', conv:'general'})                 chat.send('hi','general')
                                               myMessages.append(buf)        --->
                                                                               framed-stream
                                                                               peer receives
                                               myMessages 'append' event
                                               emit('message', {...mine})
  ipc.readable fires           <----           BareKit.IPC.write(buf)
  handleWorkletMessage
  ui.appendMessage(...)
```

The host owns the keystroke; the worklet owns the message log + the wire.
The IPC round-trip is the only coupling.

## Holepunch primer

One paragraph per primitive so you know what each piece does and why it's
here. Check the holepunch repos for exact API signatures; the patterns below
are representative of current versions.

- **sodium-native** -- libsodium bindings. Provides signing keypairs
  (`crypto_sign_*`), authenticated symmetric encryption
  (`crypto_secretbox_*`), public-key encryption (`crypto_box_*`),
  key exchange (`crypto_kx_*` / `crypto_scalarmult_*`), and hashing
  (`crypto_generichash` = blake2b). Used for identity, message signing,
  private-conversation content encryption, and topic derivation.
- **udx-native** -- UDP transport. Hyperswarm's network layer. You don't
  touch it directly; hyperswarm wraps it.
- **hyperswarm** -- DHT-based peer discovery by topic. `swarm.join(topic)`
  finds other peers announcing the same topic; `swarm.on('connection')`
  gives you a duplex stream per peer. Connections are noise-handshake
  encrypted on the wire. The topic itself is a public DHT key -- anyone
  who knows it can find you. Used for discovery, not for privacy.
- **framed-stream** -- length-prefixed message framing over a duplex
  stream. Wraps a hyperswarm connection so you get discrete messages
  instead of a byte soup. Use for ad-hoc control messages; use hypercore
  replication (below) for the actual logs.
- **hypercore** -- an append-only, authenticated log. Single writer (the
  owner of the keypair); many readers (replicators). Every entry is
  signed; replication gives you the full history. `core.append(buf)`,
  `core.get(i)`, `core.length`, `core.replicate(stream)`. Used for
  per-user message logs.
- **corestore** -- a namespaced collection of hypercores. `store.get({
  name })` gives you a named core; `store.get({ key })` gives you a
  peer's core by public key. `store.replicate(stream)` replicates ALL
  cores in the store over one connection. Used as the single replication
  entry point so you don't wire each core separately.
- **autobase** -- multi-writer linearization over a set of input
  hypercores. Each writer appends to their own core; autobase merges them
  into one ordered view (causal clocks, dedup). `new Autobase(store,
  localKey, { inputs, localOutput, apply })`, `base.append(buf)`,
  `base.view.get(i)`. Used for conversations with multiple participants
  and for the feed.
- **hyperbee** -- a sorted key-value store backed by a hypercore.
  `bee.put(k,v)`, `bee.get(k)`, `bee.del(k)`, `bee.createReadStream()`.
  Single-writer like hypercore. Used for profiles and the follow graph.
- **blind-pairing** -- bootstrap authentication over hyperswarm. Lets
  two peers establish a trusted connection without exchanging keys in
  the clear or out-of-band. Used for first contact / invite flows.

The mental model: **hyperswarm finds peers, framed-stream + hypercore
replication move the data, hyperbee indexes it, autobase merges multiple
writers, sodium-native signs + encrypts it, blind-pairing bootstraps
trust.** The worklet orchestrates all of this; the host just shows the
results.

## Prerequisites

- TiBareKit module built + installed (see `README.md` -> Prebuild, or use
  `scripts/update-bare-kit.sh` to rebuild from a bare-kit checkout).
- `bare-pack` on PATH (`npm install --global bare-pack`).
- The build plugin. The easy path: run
  `./scripts/scaffold-barekit-plugin.sh --app-dir <your-app> --name <entry> --with-worklet`
  from the TiBareKit repo root -- it drops a parameterized copy of the
  demo's plugin into the app and seeds a starter `worklet/`. The manual
  path: copy `DemoApp/BareKitDemo/plugins/tibarekit-spike/` and adapt
  (see Step 12). Either way, the plugin runs `bare-pack` and the Android
  addon relocation at `build.pre.compile`.
- Worklet npm deps (pin in `worklet/package.json`):
  `hyperswarm`, `corestore`, `hypercore`, `autobase`, `hyperbee`,
  `sodium-native`, `framed-stream`, `blind-pairing`, `b4a`,
  `hypercore-crypto` (for key utilities), `compact-encoding` (for binary
  message codecs if you prefer binary over JSON).
- Titanium SDK 13.3.0.GA (pinned in `tiapp.xml`).
- For Android: an arm64-v8a AVD with API 31+ (the upstream `bare-kit`
  prebuilds target `minSdk` 31).

## Project layout

```
MyChatApp/
  tiapp.xml                  # registers ti.barekit module + your build plugin
  Resources/
    app.js                    # Titanium UI + IPC bridging
    ui/
      chat.js                 # chat screen
      feed.js                 # feed screen
      profile.js              # profile screen
      follow.js               # follow list screen
  worklet/
    app.js                    # worklet entry -- wires IPC, boots the stack
    identity.js               # sodium keypair + blind-pairing
    network.js                # hyperswarm join + peer connection handling
    chat.js                   # message log + chat protocol
    social.js                 # profiles + follows + feed aggregation
    blobs.js                  # media blob core
    crypto.js                 # conversation key derivation + content encryption
    proto.js                  # IPC message dispatch + emit
    package.json              # holepunch deps
  plugins/
    mychatapp-bundle/
      1.0.0/
        plugin.js             # adapted from tibarekit-spike plugin
        hooks/
          mychatapp-bundle.js # re-export for SDK 14.0.0 loader (see spike)
```

Each worklet file owns one concern. The host UI is split per-screen so a
single `app.js` doesn't become a god file.

## Step 1: Identity + key management

Each user has a sodium-native signing keypair. The host persists the
secret key in `Ti.Filesystem.applicationDataDirectory` (NOT in the
worklet -- the worklet's storage is for cores/bees, not for the master
key). On startup the host loads the key and sends the secret bytes to
the worklet over IPC.

```js
// worklet/identity.js
const sodium = require('sodium-native')
const b4a = require('b4a')

let identity = null

// Called at boot with the host-loaded secret key (Uint8Array), or null
// to create a new identity. The new identity's publicKey is emitted back
// to the host for persistence + display.
exports.boot = function (secretKeyBytes, emit) {
  if (secretKeyBytes) {
    const secretKey = b4a.from(secretKeyBytes, 'hex')
    const publicKey = sodium.crypto_sign_seed_keypair(secretKey).publicKey
    identity = { publicKey, secretKey }
  } else {
    const kp = sodium.crypto_sign_keypair()
    identity = { publicKey: kp.publicKey, secretKey: kp.secretKey }
    emit('identity', { publicKey: b4a.toString(identity.publicKey, 'hex'),
                       secretKey: b4a.toString(identity.secretKey, 'hex') })
  }
  return identity
}

exports.get = () => {
  if (!identity) throw new Error('identity not booted')
  return identity
}

// Curve25519 keypair for crypto_box (encryption). Derived from the
// ed25519 signing keypair so a user has one master secret.
exports.boxKeys = function () {
  const { secretKey } = exports.get()
  const boxKp = sodium.crypto_sign_ed25519_to_curve25519(secretKey)  // check API
  return boxKp
}

// Rotate: generate a new keypair, re-sign all owned cores with the new
// key, migrate follows. Out of scope for the spike; mentioned for completeness.
exports.rotate = function (emit) {
  // see "Production considerations" -> key rotation
}
```

```js
// Resources/app.js -- host side, key persistence
const keyFile = Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'identity.key')
let storedSecret = null
if (keyFile.exists()) {
  storedSecret = keyFile.read().text  // hex of the secret key
}
// after worklet start + writable fires:
sendToWorklet({ type: 'boot-identity', secretKey: storedSecret })

// in handleWorkletMessage:
case 'identity':
  // first-run: persist the secret key the worklet just generated
  keyFile.write(Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'identity.key').write(msg.secretKey)
  // ^ actually: keyFile.write(msg.secretKey) -- see Ti.Filesystem docs
  ui.showMyKey(msg.publicKey)
  break
```

**Key rules:**
- The secret key is the user's identity. Losing it loses the follow graph
  + message history. Back it up (out of scope; consider iCloud/Drive sync
  or a recovery phrase derived from the seed).
- Never log the secret key. Never send it anywhere except to the worklet
  at boot.
- The host owns persistence; the worklet owns use. This separation means
  a worklet `terminate()` + relaunch can re-derive the same identity.

**Blind-pairing** for first-time peer auth: bootstrap a connection
without exchanging keys in the clear. The sender and receiver both join
a temporary topic; blind-pairing establishes a noise channel and reveals
the participants' real public keys only after both sides consent. See
`holepunchto/blind-pairing` for the sender/receiver API; it rides on
top of hyperswarm. Use it for the "add contact" / "accept invite" flow,
not for everyday message exchange (everyday peers already know each
other's keys via the follow graph).

## Step 2: Conversation model + topic derivation

A conversation is a set of participants who replicate each other's
hypercores and linearize them via autobase. Participants find each other
through hyperswarm topics. The topic is a 32-byte blake2b hash.

```js
// worklet/network.js (topic helpers)
const sodium = require('sodium-native')
const b4a = require('b4a')

// Public topic: anyone who knows the string can join. Use for app-wide
// discovery (e.g. the "general" room, a public forum).
exports.publicTopic = function (name) {
  const out = b4a.allocUnsafe(32)
  sodium.crypto_generichash(out, b4a.from('mychatapp:public:' + name))
  return out
}

// Private topic: only the listed participants can derive it. Sort keys
// so both sides compute the same topic. Use for direct + group chats.
exports.privateTopic = function (participantPublicKeys) {
  const sorted = participantPublicKeys.map(k => b4a.from(k, 'hex')).sort(b4a.compare)
  const out = b4a.allocUnsafe(32)
  sodium.crypto_generichash(out, b4a.concat([b4a.from('mychatapp:private:'), ...sorted]))
  return out
}

// Per-user "presence" topic: derived from the user's own public key. Other
// peers join this topic to find the user directly. Used for DMs after
// the follow graph gives you someone's key.
exports.presenceTopic = function (publicKey) {
  const out = b4a.allocUnsafe(32)
  sodium.crypto_generichash(out, b4a.concat([b4a.from('mychatapp:presence:'), b4a.from(publicKey, 'hex')]))
  return out
}
```

| Conversation type | Topic derivation | Who can join | Privacy |
|---|---|---|---|
| Public room | `publicTopic(name)` | anyone who knows `name` | none (content still in your core; see Step 8) |
| Direct DM | `privateTopic([A, B])` | A + B only | topic is private; content needs Step 8 encryption |
| Group chat | `privateTopic([A, B, C, ...])` | listed participants | as above; rotate if membership changes |
| User presence | `presenceTopic(userKey)` | anyone who knows the user's key | public discovery, private messaging |

**Membership changes:** if a group's participant set changes, derive a
NEW topic (the old topic + old autobase is now stale; the old messages
are still readable by old members). Re-invite everyone to the new topic.
This is simpler than trying to evolve membership in-place; autobase
membership is a known-hard problem.

## Step 3: Networking with hyperswarm

Generalized from the spike's `worklet/spike.js`. The worklet keeps a
registry of joined topics + their peer connections, replicates the
corestore over every connection, and emits peer events to the host.

```js
// worklet/network.js
const Hyperswarm = require('hyperswarm')
const FramedStream = require('framed-stream')
const b4a = require('b4a')

const swarm = new Hyperswarm()
const joined = new Map()    // topicHex -> { conversation, peers: Set<peer> }
let corestore = null
let emit = null

exports.init = function (store, emitFn) {
  corestore = store
  emit = emitFn
  swarm.on('connection', (socket, info) => {
    // Replicate all cores in the store over this connection.
    const stream = corestore.replicate(socket, { live: true })
    // Framed stream for ad-hoc control messages (NOT core replication).
    const fr = new FramedStream(socket)
    fr.on('data', (msg) => handleControlMessage(msg, fr, info))
    socket.on('close', () => {
      for (const t of joined.values()) t.peers.delete(fr)
      emit('peer-closed', { host: info.host })
    })
    // Track the peer so the host can show connection count per conversation.
    // The peer is associated with a topic once the first control message
    // identifies which conversation it joined.
    fr._peerInfo = info
    emit('peer', { host: info.host, port: info.port })
  })
}

exports.joinConversation = function (conversation) {
  const topic = topicFor(conversation)
  const topicHex = b4a.toString(topic, 'hex')
  if (joined.has(topicHex)) return
  swarm.join(topic, { server: true, client: true })
  joined.set(topicHex, { conversation, peers: new Set() })
  return swarm.flush()  // resolves when the DHT has us announced
}

exports.leaveConversation = function (conversation) {
  const topic = topicFor(conversation)
  swarm.leave(topic)
  joined.delete(b4a.toString(topic, 'hex'))
}

exports.flush = () => swarm.flush()
exports.destroy = () => swarm.destroy()

function topicFor(conversation) {
  if (conversation.type === 'public') return exports.publicTopic(conversation.name)
  if (conversation.type === 'private') return exports.privateTopic(conversation.participants)
  if (conversation.type === 'presence') return exports.presenceTopic(conversation.publicKey)
  throw new Error('unknown conversation type: ' + conversation.type)
}

function handleControlMessage(msg, fr, info) {
  // msg = { type, conversation, ... }
  if (msg.type === 'hello') {
    const t = joined.get(b4a.toString(topicFor(msg.conversation), 'hex'))
    if (t) t.peers.add(fr)
  }
  // other control messages: leave-request, presence-ping, etc.
}
```

**Reconnection:** hyperswarm handles it -- if a peer drops, the swarm
re-discovers. You don't need manual reconnect logic. If the DHT itself
is unreachable (no network), `swarm.flush()` will hang; surface that to
the host as a `discovery-timeout` event after 15s (the spike's pattern).

**Bandwidth:** hyperswarm opens many UDP sockets; on mobile, keep an eye
on cellular data. Consider joining only the conversations the user has
open, not all of them at once.

## Step 4: Message log with hypercore

Each user's messages live in their own single-writer hypercore. The
corestore holds all the cores (yours + your peers' replicated ones). A
peer's core is fetched by key when you follow them or join a shared
conversation.

```js
// worklet/chat.js
const b4a = require('b4a')

let store = null
let myMessages = null
let emit = null

// Message schema. Versioned so old clients can reject unknown fields
// instead of crashing. Bump MAJOR for incompatible changes.
const SCHEMA_VERSION = 1

function encodeMessage(msg) {
  return b4a.from(JSON.stringify({ v: SCHEMA_VERSION, ...msg }))
}

function decodeMessage(buf) {
  const msg = JSON.parse(buf.toString())
  if (msg.v !== SCHEMA_VERSION) throw new Error('schema mismatch: ' + msg.v)
  return msg
}

exports.init = function (corestore, identity, emitFn) {
  store = corestore
  emit = emitFn
  myMessages = store.get({ name: 'my-messages', keyPair: identity })
  // Watch your own core for appends and notify the host.
  myMessages.on('append', async () => {
    const len = myMessages.length
    const node = await myMessages.get(len - 1)
    try {
      const msg = decodeMessage(node)
      emit('message', { ...msg, mine: true })
    } catch (e) { emit('error', { message: 'decode failed: ' + e.message }) }
  })
}

// Append a chat message to your own log. Returns the index.
exports.send = async function (text, conversation) {
  const msg = {
    type: 'chat',
    conversation,                       // { type, name } or { type, participants }
    text,
    author: b4a.toString(exports.identity.publicKey, 'hex'),
    ts: Date.now(),
    nonce: b4a.toString(randomBytes(24), 'hex')  // for dedup + crypto_box
  }
  await myMessages.append(encodeMessage(msg))
  return myMessages.length - 1
}

// Post (longer-form, like a tweet). Lives in your own core, appears in
// followers' feeds via Step 7.
exports.post = async function (text, attachments = []) {
  const msg = {
    type: 'post',
    text,
    attachments,                        // [{ blobId, mime, length }]
    author: b4a.toString(exports.identity.publicKey, 'hex'),
    ts: Date.now(),
    nonce: b4a.toString(randomBytes(24), 'hex')
  }
  await myMessages.append(encodeMessage(msg))
  return myMessages.length - 1
}

// Fetch a peer's message core by key (the host asks for this when the
// user opens a conversation with someone they follow).
exports.getPeerCore = function (peerPublicKeyHex) {
  return store.get({ key: b4a.from(peerPublicKeyHex, 'hex') })
}

// Recent messages from a single core (yours or a peer's).
exports.recent = async function (core, n) {
  const len = core.length
  const out = []
  for (let i = Math.max(0, len - n); i < len; i++) {
    out.push(decodeMessage(await core.get(i)))
  }
  return out
}
```

**Schema versioning is mandatory.** Once a message is in a hypercore,
it's there forever (append-only). A reader that doesn't understand a
field should skip it, not crash. Bump `SCHEMA_VERSION` on incompatible
changes; keep readers tolerant of newer minor versions.

**Dedup:** the `nonce` field lets consumers dedupe across replicas. Two
peers replicating your core see the same messages; if you fan-out a
message via both framed-stream AND core replication, the receiver uses
the nonce to drop the duplicate.

## Step 5: Multi-writer ordering with autobase

A conversation has multiple writers (each participant appends to their
own core). Autobase linearizes them into a single ordered view with
causal merge.

```js
// worklet/chat.js (continued)
const Autobase = require('autobase')

const conversations = new Map()  // conversationId -> Autobase

// Build the autobase for a conversation. inputs = the message cores of
// all participants. localOutput = a core where this node writes the
// linearized view. apply = the merge function.
exports.startConversation = async function (conversation, participantCores) {
  const id = conversationId(conversation)
  if (conversations.has(id)) return conversations.get(id)

  const base = new Autobase(store.session(), null, {
    inputs: participantCores,
    localOutput: store.get({ name: 'conv-' + id + '-output' }),
    apply: applyMessages
  })
  conversations.set(id, base)
  await base.view.update()
  return base
}

// The merge function: called with a batch of input nodes that are
// ready to be linearized. Must be deterministic + idempotent.
async function applyMessages(nodes) {
  for (const node of nodes) {
    let msg
    try { msg = decodeMessage(node.value) } catch { continue }  // skip junk
    // Dedup by nonce across replicas + across re-applies. Autobase may
    // re-apply a node after a fork resolution; the view must survive that.
    if (await seenNonce(msg.nonce)) continue
    await markSeenNonce(msg.nonce)
    // Append to the linearized view. The view is itself a hypercore; the
    // host reads it via exports.recentConversation.
    await this.view.append(node.value)
  }
}

exports.recentConversation = async function (conversation, n) {
  const base = conversations.get(conversationId(conversation))
  if (!base) return []
  await base.view.update()
  const len = base.view.length
  const out = []
  for (let i = Math.max(0, len - n); i < len; i++) {
    out.push(decodeMessage(await base.view.get(i)))
  }
  return out
}

exports.appendConversation = function (conversation, msg) {
  const base = conversations.get(conversationId(conversation))
  if (!base) throw new Error('conversation not started')
  return base.append(encodeMessage(msg))
}
```

**Causal clocks:** autobase tracks clock per writer; a message is
"ready" when all clocks it depends on have been seen. You don't manage
this manually -- autobase does.

**Forks:** if a writer appends two incompatible histories (e.g. two
devices with the same key, both offline), autobase picks one branch.
The losing branch's messages are not lost (still in the writer's core)
but won't appear in the view. This is rare in a chat app; mention it so
the user doesn't expect automatic merge of conflicting edits.

**The `apply` function must be deterministic + idempotent.** Autobase
may call it multiple times for the same node (after reconfiguration,
fork resolution, view reset). Don't allocate resources, don't emit
side effects, don't depend on wall-clock time. The `seenNonce` /
`markSeenNonce` above must be backed by a persistent store (a hyperbee
in the worklet's store) so it survives view resets.

## Step 6: Social graph with hyperbee

Profiles and the follow graph live in hyperbees (key-value stores backed
by hypercores). Your profile bee is single-writer; you replicate peers'
profile bees by key.

```js
// worklet/social.js
const Hyperbee = require('hyperbee')
const b4a = require('b4a')

let store = null
let identity = null
let profileBee = null
let followsBee = null
let followersIndex = null    // local-only, not replicated

exports.init = function (corestore, id, emit) {
  store = corestore
  identity = id
  profileBee = new Hyperbee(store.get({ name: 'profile', keyPair: id }), {
    keyEncoding: 'utf-8', valueEncoding: 'json'
  })
  followsBee = new Hyperbee(store.get({ name: 'follows' }), {
    keyEncoding: 'utf-8', valueEncoding: 'json'
  })
  // Followers index is built locally from incoming replication; not
  // replicated itself (it's derived from everyone else's follows bees).
  followersIndex = new Hyperbee(store.get({ name: 'followers-index' }), {
    keyEncoding: 'utf-8', valueEncoding: 'json'
  })
}

// -- Profile --

const PROFILE_PREFIX = 'p/'   // p/<field> = profile field value

exports.setProfile = function (field, value) {
  return profileBee.put(PROFILE_PREFIX + field, value)
}

exports.getProfile = async function (field) {
  const node = await profileBee.get(PROFILE_PREFIX + field)
  return node ? node.value : null
}

// Fetch a peer's profile by replicating their profile core (key derived
// from their public key) and reading their bee.
exports.getPeerProfile = async function (peerPublicKeyHex, fields) {
  const peerProfileCore = store.get({ key: b4a.from(peerPublicKeyHex, 'hex'),
                                      name: 'profile' })  // by key + name match
  await peerProfileCore.update()
  const peerBee = new Hyperbee(peerProfileCore, {
    keyEncoding: 'utf-8', valueEncoding: 'json'
  })
  const out = {}
  for (const f of fields) {
    const node = await peerBee.get(PROFILE_PREFIX + f)
    if (node) out[f] = node.value
  }
  return out
}

// -- Follow graph --

const FOLLOWS_PREFIX = 'f/'   // f/<pubkey-hex> = { since }

exports.follow = function (peerPublicKeyHex) {
  return followsBee.put(FOLLOWS_PREFIX + peerPublicKeyHex, { since: Date.now() })
}

exports.unfollow = function (peerPublicKeyHex) {
  return followsBee.del(FOLLOWS_PREFIX + peerPublicKeyHex)
}

exports.isFollowing = async function (peerPublicKeyHex) {
  return (await followsBee.get(FOLLOWS_PREFIX + peerPublicKeyHex)) !== null
}

// Stream all followed keys. Used by the feed (Step 7).
exports.followedKeys = async function* () {
  for await (const { key } of followsBee.createReadStream()) {
    if (key.startsWith(FOLLOWS_PREFIX)) yield key.slice(FOLLOWS_PREFIX.length)
  }
}

// Build the followers index by watching replicated follows bees of
// everyone you follow. Called periodically or on replication events.
exports.rebuildFollowersIndex = async function () {
  // for each peer you follow, replicate their follows bee, check if they
  // follow you, if yes add to followersIndex. Out of scope for the spike;
  // the followers list is "nice to have" -- the follows list is what the
  // feed needs.
}
```

**Profile schema:** keep it flat. `{ name, bio, avatar-blob-id, avatar-mime }`.
Avatar is a blob in your blob core (Step 9). Don't put large blobs
directly in the bee -- bee values are inline in the core; big blobs bloat
replication.

**The follow graph is asymmetric.** You follow someone by adding their
key to your follows bee. They don't have to follow back. Their followers
list is in THEIR follows bee, which you'd replicate to find out -- that's
the "followers index" rebuild above.

## Step 7: The feed

The feed is an autobase over the message cores of everyone you follow,
linearized by timestamp. Update it whenever a followed core appends or
you follow/unfollow someone.

```js
// worklet/social.js (continued)
const Autobase = require('autobase')

let feedBase = null
let feedInputs = new Set()   // pubKeyHex -> core

// Rebuild the feed from the current follows list. Call on app start +
// after follow/unfollow.
exports.rebuildFeed = async function () {
  const inputs = []
  for await (const key of exports.followedKeys()) {
    const core = store.get({ key: b4a.from(key, 'hex') })
    await core.update()
    inputs.push(core)
    feedInputs.add(key)
  }
  feedBase = new Autobase(store.session(), null, {
    inputs,
    localOutput: store.get({ name: 'feed-output' }),
    apply: applyFeed
  })
  await feedBase.view.update()
  emit('feed-rebuilt', { count: feedBase.view.length })
}

// Incremental: when a followed core appends, autobase picks it up on the
// next view.update(). Call this on a timer (every few seconds when
// foregrounded) or on a replication event.
exports.refreshFeed = async function () {
  if (!feedBase) return
  await feedBase.view.update()
}

exports.recentFeed = async function (n, before = null) {
  if (!feedBase) return []
  await feedBase.view.update()
  const len = feedBase.view.length
  const start = before != null ? before : len
  const out = []
  for (let i = Math.max(0, start - n); i < start; i++) {
    out.push(decodeMessage(await feedBase.view.get(i)))
  }
  return out.reverse()   // newest first
}

async function applyFeed(nodes) {
  for (const node of nodes) {
    let msg
    try { msg = decodeMessage(node.value) } catch { continue }
    if (msg.type !== 'post') continue   // feed is posts only; chat lives in convs
    if (await seenNonce(msg.nonce)) continue
    await markSeenNonce(msg.nonce)
    await this.view.append(node.value)
  }
}
```

**Pagination:** `recentFeed(n, before)` paginates backward from `before`
(an index). The host requests page 1 (`recentFeed(20)`), then page 2
(`recentFeed(20, len - 20)`), etc.

**Refresh strategy:** `refreshFeed` on a 2-5s timer when the feed screen
is open. Don't refresh when backgrounded (suspended). On a follow/unfollow,
call `rebuildFeed` (heavier; only on membership change).

**Feed filter:** the example shows posts only. For a mixed feed
(posts + chat from specific conversations), filter by `msg.type` in
`applyFeed` and track which conversations to include via the host
(user's open conversations).

## Step 8: Encryption model

Hypercores are signed (authentic -- you can prove the owner wrote it)
but NOT private (anyone replicating the core can read it). For private
conversations, encrypt the content.

### What's encrypted by default

- **Wire-level:** hyperswarm connections use a noise handshake. The
  network observer sees encrypted UDP; they can't read replicated data
  in transit.
- **Log-level (public rooms + posts):** NOT encrypted beyond the wire.
  Anyone who replicates your core can read your posts. That's the
  social-media model -- posts are public.

### What needs content encryption

- **Direct + group chats:** the `text` field should be encrypted so a
  peer replicating the core for indexing can't read it.

### Pattern: crypto_box with ECDH-derived shared key

```js
// worklet/crypto.js
const sodium = require('sodium-native')
const b4a = require('b4a')

// Derive a per-conversation shared key from the participant set.
// Each participant uses their own box secret key + the others' box
// public keys. For group chats, use a per-conversation symmetric key
// distributed to participants via 1:1 crypto_box (key-encryption-key
// pattern); this is more complex -- see "Group key management" below.
exports.conversationKey = function (myBoxSecretKey, peerBoxPublicKeys) {
  // For 1:1: ECDH(myBoxSecretKey, peerBoxPublicKey) -> shared key
  if (peerBoxPublicKeys.length === 1) {
    const shared = b4a.allocUnsafe(sodium.crypto_box_BEFORENMBYTES)
    sodium.crypto_box_beforenm(shared, peerBoxPublicKeys[0], myBoxSecretKey)
    return shared
  }
  // For groups: derive a per-conversation key from the participant set
  // so all members compute the same key. This is NOT private against
  // group members (they can all decrypt -- which is the point), but it
  // IS private against outsiders who don't know the membership. Use the
  // HKDF-ish pattern: blake2b(sorted participant box public keys).
  const sorted = [...peerBoxPublicKeys].sort(b4a.compare)
  const out = b4a.allocUnsafe(sodium.crypto_generichash_BYTES)
  sodium.crypto_generichash(out, b4a.concat(sorted))
  return out
}

exports.encrypt = function (key, plaintext) {
  const nonce = b4a.allocUnsafe(sodium.crypto_SECRETBOX_NONCEBYTES)
  sodium.randombytes_buf(nonce)
  const cipher = b4a.allocUnsafe(plaintext.length + sodium.crypto_SECRETBOX_MACBYTES)
  sodium.crypto_secretbox_easy(cipher, plaintext, nonce, key)
  return { nonce, cipher }
}

exports.decrypt = function (key, nonce, cipher) {
  const plain = b4a.allocUnsafe(cipher.length - sodium.crypto_SECRETBOX_MACBYTES)
  const ok = sodium.crypto_secretbox_open_easy(plain, cipher, nonce, key)
  if (!ok) throw new Error('decrypt failed')
  return plain
}
```

### Wire format for encrypted messages

The message in the hypercore has `text: null` and an `enc` field:

```js
{ type: 'chat', conversation, enc: { nonce, cipher, participants }, ts, nonce: dedupNonce }
```

Receivers in the conversation derive the same key (they have the
participant set from the conversation spec) and decrypt. Peers
replicating your core but not in the conversation see `{ type: 'chat',
enc: {...} }` -- they can't decrypt.

### Group key management

The simple group-key pattern above (blake2b of sorted participant keys)
works for "private against outsiders" but breaks if membership changes
-- a former member can still derive the old key and read old messages
(that's fine -- they were a member then). For FORWARD secrecy against
ejected members, rotate the conversation topic + key on membership change
(see Step 2). Full ratchet-style forward secrecy is out of scope; mention
it as a hardening step.

### What's NOT encrypted

- **Topic lookups:** the DHT sees which topic you join. A passive
  observer can correlate "this IP joins topic X" across time. Use
  private topics (Step 2) so the topic itself doesn't reveal the
  conversation's name, but the DHT still sees your IP + topic hash.
- **Message timing + size:** traffic analysis can correlate send/receive
  events. Out of scope; mention for completeness.
- **Replication metadata:** which cores you request reveals who you
  follow. The peer you're replicating from sees your request.

## Step 9: Media attachments

Images and short video go in a dedicated blob core per user, referenced
from messages by blob id. Receivers fetch the blob on demand.

```js
// worklet/blobs.js
const b4a = require('b4a')

let store = null
let myBlobs = null

exports.init = function (corestore, identity) {
  store = corestore
  myBlobs = store.get({ name: 'my-blobs', keyPair: identity, valueEncoding: 'binary' })
}

// Append a blob (Uint8Array of the file bytes). Returns the blob id
// (= the index in the core).
exports.put = async function (bytes) {
  await myBlobs.append(b4a.from(bytes))
  return myBlobs.length - 1
}

// Get a blob by (authorPublicKey, id). Replicates the peer's blob core
// if needed.
exports.get = async function (authorPublicKeyHex, id) {
  if (authorPublicKeyHex === b4a.toString(exports.identity.publicKey, 'hex')) {
    return myBlobs.get(id)
  }
  const peerBlobs = store.get({ key: b4a.from(authorPublicKeyHex, 'hex'), name: 'my-blobs' })
  await peerBlobs.update()
  return peerBlobs.get(id)
}
```

### Message reference

```js
{ type: 'post', text: 'look at this', attachments: [
  { author: myPubKeyHex, blobId: 42, mime: 'image/jpeg', length: 102400 }
]}
```

### Thumbnail strategy

Generate a thumbnail on the host (Titanium can resize) and send BOTH the
full image + thumbnail as separate blobs. The feed shows thumbnails;
tapping fetches the full blob. This keeps the feed snappy over slow links.

### Size gates

- Hard cap blob size in the host before send (e.g. 10 MB images, 50 MB
  video). Reject larger; the host UI should warn.
- The worklet's memory limit (Step 11) must exceed the max blob size or
  the append will OOM.

### Lazy fetch

The feed view includes attachment metadata but not the bytes. The host
fetches the blob only when the user scrolls to it. This is critical for
metered data -- don't auto-fetch every blob in the feed.

## Step 10: IPC protocol host <-> worklet

Formal spec for the byte stream between the Titanium host and the Bare
worklet. Use newline-delimited JSON. Every message is one JSON object,
serialized to a byte buffer, written via `ipc.write`.

### Wire format

```
<JSON object as UTF-8 bytes>      -- one per ipc.write call
```

The IPC channel is a byte stream; `BareKit.IPC.write(buf)` sends one
buffer. The receiver reads via `BareKit.IPC.on('data', cb)` (worklet) or
`ipc.read()` in the `readable` callback (host). Frame at the application
layer: one JSON object per write, parse on read. If a read returns a
partial buffer, buffer + retry -- but in practice the native bridge
delivers whole writes (the underlying pipe is message-preserving on
both platforms; verify if you see split reads).

### Message types

**Host -> Worklet:**

| Type | Fields | Purpose | Reply |
|---|---|---|---|
| `boot-identity` | `secretKey: string\|null` | load or create identity | `identity` (on new) |
| `send` | `text, conversation` | append chat message | `message` (via append event) |
| `post` | `text, attachments` | append a post | `message` (via append event) |
| `follow` | `peerKey` | follow a user | `followed` |
| `unfollow` | `peerKey` | unfollow a user | `unfollowed` |
| `set-profile` | `field, value` | set profile field | `profile-updated` |
| `get-profile` | `peerKey, fields` | fetch peer profile | `profile` |
| `get-feed` | `n, before` | paginated feed | `feed` |
| `get-conversation` | `conversation, n` | paginated chat history | `conversation` |
| `join-conversation` | `conversation` | join a conversation's topic | `joined` |
| `leave-conversation` | `conversation` | leave a topic | `left` |
| `put-blob` | `bytes, mime` | upload a blob | `blob-id` |
| `get-blob` | `author, blobId` | fetch a blob | `blob` (with bytes) |
| `suspend` | `linger?` | suspend the worklet | -- |
| `resume` | -- | resume the worklet | -- |
| `terminate` | -- | tear down the worklet | -- |

**Worklet -> Host:**

| Type | Fields | Purpose |
|---|---|---|
| `identity` | `publicKey, secretKey` | new identity created (persist + show) |
| `message` | `...msg, mine` | a message was appended (yours or a peer's via replication) |
| `peer` | `host, port` | a peer connected |
| `peer-closed` | `host` | a peer disconnected |
| `feed` | `items[]` | feed page result |
| `feed-rebuilt` | `count` | feed autobase was rebuilt |
| `conversation` | `items[]` | chat history page result |
| `joined` | `conversation` | joined a topic |
| `left` | `conversation` | left a topic |
| `followed` / `unfollowed` | `peerKey` | follow state changed |
| `profile` | `peerKey, fields` | profile result |
| `profile-updated` | `field` | profile field set |
| `blob-id` | `id` | blob uploaded |
| `blob` | `bytes` | blob fetched |
| `error` | `message, code?` | an error occurred |
| `discovery-timeout` | -- | DHT didn't bootstrap in 15s |
| `fatal` | `message` | worklet hit an unrecoverable error |

### Error handling

- Every async reply can be an `error` instead of the success type. The
  host's `handleWorkletMessage` should have an `error` case that logs +
  surfaces to the UI (a toast or status bar).
- The worklet's `proto.js` should wrap every handler in try/catch and
  emit `error` on failure. Never let a handler throw silently -- the host
  would see nothing and the user would think the app hung.
- The spike's `sendToWorklet` helper (in `DemoApp/BareKitDemo/Resources/app.js`)
  threads the async `ipc.write` callback's `{error}` into a visible log
  line. Reuse that pattern.

### Worklet side dispatch

```js
// worklet/proto.js
const b4a = require('b4a')

let handlers = {}

exports.register = function (type, fn) { handlers[type] = fn }

exports.start = function () {
  BareKit.IPC.on('data', (buf) => {
    let msg
    try { msg = JSON.parse(buf.toString()) } catch (e) {
      exports.emit('error', { message: 'bad json: ' + e.message })
      return
    }
    const fn = handlers[msg.type]
    if (!fn) { exports.emit('error', { message: 'unknown msg type: ' + msg.type }); return }
    Promise.resolve()
      .then(() => fn(msg))
      .catch(e => exports.emit('error', { message: msg.type + ': ' + e.message }))
  })
}

exports.emit = function (type, payload) {
  BareKit.IPC.write(b4a.from(JSON.stringify({ type, ...payload })))
}
```

```js
// worklet/app.js
const proto = require('./proto')
const identity = require('./identity')
const network = require('./network')
const chat = require('./chat')
const social = require('./social')
const blobs = require('./blobs')
const Corestore = require('corestore')
const path = require('bare-path')

const assets = global.BARE_ASSETS || './assets'  // set by host via worklet options
const store = new Corestore(path.join(assets, 'corestore'))

proto.register('boot-identity', (msg) => identity.boot(msg.secretKey, proto.emit))
proto.register('send',          (msg) => chat.send(msg.text, msg.conversation))
proto.register('post',          (msg) => chat.post(msg.text, msg.attachments))
proto.register('follow',        (msg) => social.follow(msg.peerKey).then(() => social.rebuildFeed()))
proto.register('unfollow',      (msg) => social.unfollow(msg.peerKey).then(() => social.rebuildFeed()))
proto.register('set-profile',   (msg) => social.setProfile(msg.field, msg.value))
proto.register('get-profile',   (msg) => social.getPeerProfile(msg.peerKey, msg.fields).then(p => proto.emit('profile', { peerKey: msg.peerKey, ...p })))
proto.register('get-feed',      (msg) => social.recentFeed(msg.n, msg.before).then(items => proto.emit('feed', { items })))
proto.register('join-conversation', (msg) => network.joinConversation(msg.conversation))
proto.register('leave-conversation', (msg) => network.leaveConversation(msg.conversation))
// ... etc.

identity.boot(null, proto.emit)  // null -> create new if not yet booted; host re-sends with real key
network.init(store, proto.emit)
chat.init(store, identity.get(), proto.emit)
social.init(store, identity.get(), proto.emit)
blobs.init(store, identity.get())

proto.start()

// Uncaught exception -> FATAL -> host logs it (the spike's pattern).
process.on('uncaughtException', (err) => {
  proto.emit('fatal', { message: err.stack || err.message })
})
```

### Host side

```js
// Resources/app.js -- IPC bridging
const { Worklet, IPC } = require('ti.barekit')

const assets = Ti.Platform.osname === 'android'
  ? Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'bare-assets').nativePath
  : null

const worklet = new Worklet({
  memoryLimit: 128 * 1024 * 1024,
  ...(assets ? { assets } : {})
})
worklet.start('/app.bundle', null, [])

const ipc = new IPC(worklet)   // AFTER start -- see contracts below

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
    case 'identity':       ui.showMyKey(msg.publicKey); persistKey(msg.secretKey); break
    case 'message':        ui.appendMessage(msg); break
    case 'peer':           ui.addPeer(msg); break
    case 'peer-closed':    ui.removePeer(msg); break
    case 'feed':           ui.renderFeed(msg.items); break
    case 'feed-rebuilt':   ui.onFeedRebuilt(msg.count); break
    case 'conversation':   ui.renderConversation(msg.items); break
    case 'joined':         ui.onJoined(msg.conversation); break
    case 'left':           ui.onLeft(msg.conversation); break
    case 'followed':       ui.onFollowed(msg.peerKey); break
    case 'unfollowed':     ui.onUnfollowed(msg.peerKey); break
    case 'profile':        ui.showProfile(msg.peerKey, msg); break
    case 'profile-updated':ui.onProfileUpdated(msg.field); break
    case 'blob-id':        ui.onBlobUploaded(msg.id); break
    case 'blob':           ui.onBlobFetched(msg.bytes); break
    case 'error':          Ti.API.error('worklet: ' + msg.message); ui.toast(msg.message); break
    case 'discovery-timeout': ui.onDiscoveryTimeout(); break
    case 'fatal':          Ti.API.error('FATAL: ' + msg.message); ui.onFatal(msg.message); break
    default:               Ti.API.warn('unknown worklet msg: ' + msg.type)
  }
}

// Boot: send the persisted identity key (or null to create new).
const keyFile = Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'identity.key')
sendToWorklet({ type: 'boot-identity', secretKey: keyFile.exists() ? keyFile.read().text : null })
```

### IPC contracts (recap -- see `index.md` for the full list)

1. **Create `new IPC(worklet)` AFTER `worklet.start()` returns.** The IPC
   dups fds that are invalid until start. Creating before yields a channel
   whose callbacks never fire.
2. **`ipc.writable` is one-shot.** It fires once; the native source is
   level-triggered but the proxy deregisters on first fire. Queue writes
   before it fires (the `pending` array above), reassign if you need another.
3. **Never `ipc.write(...)` before `writable` has fired.** Writing into a
   not-yet-armed fd crashes the worklet. The `writableFired` guard above.
4. **Single-dict callback.** Async `push` and `ipc.write(data, cb)`
   callbacks deliver one dict: `{error}` on failure, `{reply}` / `{}`
   on success.
5. **Worklet `console.log` does NOT route to `Ti.API`.** Use
   `BareKit.IPC.write` to surface worklet log lines in the Titanium log
   via the readable callback.
6. **`setWritable` reassignment is safe** (the re-entrancy race is fixed
   -- commit `b3e0578`; the native proxies capture the callback before
   the deferred dispatch). Reassigning creates a new arming; do it
   deliberately, not on every message.

## Step 11: The Titanium UI

Plain Titanium. Keep it thin -- state lives in the worklet (autobase
views, hyperbee gets); the UI just renders what the worklet emits and
forwards user input back. Split per-screen so a single `app.js` doesn't
become a god file.

```js
// Resources/app.js (continued) -- navigation skeleton
const win = Ti.UI.createWindow({ backgroundColor: '#fff' })
const tabs = Ti.UI.createTabGroup()

const chatTab = Ti.UI.createTab({ title: 'Chat', window: require('ui/chat').create() })
const feedTab = Ti.UI.createTab({ title: 'Feed', window: require('ui/feed').create() })
const profileTab = Ti.UI.createTab({ title: 'Profile', window: require('ui/profile').create() })
tabs.addTab(chatTab); tabs.addTab(feedTab); tabs.addTab(profileTab)
tabs.open()
```

```js
// Resources/ui/chat.js
exports.create = function () {
  const win = Ti.UI.createWindow({ title: 'Chat' })
  const list = Ti.UI.createListView({ sections: [{ items: [] }] })
  const input = Ti.UI.createTextField({ hintText: 'message...' })
  const sendBtn = Ti.UI.createButton({ title: 'Send' })

  sendBtn.addEventListener('click', () => {
    const text = input.value.trim()
    if (!text) return
    sendToWorklet({ type: 'send', text, conversation: { type: 'public', name: 'general' } })
    input.value = ''
  })

  win.add(list); win.add(input); win.add(sendBtn)
  return win
}

// ui namespace exposed globally by app.js so ui.* handlers work
global.ui = {
  appendMessage({ text, author, mine }) { /* update chat list */ },
  renderFeed(items) { /* update feed list */ },
  showMyKey(publicKey) { /* update profile screen */ },
  addPeer({ host }) { /* status bar */ },
  removePeer({ host }) { /* status bar */ },
  toast(msg) { Ti.UI.createAlertDialog({ message: msg }).show() },
  onFatal(msg) { /* full-screen error */ },
  onDiscoveryTimeout() { /* "no peers -- check network" banner */ }
}
```

**UI rules:**
- The UI never touches the filesystem, the network, or crypto. It only
  calls `sendToWorklet` and renders `handleWorkletMessage` results.
- Long lists: use `Ti.UI.createListView` (virtualized) -- the feed can
  grow to thousands of items.
- State: keep a per-screen JS object that mirrors what the worklet last
  sent. Don't re-request everything on every focus; request only the
  delta (e.g. `get-feed` with `before` for the next page).

## Step 12: Build plugin + bundle

**Automated path:** `scripts/scaffold-barekit-plugin.sh` (in the TiBareKit
repo) drops a parameterized copy of the demo's plugin into any Titanium
app, with the worklet entry name + bundle prefix substituted throughout,
and optionally seeds a starter `worklet/`. This is the recommended path
for new apps -- it avoids hand-editing the plugin's `id`, the bundle names,
and the `bare-pack` entry argument.

```bash
# from the TiBareKit repo root
./scripts/scaffold-barekit-plugin.sh \
  --app-dir /path/to/MyChatApp \
  --name chat \
  --plugin-name tibarekit-chat \
  --with-worklet
```

This writes `plugins/tibarekit-chat/1.0.0/{plugin.js, hooks/tibarekit-chat.js, package.json}`
and seeds `worklet/{chat.js, package.json}`. It prints the `tiapp.xml`
snippet to paste (the `<modules>` + `<plugins>` blocks). See `--help` for
all flags.

**Manual path:** Copy `DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/plugin.js`
and adapt: change the `id`, the worklet entry (`spike.js` -> `app.js`), and
the bundle names. The addon-resolution logic (iOS `--offload-addons`,
Android embed + `relocateAddonsToAssets`) is load-bearing -- keep it
verbatim. See `architecture.md` -> "Bundle + native addon resolution"
for why.

```js
// plugins/mychatapp-bundle/1.0.0/plugin.js -- key changes from the spike
export const id = 'mychatapp-bundle'
// ... in init() post:
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
<sdk-version>13.3.0.GA</sdk-version>
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

Bundle-loader mode: `worklet.start('/app.bundle', null, [])` -- the
`null` source means "load the bundle named by filename" (see `index.md`
-> "Bundle loader mode").

### Bundle debugging

If the worklet fails to start with a "module not found" error, the
bundle is missing a dep. `bare-pack` only bundles what's `require`'d
from the entry. Make sure every worklet file is reachable via `require`
from `worklet/app.js`. Dynamic `require` (variable arg) won't be
tracked -- use static `require` strings.

If a native addon fails to load at runtime (dlopen error), check:
- iOS: the `.bare` files exist in `Resources/node_modules/<pkg>/prebuilds/<host>/`
  (the `--offload-addons` flag in the plugin).
- Android: the bundle has `bundle.assets` containing the `.bare` keys
  (the `relocateAddonsToAssets` call). Inspect with `bare-bundle`:
  ```js
  const Bundle = require('bare-bundle')
  const b = Bundle.from(require('fs').readFileSync('Resources/app-android-arm64.bundle'))
  console.log('addons:', b.addons, 'assets:', b.assets)
  ```
  Addons should be empty; assets should contain the `.bare` paths.

## Step 13: Verify each layer

Don't stack the next layer until the current one is proven. Build + run
after each step, with concrete pass/fail signals:

1. **Networking only** -- join the topic, log `peer` + `peer-closed`
   events on both devices. No storage yet. (This is what the spike proves.)
   Pass: `connection opened` on both sides within 15s. Fail: `discovery-timeout`
   -> check network + DHT bootstrap.
2. **Add hypercore** -- append a message on device A, confirm it
   replicates to device B's corestore. Read it back on B and log it.
   Pass: B logs the message A appended. Fail: B's corestore has the core
   but length is 0 -> replication wired wrong; check `store.replicate` is
   called on every connection.
3. **Add autobase** -- two writers, confirm the linearized view converges
   on both devices (same order, same count). Pass: both devices report
   the same `view.length` after `view.update()`. Fail: views diverge ->
   the `apply` function isn't deterministic; check for wall-clock or
   non-idempotent side effects.
4. **Add hyperbee** -- follow on A, confirm B's profile bee replicates to
   A. Pass: A's `getPeerProfile(B)` returns B's profile fields. Fail: A
   gets null -> the peer profile core wasn't replicated; check the peer's
   profile core key matches the bee's backing core key.
5. **Add the feed** -- follow on A, post on B, confirm A's feed updates.
   Pass: A's feed includes B's post after a refresh. Fail: feed is empty
   -> `rebuildFeed` didn't include B's core; check `followedKeys` yields
   B's key.
6. **Add encryption** -- send an encrypted DM; from a third device
   replicating A's core (but not in the conversation), confirm the third
   device sees `enc.cipher` but cannot decrypt. Pass: third device's
   decrypt throws. Fail: third device decrypts -> the key derivation
   isn't participant-bound; check `conversationKey` includes ALL
   participant keys.
7. **Add media** -- attach an image to a post; on the receiver, confirm
   the blob fetches + renders. Pass: image appears. Fail: blob fetch
   hangs -> the peer's blob core isn't in the corestore replication; add
   it to `store.get({ key, name: 'my-blobs' })` on the receiver.
8. **Add the UI** -- drive everything from the Titanium side. Pass: the
   full flow (type, send, appear on receiver) works. Fail: UI events
   don't reach the worklet -> check `sendToWorklet` + the writable guard.

The watchdog + FATAL forwarder pattern from the spike
(`worklet/spike.js`) is worth keeping throughout: a 30s no-IPC-output
watchdog catches silent worklet deaths (native addon crash during
load), and an uncaughtException -> `fatal` -> IPC-write -> host-log
path surfaces worklet crashes in `Ti.API`.

## Step 14: Testing + debugging

### Unit tests for the protocol

The IPC protocol is pure JSON; test the dispatch + handlers without the
worklet. In Node, `require('./worklet/proto.js')`, register handlers,
call them with mock messages, assert the emitted messages.

```js
// test/proto.test.js (Node, not Bare)
const test = require('brittle')   // or any Node test framework
const proto = require('../worklet/proto')
// ... register handlers, send mock msgs, assert emit calls
```

This works because `proto.js` only uses `BareKit.IPC` at `start()` time;
the handlers themselves are plain JS.

### Integration: two worklets on two sims

The only end-to-end test that matters. Run the app on two sims, follow
each other, send a message, confirm round-trip. The spike's success
criteria (launch, no FATAL, connection in 15s, message round-trip with
echo guard) generalize. Add: feed replicates, follow persists across
relaunch.

### Inspecting the assets dir

On the Android emulator:
```bash
adb shell run-as <app-id> ls -la files/bare-assets/corestore/
adb shell run-as <app-id> ls -la files/bare-assets/corestore/<core-key>/
```
On iOS simulator: the app's container is under
`~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Data/Application/<app-id>/`.
`find` for `bare-assets/`.

### Log bridging

The worklet's `console.log` does NOT route to `Ti.API`. Use the
`fatal`/`error` emit pattern to surface worklet logs:
```js
// worklet side, dev-only
function debugLog(msg) {
  if (process.env.MYCHAT_DEBUG) proto.emit('debug', { message: msg })
}
// host side:
case 'debug': Ti.API.info('worklet: ' + msg.message); break
```
Gate behind an env var so prod builds don't spam the log.

### adb logcat + simctl

```bash
# Android -- watch for native addon loads + SELinux grants
adb logcat | grep -E 'TiAPI|bare-kit|avc: granted'
# iOS -- simulator logs
xcrun simctl spawn <UDID> log stream --predicate 'subsystem CONTAINS "TiBareKit"'
```
The `avc: granted { execute }` SELinux line on Android is the signal that
the addon-relocation workaround landed (the worklet extracted + dlopen'd
a `.bare`).

## Step 15: Notifications + background

This is the hard part of mobile P2P. Both iOS and Android aggressively
limit background networking.

### iOS

- Background UDP is suspended within seconds of backgrounding. The DHT
  drops; peers see you go offline.
- Options:
  - **Foreground-only:** the app only works when open. Simplest; the
    right default for a spike.
  - **VoIP/Audio background mode:** keeps a persistent network
    connection. App Store review will reject apps that use VoIP mode
    without actually providing VoIP, or audio mode without playing
    audio. Use only if your app genuinely is a VoIP/audio app.
  - **Push notifications (APNs):** a server (you DO need a server for
    this, even in a P2P app) sends a push when a peer wants to reach
    you. The push wakes the app briefly; the worklet boots, joins the
    topic, exchanges the message, then suspends. This is how a true P2P
    app can be "reachable" without a constant connection. The server
    only relays the "hey, X wants to talk" signal -- the actual message
    goes P2P.

### Android

- Doze mode kills background network on Android 6+. The worklet
  suspends; peers see you go offline.
- Options:
  - **Foreground service:** a persistent notification ("MyChatApp is
    running") keeps the app alive + network up. Users can disable it;
    Android may still kill it under memory pressure. The most reliable
    P2P background option.
  - **FCM:** same APNs pattern -- a server sends a high-priority FCM
    that wakes the app briefly.
  - **WorkManager:** for periodic (not real-time) sync. Not suitable for
    chat.

### What to actually build

1. Default: foreground-only. Suspend the worklet on `pause` event,
   resume on `resume`. This is what the spike does.
2. Later: add a push server (small, just relays "X has a message for
   you") + APNs/FCM. The push wakes the app, the worklet boots + joins
   + exchanges + suspends. This is a real project; budget for it.

### Worklet lifecycle mapping

```js
// Resources/app.js
Ti.App.addEventListener('pause',  () => sendToWorklet({ type: 'suspend', linger: 5000 }))
Ti.App.addEventListener('resume', () => sendToWorklet({ type: 'resume' }))
Ti.App.addEventListener('close', () => sendToWorklet({ type: 'terminate' }))  // careful: may not deliver
```

`terminate()` is terminal -- the worklet cannot be restarted; construct
a new `Worklet`. The `close` event may not deliver if the OS kills the
app hard; that's fine, the worklet dies with the process.

## Step 16: Persistence + storage layout

### What's on disk

```
<assets>/
  corestore/
    <core-key-hex>/         # one dir per hypercore in the store
      ...                    # hypercore internal files (oplog, blocks, tree)
  identity.key               # host-managed (Ti.Filesystem.applicationDataDirectory)
```

On Android, `<assets>` is `Ti.Filesystem.getFile(applicationDataDirectory, 'bare-assets').nativePath`.
On iOS, the worklet's storage is in the app's container (the worklet
resolves a writable dir from the `assets` option or the default).

### Growth

Hypercores are append-only. A busy conversation generates one append per
message; a year of chat can be hundreds of MB. Mitigations:

- **Truncate causal cores:** `core.truncate(length)` drops the oldest
  entries. Only safe if no reader needs the history. For chat, keep
  history (users want to scroll back).
- **Compact autobase outputs:** the autobase `localOutput` core can grow
  large; periodically reset it + rebuild from inputs. Autobase supports
  this; check the API.
- **Lazy blob fetch (Step 9):** blobs aren't auto-replicated; only fetch
  what the user opens.
- **Memory limit:** set `memoryLimit` high enough for the largest core
  you expect in RAM at once. The worklet OOMs if it exceeds this. 128 MB
  is a starting point; watch `Ti.Platform.availableMemory`.

### Backup + restore

The identity key is the only thing that MUST be backed up -- without it,
the user loses their identity + follow graph + the ability to write to
their cores. The cores themselves can be re-replicated from peers (as
long as at least one peer has them).

For full backup: zip the `corestore/` dir + the identity key. Restore:
unzip into the same paths. The worklet picks up the cores on next boot.

### Multi-account

To support multiple identities in one app: namespace the assets dir per
identity (`<assets>/<pubkey-hex>/corestore/`). Switch accounts by
terminating the worklet + starting a new one with a different assets dir
+ identity key.

## Production considerations

- **Key persistence is mandatory.** Without persisting the identity
  keypair, every app launch creates a new identity and the user loses
  their follow graph + message history. Store the secret key in
  `Ti.Filesystem.applicationDataDirectory`; never log it; never send it
  anywhere except to the worklet over IPC at boot.
- **Key rotation** is hard. Rotating the signing key means re-issuing
  all your owned cores under the new key. The simplest approach: a new
  identity is a new user; the old identity's cores stay readable but
  the new identity's writes are separate. Don't implement rotation
  unless you have a real need.
- **Worklet lifecycle.** `suspend()` when the app goes to background
  (iOS suspends background processes anyway; Android doze will kill the
  network). `resume()` on foreground. `terminate()` on logout (after
  persisting state). A worklet cannot be restarted after `terminate()` --
  construct a new `Worklet`.
- **Memory limit.** The spike uses 64 MB. A real chat app with
  hypercores + autobase views needs more -- start at 128 MB, watch
  `Ti.Platform.availableMemory` (the spike's appmem reporter), tune up
  if cores get large.
- **IPC error surfacing.** Use a `sendToWorklet` helper that threads
  `{error}` from the async write callback into a visible log line.
  Silent IPC errors are the worst failure mode -- the worklet looks
  alive but nothing reaches the host.
- **`setWritable` reassignment.** Safe (the re-entrancy race is fixed),
  but reassigning `ipc.writable` still creates a new arming; do it
  deliberately, not on every message.
- **Addon resolution is platform-specific.** iOS uses `--offload-addons`
  (NSBundle resolves `file:` URLs at runtime). Android embeds +
  relocates `bundle.addons` -> `bundle.assets` (the stock worklet only
  extracts `bundle.assets`). The build plugin handles both -- do NOT
  strip the `relocateAddonsToAssets` call or the `--offload-addons` flag.
  See `architecture.md` -> "Bundle + native addon resolution".
- **3 of 4 Android ABIs are runtime-untested.** The plugin builds +
  relocates all four (arm64-v8a, armeabi-v7a, x86, x86_64) but only
  arm64-v8a is exercised by the spike. Verify the others on actual
  devices/emulators before shipping.
- **Schema versioning.** Messages in hypercores are forever. Version
  the schema (`v: N`) and keep readers tolerant of newer minor versions.
  Bump MAJOR on incompatible changes; old clients should skip unknown
  fields, not crash.

## Security threat model

What's protected against what. Be explicit so users know what they're
getting.

| Threat | Protected? | How |
|---|---|---|
| Passive network observer reads messages | yes (wire) | hyperswarm noise handshake encrypts the wire |
| Passive observer reads private conversation content | yes (log) | crypto_box content encryption (Step 8) |
| Passive observer identifies participants | no | DHT sees your IP + topic hash; traffic analysis can correlate |
| Malicious peer sends junk to autobase | yes | `apply` validates + dedupes; junk doesn't enter the view |
| Malicious peer replays old messages | yes | causal clocks + nonce dedup reject stale/duplicate |
| Malicious peer forges a message from another user | yes | hypercore signatures; non-owner writes are rejected |
| Device thief reads messages | partial | messages are on disk unencrypted in the corestore; protect with OS-level full-disk encryption (default on iOS, depends on Android) |
| Device thief impersonates user | depends | identity key is on disk in `applicationDataDirectory`; protect with Secure Enclave / Keystore (out of scope; mention) |
| Weak topic guessed by attacker | depends | use `privateTopic` (Step 2) so the topic is derived from participant keys, not a guessable string |
| Former group member reads new messages | yes (after rotation) | rotate topic + key on membership change |
| Former group member reads OLD messages | no | they were a member then; old messages are readable to them forever (by design) |

### Known weaknesses

- **Metadata leaks:** IP addresses, connection times, message sizes are
  visible to peers + the DHT. This is inherent to P2P without additional
  mix-networking (out of scope).
- **No forward secrecy against device compromise:** if the device is
  compromised, all conversation keys in memory are exposed. A ratchet
  (double ratchet, Signal-style) would mitigate; out of scope for the
  spike.
- **First contact trust:** blind-pairing bootstraps, but the human has to
  verify the peer's key out-of-band (QR code, in-person) for full trust.
  Otherwise the first peer you pair with could be a MITM. This is the
  same trust model as Signal safety numbers.

## Deployment + distribution

### App Store (iOS)

- The native addons (sodium-native, udx-native) are static libs linked
  into the module's framework. Apple's static-lib signing is fine; no
  special entitlement for crypto.
- Background networking: if you use a background mode (VoIP/Audio),
  Apple will reject the app if the mode isn't genuinely used. The
  foreground-only default has no issue.
- Export compliance: the app uses encryption (sodium). Apple's
  App Store Connect has an "encryption exemption" questionnaire; for
  standard encryption (not custom), it's a one-line "yes, qualifies
  for exemption" -- check the current rules.
- The Catalyst slice (if you ship it) is binary-patched from iOS
  prebuilds. Verify it works in a Catalyst app before shipping; the patch
  changes only the `platform` field in `LC_BUILD_VERSION`, which "may
  have subtle runtime/ABI implications" per `README.md`.

### Play Store (Android)

- `minSdk` 31 (the upstream bare-kit prebuilds target this). Older
  devices can't load `libbare-kit.so`.
- The AAR ships four ABIs (arm64-v8a, armeabi-v7a, x86, x86_64). Only
  arm64-v8a is runtime-tested by the spike; verify the others.
- Foreground service for background networking: declare the foreground
  service type + a persistent notification. Play Store review checks for
  this.
- Export compliance: standard encryption declaration; check current
  rules.

### Module distribution

- Build the module from `ios/` + `android/` with `ti build --build-only`
  (or use `scripts/update-bare-kit.sh --verify` to rebuild + verify in
  one step).
- Ship the module zip to your app developers; they install it via the
  app's `modules/` dir or the global Titanium modules dir.

## What's proven vs what's the next layer

| Layer | Status in TiBareKit |
|---|---|
| Worklet + IPC API on iOS + Android | proven (module ships) |
| sodium-native loads on iOS + Android arm64 | proven (spike) |
| udx-native loads on iOS + Android arm64 | proven (spike) |
| hyperswarm join + DHT discovery + peer connection | proven (spike) |
| framed-stream message round-trip + echo guard | proven (spike) |
| `setWritable` re-entrancy race | fixed (commit `b3e0578`) |
| hypercore replication over the IPC-bridged connection | unproven -- Step 4 |
| autobase multi-writer ordering across two devices | unproven -- Step 5 |
| hyperbee profile + follow graph replication | unproven -- Step 6 |
| feed aggregation across followed authors | unproven -- Step 7 |
| crypto_box content encryption for private conversations | unproven -- Step 8 |
| media blob core + lazy fetch | unproven -- Step 9 |
| blind-pairing bootstrap auth | unproven -- Step 1 |
| background networking (APNs/FCM relay) | unproven -- Step 15 |
| armeabi-v7a / x86 / x86_64 Android ABIs at runtime | unproven (3 of 4) |
| Mac Catalyst slice at runtime | unproven (binary-patched, may have ABI quirks) |
| Schema migration across versions | unproven |

Build the unproven layers incrementally with the per-layer verification
in Step 13. If a layer doesn't behave, narrow the failure mode with the
spike's diagnostics (FATAL forwarder, watchdog, `IPC ERR` surfacing)
before stacking more on top.

## Worked example: a "general" chat room, end to end

A single public chat room: users join `general`, send messages, see each
other's messages. This is the smallest end-to-end slice -- it exercises
identity, networking, hypercore, autobase, IPC, UI, and the build
plugin. Use it as a template; layer Step 6+ on top once it works.

### worklet/app.js (complete)

```js
const b4a = require('b4a')
const sodium = require('sodium-native')
const Hyperswarm = require('hyperswarm')
const FramedStream = require('framed-stream')
const Corestore = require('corestore')
const Autobase = require('autobase')
const Hyperbee = require('hyperbee')
const path = require('bare-path')

const assets = global.BARE_ASSETS || './assets'
const store = new Corestore(path.join(assets, 'corestore'))

// -- Identity --
let identity = null
function bootIdentity(secretHex) {
  if (secretHex) {
    const sk = b4a.from(secretHex, 'hex')
    const kp = sodium.crypto_sign_seed_keypair(sk)  // derive pk from sk
    identity = { publicKey: kp.publicKey, secretKey: kp.secretKey }
  } else {
    const kp = sodium.crypto_sign_keypair()
    identity = { publicKey: kp.publicKey, secretKey: kp.secretKey }
    emit('identity', { publicKey: b4a.toString(identity.publicKey, 'hex'),
                       secretKey: b4a.toString(identity.secretKey, 'hex') })
  }
  initStack()
}

// -- Stack --
let myMessages, base, swarm
const ROOM = 'general'
function topicFor(name) {
  const out = b4a.allocUnsafe(32)
  sodium.crypto_generichash(out, b4a.from('mychatapp:public:' + name))
  return out
}

function initStack() {
  myMessages = store.get({ name: 'my-messages', keyPair: identity })
  // Autobase over your own core; add peer cores as they appear.
  base = new Autobase(store.session(), null, {
    inputs: [myMessages],
    localOutput: store.get({ name: 'general-output' }),
    apply: async (nodes) => {
      for (const node of nodes) {
        const msg = JSON.parse(node.value.toString())
        await base.view.append(node.value)
      }
    }
  })
  // Watch your own appends.
  myMessages.on('append', async () => {
    const node = await myMessages.get(myMessages.length - 1)
    emit('message', { ...JSON.parse(node.toString()), mine: true })
  })
  // Networking.
  swarm = new Hyperswarm()
  swarm.on('connection', (socket) => {
    store.replicate(socket, { live: true })
    const fr = new FramedStream(socket)
    fr.on('data', (buf) => {
      const msg = JSON.parse(buf.toString())
      if (msg.type === 'hello') {
        // Peer announced their message core key; add it to the autobase.
        const peerCore = store.get({ key: b4a.from(msg.coreKey, 'hex') })
        base.addInput(peerCore)
        emit('peer', { coreKey: msg.coreKey })
      }
    })
    // Announce ourselves.
    fr.write(b4a.from(JSON.stringify({
      type: 'hello', coreKey: b4a.toString(myMessages.key, 'hex')
    })))
  })
  swarm.join(topicFor(ROOM), { server: true, client: true })
  swarm.flush().then(() => emit('joined', { room: ROOM })).catch(
    () => setTimeout(() => emit('discovery-timeout', {}), 15000)
  )
  // Periodic refresh of the conversation view.
  setInterval(async () => {
    if (!base) return
    await base.view.update()
    const len = base.view.length
    const items = []
    for (let i = Math.max(0, len - 50); i < len; i++) {
      items.push(JSON.parse((await base.view.get(i)).toString()))
    }
    emit('conversation', { items })
  }, 2000)
}

// -- IPC --
function emit(type, payload) {
  BareKit.IPC.write(b4a.from(JSON.stringify({ type, ...payload })))
}
BareKit.IPC.on('data', (buf) => {
  const msg = JSON.parse(buf.toString())
  if (msg.type === 'boot-identity') bootIdentity(msg.secretKey)
  else if (msg.type === 'send') {
    const node = { type: 'chat', text: msg.text, author: b4a.toString(identity.publicKey, 'hex'), ts: Date.now() }
    myMessages.append(b4a.from(JSON.stringify(node)))
  }
})
process.on('uncaughtException', (err) => emit('fatal', { message: err.message }))
```

### Resources/app.js (complete, minimal UI)

```js
const { Worklet, IPC } = require('ti.barekit')

const assets = Ti.Platform.osname === 'android'
  ? Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'bare-assets').nativePath
  : null
const worklet = new Worklet({ memoryLimit: 128 * 1024 * 1024, ...(assets ? { assets } : {}) })
worklet.start('/app.bundle', null, [])
const ipc = new IPC(worklet)

const pending = []
let writableFired = false
ipc.writable = () => { writableFired = true; while (pending.length) ipc.write(pending.shift()) }
ipc.readable = () => { let buf; while ((buf = ipc.read())) handle(JSON.parse(buf.toString())) }

function send(msg) {
  const bytes = JSON.stringify(msg)
  if (!writableFired) { pending.push(bytes); return }
  ipc.write(bytes)
}

const win = Ti.UI.createWindow({ backgroundColor: '#fff' })
const list = Ti.UI.createListView({ sections: [{ items: [] }] })
const input = Ti.UI.createTextField({ hintText: 'message...' })
const sendBtn = Ti.UI.createButton({ title: 'Send' })
sendBtn.addEventListener('click', () => {
  if (!input.value.trim()) return
  send({ type: 'send', text: input.value.trim() })
  input.value = ''
})
win.add(list); win.add(input); win.add(sendBtn); win.open()

function handle(msg) {
  if (msg.type === 'conversation') {
    list.sections[0].items = msg.items.map(m => ({ properties: { title: (m.mine ? 'me: ' : '') + m.text } }))
  } else if (msg.type === 'identity') {
    const keyFile = Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'identity.key')
    keyFile.write(msg.secretKey)
    Ti.API.info('my key: ' + msg.publicKey)
  } else if (msg.type === 'peer') {
    Ti.API.info('peer connected: ' + msg.coreKey)
  } else if (msg.type === 'discovery-timeout') {
    Ti.API.warn('no peer discovered (check network / DHT bootstrap)')
  } else if (msg.type === 'fatal') {
    Ti.API.error('FATAL: ' + msg.message)
  }
}

const keyFile = Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'identity.key')
send({ type: 'boot-identity', secretKey: keyFile.exists() ? keyFile.read().text : null })
```

### Build + run

1. Copy the spike's build plugin to `plugins/mychatapp-bundle/1.0.0/`,
   change `id` + `spike.js` -> `app.js`.
2. `worklet/package.json`:
   ```json
   { "name": "mychatapp-worklet", "dependencies": {
       "hyperswarm": "*", "corestore": "*", "hypercore": "*",
       "autobase": "*", "hyperbee": "*", "sodium-native": "*",
       "framed-stream": "*", "b4a": "*", "bare-path": "*" } }
   ```
   `cd worklet && npm install`
3. `tiapp.xml`: register the plugin + `ti.barekit` module + pin SDK
   `13.3.0.GA`.
4. Build + run on two sims:
   ```bash
   ti build --project-dir MyChatApp --platform ios --target simulator --device-id <UDID-A> --sdk 13.3.0.GA
   ti build --project-dir MyChatApp --platform ios --target simulator --device-id <UDID-B> --sdk 13.3.0.GA
   ```
5. Type on A, see it appear on B's list. Type on B, see it on A. That's
   the smallest end-to-end slice -- everything else in this guide layers
   on top of this shape.

## References

- [`documentation/index.md`](index.md) -- API reference (`Worklet`, `IPC`,
  configuration, bundle-loader mode, contracts).
- [`documentation/architecture.md`](architecture.md) -- the two-layer
  model, native bridge, addon resolution (the non-obvious part), build
  pipeline, spike dataflow, platform divergence.
- [`DemoApp/BareKitDemo/`](../DemoApp/BareKitDemo/) -- the spike that
  proves the networking layer. Read `worklet/spike.js` for the hyperswarm
  + framed-stream + echo-guard pattern this guide generalizes, and
  `Resources/app.js` for the host-side IPC bridging + watchdog.
- [`scripts/update-bare-kit.sh`](../scripts/update-bare-kit.sh) -- rebuild
  bare-kit prebuilds + install into TiBareKit in one command.
- holepunch packages: [hyperswarm](https://github.com/holepunchto/hyperswarm),
  [hypercore](https://github.com/holepunchto/hypercore),
  [autobase](https://github.com/holepunchto/autobase),
  [hyperbee](https://github.com/holepunchto/hyperbee),
  [blind-pairing](https://github.com/holepunchto/blind-pairing),
  [sodium-native](https://github.com/holepunchto/sodium-native),
  [framed-stream](https://github.com/holepunchto/framed-stream),
  [corestore](https://github.com/holepunchto/corestore),
  [b4a](https://github.com/holepunchto/b4a).
- [pear](https://github.com/holepunchto/pear) -- the reference holepunch
  desktop chat + social app. Its protocol design is the canonical example
  of the stack this guide describes; the TiBareKit port is the mobile slice.
- [Hypercore protocol spec](https://github.com/holepunchto/hypercore/PROTOCOL.md)
  + [Autobase docs](https://github.com/holepunchto/autobase/README.md)
  for the deeper replication + merge semantics.