// BareKitDemo - demonstrates the ti.barekit module (Worklet + IPC).
//
// The ti.barekit JS wrapper exports { Worklet, IPC }. Native callbacks
// (push reply, async read/write) deliver a SINGLE result dict:
//   push:    { reply: Ti.Blob } | { error: String } | {}
//   read:    { data: Ti.Blob }  | { error: String } | {}
//   write:   {}                 | { error: String }

const { Worklet, IPC } = require('ti.barekit');

const log = (msg) => {
  Ti.API.info('[BareKitDemo] ' + msg);
  if (logArea) {
    logLines.push(msg);
    logArea.setValue(logLines.join('\n'));
  }
};

const logLines = [];
let logArea = null;

// Worklet source runs inside the Bare runtime. Globals available there:
//   Bare              - the Bare runtime (Bare.on('uncaughtException', ...), etc.)
//   BareKit           - EventEmitter; BareKit.IPC is the IPC instance
//   BareKit.IPC.write(data) / .on('data', cb)  - IPC to main
//   BareKit.on('push', (payload, reply) => { reply(err, buf, encoding) }) - push handler
const workletSource = [
  "console.log('hello from the worklet');",
  "Bare.on('uncaughtException', (err) => {",
  "  BareKit.IPC.write('FATAL: ' + err.message);",
  "});",
  "BareKit.IPC.on('data', (data) => {",
  "  BareKit.IPC.write('echo: ' + data.toString());",
  "});",
  "BareKit.on('push', (payload, reply) => {",
  "  reply(null, Buffer.from('pong: ' + payload.toString()));",
  "});"
].join('\n');

const worklet = new Worklet({ memoryLimit: 24 * 1024 * 1024 });
const ipc = new IPC(worklet);

worklet.start('/app.js', workletSource, ['--demo']);

// Polling IPC: readable fires when data arrives from the worklet.
ipc.readable = () => {
  const d = ipc.read();
  if (d) log('[polling] worklet: ' + d.toString());
};

// All writes MUST happen after `writable` fires -- writing before the
// IPC channel is ready returns a negative byte count, which BareKit's
// write:completion: turns into an integer-overflow crash. Do the
// polling ping and the async write+read round-trip from here. A guard
// flag keeps this one-shot without nulling the setter (which would
// pass nil/NSNull to the native callback setter and is fragile).
let writableFired = false;
ipc.writable = () => {
  if (writableFired) return;
  writableFired = true;

  // Polling ping (sync write).
  ipc.write('ping from main (polling)');

  // Async write + read: write a line, then async-read the worklet's reply.
  ipc.write('async hello', (result) => {
    if (result.error) return log('write err: ' + result.error);
    ipc.read((r) => {
      if (r.error) return log('read err: ' + r.error);
      if (r.data) log('[async] worklet: ' + r.data.toString());
    });
  });
};

// Push: send 'check' to the worklet; the BareKit 'push' handler replies 'pong: check'.
worklet.push('check', (result) => {
  if (result.error) return log('push err: ' + result.error);
  if (result.reply) log('[push] reply: ' + result.reply.toString());
  else log('[push] (no reply)');
});

// Lifecycle: suspend at 2s, resume at 4s, terminate at 6s.
setTimeout(() => { worklet.suspend();  log('suspended');  }, 2000);
setTimeout(() => { worklet.resume();   log('resumed');   }, 4000);
setTimeout(() => { worklet.terminate(); log('terminated'); }, 6000);

// Simple UI: a window with a scrolling text area that mirrors the log.
const win = Ti.UI.createWindow({ backgroundColor: '#fff' });
logArea = Ti.UI.createTextArea({
  value: '',
  color: '#000',
  font: { fontSize: 12, fontFamily: 'Menlo' },
  editable: false,
  top: 20, left: 20, right: 20, bottom: 20,
  verticalAlign: 'top'
});
win.add(logArea);
win.open();

log('BareKitDemo started -- watch the console and this view for output.');