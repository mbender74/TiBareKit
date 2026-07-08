// Titanium CommonJS extension for ti.barekit.
//
// This file is loaded by the Titanium kernel as the module's CommonJS
// extension: its `module.exports` are merged into the native module proxy
// returned by `require('ti.barekit')`. To reach the native factories
// (createWorklet / createIPC) from inside the classes below, we call
// `require('ti.barekit')` at method-invocation time, NOT at top level --
// a top-level self-require would re-enter the kernel's extension step and
// recurse (see titanium_mobile common/Resources/ti.internal/kernel/module.js,
// extendModuleWithCommonJs / loadExternalModule).

const isAndroid = Ti.Platform.name === 'android';

class Worklet {
  constructor(options) {
    this._proxy = require('ti.barekit').createWorklet(options || {});
  }

  start(filename, source, arguments_) {
    if (arguments_ === undefined) arguments_ = [];
    if (source === undefined) source = null;
    this._proxy.start(filename, source, arguments_);
  }

  suspend(linger) {
    if (linger === undefined) this._proxy.suspend();
    else this._proxy.suspend(linger);
  }

  resume() { this._proxy.resume(); }
  terminate() { this._proxy.terminate(); }
  push(payload, callback) { this._proxy.push(payload, callback); }
}

class IPC {
  constructor(worklet) {
    const native = require('ti.barekit');
    if (isAndroid) {
      this._proxy = native.createIPC({ worklet: worklet._proxy });
    } else {
      this._proxy = native.createIPC(worklet._proxy);
    }
  }

  set readable(fn) {
    if (isAndroid) this._proxy.setReadable(fn);
    else this._proxy.readable = fn;
  }
  set writable(fn) {
    if (isAndroid) this._proxy.setWritable(fn);
    else this._proxy.writable = fn;
  }

  read(callback) {
    if (callback === undefined) return this._proxy.read();
    return this._proxy.read(callback);
  }

  write(data, callback) {
    if (callback === undefined) return this._proxy.write(data);
    return this._proxy.write(data, callback);
  }

  close() { this._proxy.close(); }
}

module.exports = { Worklet, IPC };