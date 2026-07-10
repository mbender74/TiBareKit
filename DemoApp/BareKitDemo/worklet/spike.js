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

// 15s timeout: if no connection fires, tell main. Not a crash -- a
// diagnostic (the DHT may not bootstrap on a restricted network).
let connectionFired = false
swarm.on('connection', () => { connectionFired = true })

setTimeout(() => {
  if (!connectionFired) {
    BareKit.IPC.write('TIMEOUT: no peer discovered (check network / DHT bootstrap)')
  }
}, 15000)

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
  BareKit.IPC.write('FATAL: ' + (err && err.message ? err.message : String(err)))
  if (err && err.stack) BareKit.IPC.write('STACK: ' + err.stack)
})