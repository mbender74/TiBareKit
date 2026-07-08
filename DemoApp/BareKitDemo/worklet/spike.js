// Task 3: prove hyperswarm + udx-native boot inside the worklet.
// Join a fixed topic; log connection events. No echo yet (Task 4).

// Keep the FATAL forwarder -- it's the diagnostic that tells us if a
// native addon (udx-native, sodium-native, etc.) fails to load.
Bare.on('uncaughtException', (err) => {
  BareKit.IPC.write('FATAL: ' + (err && err.message ? err.message : String(err)))
  if (err && err.stack) BareKit.IPC.write('STACK: ' + err.stack)
})

const Hyperswarm = require('hyperswarm')

// Buffer-literal topic: avoids the bare-crypto vs crypto uncertainty
// entirely. The topic just needs to be the same 32 bytes on both
// instances; a fixed 32-byte Buffer is fine for a spike.
const TOPIC_STRING = 'tibarekit-spike-v1'
const topic = Buffer.from('tibarekit-spike-v1-fixed-topic-32b!'.padEnd(32, '0'))

const swarm = new Hyperswarm()
swarm.on('connection', (socket) => {
  BareKit.IPC.write('connection opened')
  socket.on('error', (err) => BareKit.IPC.write('PEER ERROR: ' + (err && err.message ? err.message : String(err))))
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