# TiBareKit Module

## Description

TiBareKit is a Titanium SDK module that wraps the [holepunchto/bare-kit](https://github.com/holepunchto/bare-kit) runtime for iOS and Android. It exposes Bare -- a small, fast JavaScript runtime from Holepunch -- to Titanium applications as a first-class module, so a Titanium app can run JavaScript code in an isolated worklet process and exchange messages with it over an IPC channel.

The module ships two JavaScript classes from `require('ti.barekit')`:

- `Worklet` -- owns a Bare runtime process. You give it source (or a pre-bundled `.bundle` file) and it runs that source in the Bare runtime.
- `IPC` -- an in-process bidirectional channel between the Titanium host and a `Worklet`, with both synchronous polling and asynchronous read/write.

The native runtime binaries (the BareKit framework on iOS, the `libbare-kit.so` slices and `bare-kit.jar` on Android) are prebuilt and checked in to this repository; the module does not require CMake or the NDK on the app developer's machine. All native-to-JS callbacks are dispatched on the platform main thread.

## Installation

Build the module (`ti build -p [ios|android] --build-only`) and register it in your application's `tiapp.xml`:

```xml
<modules>
  <module version="1.0.0">ti.barekit</module>
</modules>
```

The module version is `1.0.0` and the Titanium SDK pin is `14.0.0` (set in `ios/titanium.xcconfig` and `android/manifest` as `minsdk: 14.0.0`).

## Accessing the Module

The module is a CommonJS module. Either form works:

```js
// CommonJS
const { Worklet, IPC } = require('ti.barekit');

// ES module syntax ( Titanium supports `import` from `ti.barekit`)
import { Worklet, IPC } from 'ti.barekit';
```

## API Reference

### class Worklet

A `Worklet` owns a Bare runtime process. Construct one, then call `start()` to run source or a bundle file, and use `suspend()`, `resume()`, and `terminate()` to control its lifecycle.

#### `new Worklet(options?)`

Constructs a worklet. `options` is an optional object with the following fields:

| Field        | Type    | Default  | Description                                                                 |
|--------------|---------|----------|-----------------------------------------------------------------------------|
| `memoryLimit`| Number  | (unset)  | Maximum heap size for the Bare runtime, in bytes.                           |
| `assets`     | Boolean | `false`  | Enables the asset-bundling path so a `.bundle` worklet can read assets.    |

Both fields are optional. Omit the argument entirely to use defaults:

```js
const worklet = new Worklet();
const worklet = new Worklet({ memoryLimit: 24 * 1024 * 1024 });  // 24 MB heap
const worklet = new Worklet({ assets: true });
```

#### `worklet.start(filename, source?, arguments?)`

Starts the Bare runtime and loads code into it. Returns nothing; call `push()` or use `IPC` to talk to the worklet once it is running.

| Parameter    | Type             | Default | Description                                                                                          |
|--------------|------------------|---------|------------------------------------------------------------------------------------------------------|
| `filename`   | String           | --     | Filename passed to the Bare runtime. Conventionally `/app.js` for inline source, or `/app.bundle` for bundle mode. |
| `source`     | String \| `null` | `null`  | Inline JavaScript source string, or `null` to load the `.bundle` file named by `filename`.         |
| `arguments`  | Array            | `[]`    | Array of string arguments passed to the worklet (accessible inside the worklet as `process.argv`-style globals). |

Inline source mode -- the source string is handed to the Bare runtime directly:

```js
const source = [
  "BareKit.IPC.on('data', (data) => {",
  "  BareKit.IPC.write('echo: ' + data.toString());",
  "});"
].join('\n');

worklet.start('/app.js', source, ['--flag', 'value']);
```

Bundle loader mode -- pass `null` as the `source` argument and a `.bundle` filename. The `.bundle` file must have been produced by the Bare bundler (`bare-make` upstream). Use the `assets: true` option at construction if the bundle needs to read bundled assets:

```js
const worklet = new Worklet({ assets: true });
worklet.start('/app.bundle', null, []);
```

#### `worklet.suspend(linger?)`

Suspends the worklet. The optional `linger` argument is a number of milliseconds the worklet is allowed to keep running before it is suspended; if omitted, the worklet is suspended immediately.

```js
worklet.suspend();          // suspend now
worklet.suspend(500);       // give the worklet up to 500 ms to settle, then suspend
```

#### `worklet.resume()`

Resumes a suspended worklet.

```js
worklet.resume();
```

#### `worklet.terminate()`

Terminates the worklet and releases the Bare runtime. The worklet object cannot be restarted after this; construct a new `Worklet` if you need another one.

```js
worklet.terminate();
```

#### `worklet.push(payload, callback)`

Sends a push message to the worklet. The worklet receives it through the `BareKit.on('push', (payload, reply) => { ... })` handler (see "Worklet-side globals" below). The callback is invoked once, on the platform main thread, with a single result dict (see "Callback contract" below).

| Parameter  | Type             | Description                                       |
|------------|------------------|---------------------------------------------------|
| `payload`  | String \| Ti.Blob| The message to push to the worklet.               |
| `callback`| Function         | Receives one result dict.                          |

Callback result shapes:

```js
worklet.push('check', (result) => {
  if (result.error) return Ti.API.error('push err: ' + result.error);
  if (result.reply) Ti.API.info('reply: ' + result.reply.toString());
  // result === {} means the worklet replied with no payload
});
```

### class IPC

An `IPC` instance is a bidirectional channel between the Titanium host and a running `Worklet`. Create it from a worklet, wire up `readable` and `writable`, then use `read()` and `write()` to exchange bytes.

#### `new IPC(worklet)`

Wraps the worklet's IPC channel. Pass the `Worklet` instance (not the native proxy):

```js
const worklet = new Worklet();
const ipc = new IPC(worklet);
```

#### `ipc.readable = (fn) => {}` (setter)

Sets a callback that fires when data arrives from the worklet -- i.e., when the worklet has called `BareKit.IPC.write(...)`. The callback takes no arguments; in response you typically call `ipc.read()` to pull the data.

```js
ipc.readable = () => {
  const blob = ipc.read();
  if (blob) Ti.API.info('worklet said: ' + blob.toString());
};
```

#### `ipc.writable = (fn) => {}` (setter)

Sets a callback that fires when the IPC channel is ready to accept a write. **Only call `ipc.write(...)` inside this callback (or after it has fired).** See "Write-before-writable crash" below.

```js
let writableFired = false;
ipc.writable = () => {
  if (writableFired) return;
  writableFired = true;
  ipc.write('ping from main');
};
```

#### `ipc.read()` -- synchronous polling read

With no argument, `read()` returns a `Ti.Blob` if data is available, or `null` if the channel is empty. This is the form to call from inside the `readable` callback.

```js
ipc.readable = () => {
  let blob;
  while ((blob = ipc.read())) {
    Ti.API.info('worklet: ' + blob.toString());
  }
};
```

#### `ipc.read(callback)` -- asynchronous read

With a callback argument, `read()` performs an asynchronous read. The callback is invoked once, on the platform main thread, with a single result dict:

```js
ipc.read((result) => {
  if (result.error) return Ti.API.error('read err: ' + result.error);
  if (result.data) Ti.API.info('worklet: ' + result.data.toString());
});
```

| Callback field | Type     | Description                                            |
|----------------|----------|--------------------------------------------------------|
| `result.data`  | Ti.Blob  | Present when data was read.                           |
| `result.error` | String   | Present when the read failed.                          |
| (empty)        | `{}`     | Channel closed / end-of-stream with no pending data.   |

#### `ipc.write(data)` -- synchronous write

Writes `data` (a String or Ti.Blob) to the channel. Strings are UTF-8-encoded on the bridge. Returns nothing. **Call this only after `ipc.writable` has fired** (see "Write-before-writable crash" below).

```js
ipc.writable = () => {
  ipc.write('hello from main');
};
```

#### `ipc.write(data, callback)` -- asynchronous write

Writes `data` and invokes `callback` on the platform main thread when the write completes. The callback receives a single result dict:

```js
ipc.writable = () => {
  ipc.write('async hello', (result) => {
    if (result.error) return Ti.API.error('write err: ' + result.error);
    // success -- result is {} (no fields)
  });
};
```

| Callback field | Type    | Description                              |
|----------------|---------|------------------------------------------|
| `result.error` | String  | Present when the write failed.           |
| (empty)        | `{}`    | Success -- no fields in the result dict.  |

#### `ipc.close()`

Closes the IPC channel. The worklet itself is not terminated; call `worklet.terminate()` for that.

```js
ipc.close();
```

## Configuration

### `memoryLimit`

`new Worklet({ memoryLimit: <bytes> })` caps the Bare runtime heap. The value is a byte count; use `n * 1024 * 1024` for megabytes. If omitted, the runtime uses its default.

```js
const worklet = new Worklet({ memoryLimit: 24 * 1024 * 1024 });  // 24 MB
```

### `assets`

`new Worklet({ assets: true })` enables the asset-bundling path. This is needed when the worklet loads a `.bundle` file that embeds assets (the upstream `bare-make` asset pipeline). Leave it `false` for inline-source worklets.

## Bundle loader mode

A worklet can run either inline source or a pre-bundled `.bundle` file. Bundle mode is selected by passing `null` as the `source` argument to `start()` and giving `filename` a `.bundle` path:

```js
const worklet = new Worklet({ assets: true });
worklet.start('/app.bundle', null, ['--flag']);
```

The `.bundle` file is produced upstream by `bare-make` and contains serialized modules and (optionally) assets. When `assets: true` is set at construction, the worklet can read bundled assets through the Bare runtime's asset API.

## Worklet-side globals

Inside the `source` string (or `.bundle`), the code runs in the Bare runtime with these globals available in addition to the standard JavaScript built-ins:

### `Bare`

The Bare runtime itself. Use `Bare.on('uncaughtException', ...)` to install a handler for otherwise-uncaught exceptions inside the worklet (see "uncaughtException behavior" below).

### `BareKit`

An `EventEmitter` on the worklet side. The main-side `worklet.push(...)` calls are delivered as `'push'` events here. The handler signature is `(payload, reply)`, where `reply(err, buffer, encoding?)` sends a reply back to the main side:

```js
BareKit.on('push', (payload, reply) => {
  const text = payload.toString();
  reply(null, Buffer.from('pong: ' + text));
});
```

Pass an `err` string as the first argument to report an error to the main side (it arrives in `result.error`).

### `BareKit.IPC`

The worklet's side of the IPC channel. `BareKit.IPC.write(data)` sends data to the main side; `BareKit.IPC.on('data', (data) => { ... })` receives data written by the main side:

```js
BareKit.IPC.on('data', (data) => {
  BareKit.IPC.write('echo: ' + data.toString());
});
```

## uncaughtException behavior

By default, an uncaught exception inside the worklet aborts the Bare runtime. Override this with `Bare.on('uncaughtException', ...)` to report the error to the host instead of aborting:

```js
Bare.on('uncaughtException', (err) => {
  // The host no longer aborts. Report the error to the host (for example over
  // Bare.IPC) and exit or recover as appropriate.
  console.error(err)
})
```

In a TiBareKit worklet, replace `console.error(err)` with `BareKit.IPC.write(...)` to surface the error on the main side, where the Titanium app can log or display it:

```js
Bare.on('uncaughtException', (err) => {
  BareKit.IPC.write('FATAL: ' + err.message);
});
```

## Callback contract (single result dict)

ALL native-to-JS callbacks in TiBareKit -- push replies, async reads, and async writes -- deliver a SINGLE result dict to the callback. There is no `(value, err)` two-argument form. The dict has at most one of these fields set:

| Callback  | Success                          | Error                 | Empty                |
|-----------|----------------------------------|-----------------------|----------------------|
| `push`    | `{ reply: Ti.Blob }`              | `{ error: String }`   | `{}`                 |
| `read`    | `{ data: Ti.Blob }`               | `{ error: String }`   | `{}`                 |
| `write`   | `{}`                             | `{ error: String }`   | --                   |

The correct pattern in every case is: check `result.error` first, then check for the success field (`result.reply`, `result.data`), and treat `{}` as "no data / no reply":

```js
worklet.push('check', (result) => {
  if (result.error) return Ti.API.error('push err: ' + result.error);
  if (result.reply) Ti.API.info('reply: ' + result.reply.toString());
});

ipc.write('hello', (result) => {
  if (result.error) return Ti.API.error('write err: ' + result.error);
  ipc.read((r) => {
    if (r.error) return Ti.API.error('read err: ' + r.error);
    if (r.data) Ti.API.info('reply: ' + r.data.toString());
  });
});
```

## Write-before-writable crash (important)

Calling `ipc.write(...)` BEFORE the `ipc.writable` callback has fired causes an integer-overflow crash in BareKit's `write:completion:` path on iOS (`NSMakeRange(negative, length-negative)` underflows). The same constraint applies on Android -- the channel is not ready until `writable` fires.

The rule: **only call `ipc.write(...)` inside the `ipc.writable` callback (or after it has fired)**. Use a one-shot guard flag so you do not have to null the setter:

```js
let writableFired = false;
ipc.writable = () => {
  if (writableFired) return;
  writableFired = true;
  ipc.write('ping from main');
};
```

The synchronous `ipc.write(data)` form and the asynchronous `ipc.write(data, callback)` form are both subject to this constraint.

## Usage example

A complete working example is in `DemoApp/BareKitDemo/Resources/app.js`. The structure below adapts that demo: it constructs a worklet, wires up `readable` / `writable`, does an async write+read round trip, sends a `push`, and drives the lifecycle.

```js
const { Worklet, IPC } = require('ti.barekit');

// Source runs inside the Bare runtime. Globals: Bare, BareKit, BareKit.IPC.
const workletSource = [
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

// Polling read: fires when the worklet writes to IPC.
ipc.readable = () => {
  let blob;
  while ((blob = ipc.read())) {
    Ti.API.info('[polling] worklet: ' + blob.toString());
  }
};

// Writable: ONLY write inside this callback. Guard with a flag so the
// setter stays one-shot without nulling it (which would pass nil/NSNull
// to the native callback setter and is fragile).
let writableFired = false;
ipc.writable = () => {
  if (writableFired) return;
  writableFired = true;

  // Sync write.
  ipc.write('ping from main (polling)');

  // Async write + async read round trip.
  ipc.write('async hello', (result) => {
    if (result.error) return Ti.API.error('write err: ' + result.error);
    ipc.read((r) => {
      if (r.error) return Ti.API.error('read err: ' + r.error);
      if (r.data) Ti.API.info('[async] worklet: ' + r.data.toString());
    });
  });
};

// Push: 'check' -> worklet replies 'pong: check'.
worklet.push('check', (result) => {
  if (result.error) return Ti.API.error('push err: ' + result.error);
  if (result.reply) Ti.API.info('[push] reply: ' + result.reply.toString());
});

// Lifecycle: suspend at 2s, resume at 4s, terminate at 6s.
setTimeout(() => worklet.suspend(),   2000);
setTimeout(() => worklet.resume(),    4000);
setTimeout(() => worklet.terminate(), 6000);
```

## Notes

- **Worklet `console.log` does not go to `Ti.API`.** Inside the worklet source, `console.log` routes to the Bare / OS logger, not to the Titanium log. To surface worklet output in `Ti.API`, write it over `BareKit.IPC` and log it from the main-side `readable` callback.
- **All native-to-JS callbacks are dispatched on the platform main thread.** You can safely touch Titanium UI from inside `push` / `read` / `write` callbacks.
- **Data types.** The IPC `read` / `write` / `push` APIs use `Ti.Blob` for binary data. Strings are accepted on the bridge and are UTF-8-encoded when crossing into native code.
- **No CMake or NDK on the app path.** Native binaries are prebuilt and checked in to the module; building the module only requires the Titanium SDK toolchain.

## License

See `LICENSE` in the module root.