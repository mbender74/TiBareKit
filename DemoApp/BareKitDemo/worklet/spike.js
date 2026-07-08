// Trivial spike worklet -- proves the bundle loads + IPC works.
// Later tasks replace this with the hyperswarm join + echo logic.
BareKit.IPC.write('spike alive')
BareKit.IPC.on('data', (data) => {
  BareKit.IPC.write('echo: ' + data.toString())
})