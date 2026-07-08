// Task 2: prove sodium-native loads inside the worklet.
Bare.on('uncaughtException', (err) => {
  BareKit.IPC.write('FATAL: ' + (err && err.message ? err.message : String(err)))
})

const sodium = require('sodium-native')

BareKit.IPC.write('sodium loaded, version=' + sodium.sodiumVersionString())

BareKit.IPC.on('data', (data) => {
  BareKit.IPC.write('echo: ' + data.toString())
})