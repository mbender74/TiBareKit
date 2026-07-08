// Task 2: prove sodium-native loads + works inside the worklet.
Bare.on('uncaughtException', (err) => {
  BareKit.IPC.write('FATAL: ' + (err && err.message ? err.message : String(err)))
  if (err && err.stack) BareKit.IPC.write('STACK: ' + err.stack)
})

const sodium = require('sodium-native')

// Generate 32 random bytes using the native crypto to prove the addon
// is loaded AND functional (not just dlopen'd).
const buf = Buffer.alloc(32)
sodium.randombytes_buf(buf)
BareKit.IPC.write('sodium loaded, randombytes=' + buf.toString('hex').slice(0, 16) + '...')

BareKit.IPC.on('data', (data) => {
  BareKit.IPC.write('echo: ' + data.toString())
})