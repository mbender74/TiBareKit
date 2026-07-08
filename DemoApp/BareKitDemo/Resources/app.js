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