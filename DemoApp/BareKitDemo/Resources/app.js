// TiBareKit hyperswarm spike -- Task 4: full UI + two-sim echo.
const { Worklet, IPC } = require('ti.barekit')

const log = (msg) => {
  Ti.API.info('[spike] ' + msg)
  logLines.push(msg)
  if (logArea) {
    logArea.value = logLines.join('\n')
    // Keep the latest lines visible.
    logArea.scrollToVisible ? logArea.scrollToVisible({ y: logLines.length * 14 }) : null
  }
}

const logLines = []
let logArea = null
let inputField = null
let writableFired = false

const worklet = new Worklet({ memoryLimit: 64 * 1024 * 1024 })
worklet.start('/spike.bundle', null, [])

// IPC MUST be created AFTER worklet.start() returns.
const ipc = new IPC(worklet)

ipc.readable = () => {
  const d = ipc.read()
  if (!d) return
  const msg = d.toString()
  log('worklet: ' + msg)

  // Auto-echo: if we received a "peer: <msg>" line, echo it back so the
  // originator sees a round-trip. This implements the spec's
  // "hello" -> "echo: hello" flow.
  if (msg.indexOf('peer: ') === 0) {
    const echoed = 'echo: ' + msg.slice('peer: '.length)
    if (writableFired) {
      ipc.write(echoed)
      log('sent echo: ' + echoed)
    }
  }
}

ipc.writable = () => {
  if (writableFired) return
  writableFired = true
  log('IPC writable; ready to send')
}

// UI: a log view (top) + a text field + send button (bottom).
const win = Ti.UI.createWindow({ backgroundColor: '#fff', layout: 'vertical' })

logArea = Ti.UI.createTextArea({
  value: '',
  color: '#000',
  font: { fontSize: 12, fontFamily: 'Menlo' },
  editable: false,
  top: 20, left: 20, right: 20,
  height: '78%',
  verticalAlign: 'top'
})
win.add(logArea)

const inputRow = Ti.UI.createView({
  layout: 'horizontal',
  top: 10, left: 20, right: 20, bottom: 20,
  height: Ti.UI.SIZE
})
win.add(inputRow)

inputField = Ti.UI.createTextField({
  hintText: 'type a message',
  value: '',
  width: '70%',
  height: 40,
  borderStyle: Ti.UI.INPUT_BORDERSTYLE_ROUNDED
})
inputRow.add(inputField)

const sendButton = Ti.UI.createButton({
  title: 'Send',
  width: '25%',
  height: 40,
  left: 10
})
inputRow.add(sendButton)

sendButton.addEventListener('click', () => {
  const text = inputField.value
  if (!text || !writableFired) {
    log(!writableFired ? 'IPC not writable yet' : 'empty input')
    return
  }
  ipc.write(text)
  log('sent: ' + text)
  inputField.value = ''
})

win.open()

log('spike app started. Type a message + tap Send. Run on TWO simulators.')