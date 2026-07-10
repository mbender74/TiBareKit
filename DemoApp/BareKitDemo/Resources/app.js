// TiBareKit hyperswarm spike -- Task 4: full UI + two-sim echo.
const { Worklet, IPC } = require('ti.barekit')

const MAX_LOG_LINES = 500
const log = (msg) => {
  Ti.API.info('[spike] ' + msg)
  logLines.push(msg)
  if (logLines.length > MAX_LOG_LINES) {
    logLines.splice(0, logLines.length - MAX_LOG_LINES)
  }
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
let lastReadable = Date.now()
let everReceivedReadable = false
let workletDeathReported = false

// Async write helper that surfaces {error} results from the native IPC
// callback. The native side returns a single-dict: {error: <msg>} on
// failure, {} on success. Threads through both write sites (send button
// + auto-echo) so IPC errors always produce a visible log line.
function sendToWorklet(text) {
  ipc.write(text, (result) => {
    if (result && result.error) log('IPC ERR: ' + result.error)
  })
}

const worklet = new Worklet({ memoryLimit: 64 * 1024 * 1024 })
worklet.start('/spike.bundle', null, [])

// IPC MUST be created AFTER worklet.start() returns.
const ipc = new IPC(worklet)

ipc.readable = () => {
  lastReadable = Date.now()
  everReceivedReadable = true
  const d = ipc.read()
  if (!d) return
  const msg = d.toString()
  log('worklet: ' + msg)

  // Auto-echo: if we received a "peer: <msg>" line, echo it back so the
  // originator sees a round-trip. Guard against re-echoing "echo: ..." --
  // without this, the two apps ping-pong "echo: echo: echo: ..." forever,
  // growing the string each round and flooding IPC + the log buffer.
  if (msg.indexOf('peer: ') === 0) {
    const payload = msg.slice('peer: '.length)
    if (payload.indexOf('echo: ') === 0) return
    const echoed = 'echo: ' + payload
    if (writableFired) {
      sendToWorklet(echoed)
      log('sent echo: ' + echoed)
    }
  }
}

ipc.writable = () => {
  if (writableFired) return
  writableFired = true
  log('IPC writable; ready to send')
}

// UI: input bar pinned to the TOP (guaranteed visible + tappable, clear of
// the home indicator), log fills the rest below. Earlier attempts pinned
// the input to the bottom, where the home indicator + safe-area insets
// made the field hard to tap on notched devices.
const win = Ti.UI.createWindow({ backgroundColor: '#fff' })


logArea = Ti.UI.createTextArea({
  value: '',
  color: '#000',
  font: { fontSize: 12, fontFamily: 'Menlo' },
  editable: false,
  touchEnabled: false,
  top: 10, left: 20, right: 20,
  bottom: 20,
  verticalAlign: 'top',
  backgroundColor: '#fafafa'
})
win.add(logArea)


const inputRow = Ti.UI.createView({
  layout: 'horizontal',
  bottom: 80, left: 20, right: 20,
  height: 50,
  backgroundColor: 'blue'
})
win.add(inputRow)

inputField = Ti.UI.createTextField({
  hintText: 'type a message',
  value: '',
  width: '72%',
  height: 40,
  borderStyle: Ti.UI.INPUT_BORDERSTYLE_ROUNDED,
  softKeyboardOnFocus: true,
  returnKeyType: Ti.UI.RETURNKEY_SEND,
  backgroundColor: '#fff'
})
inputRow.add(inputField)

const sendButton = Ti.UI.createButton({
  title: 'Send',
  width: '25%',
  height: 40,
  left: 8
})
inputRow.add(sendButton)

inputField.addEventListener('focus', () => log('field focused'))
inputField.addEventListener('blur', () => log('field blurred'))


function send() {
  const text = inputField.value
  if (!text || !writableFired) {
    log(!writableFired ? 'IPC not writable yet' : 'empty input')
    return
  }
  sendToWorklet(text)
  log('sent: ' + text)
  inputField.value = ''
}

sendButton.addEventListener('click', send)
inputField.addEventListener('return', send)

// Diagnostic: report app-side available memory every 5s alongside the
// worklet's RSS report. If availableMemory drops continuously while the
// worklet RSS climbs, the leak is native-side (DHT/udx/sodium).
setInterval(() => {
  const avail = Ti.Platform.availableMemory
  log('appmem avail=' + (avail ? (avail / 1024 / 1024).toFixed(1) + 'MB' : 'n/a'))
}, 5000)

// Worklet-death watchdog: fires only if the worklet produced ZERO IPC
// output for 30s since startup -- the true silent-crash case (a native
// addon crash before the worklet could send anything, including before
// the 15s TIMEOUT's setTimeout fires). If the worklet ever sent a line,
// it was alive at least briefly, so silence after that is "idle / no
// peer" not "dead" -- the watchdog stays quiet in that case.
setInterval(() => {
  if (!workletDeathReported && !everReceivedReadable && Date.now() - lastReadable > 30000) {
    workletDeathReported = true
    log('WATCHDOG: worklet produced no IPC output for 30s -- likely crashed before startup')
  }
}, 5000)

win.open()

log('spike app started. Type a message + tap Send. Run on TWO simulators.')