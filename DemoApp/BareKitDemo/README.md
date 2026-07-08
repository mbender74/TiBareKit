# BareKitDemo

A standalone Titanium app that demonstrates the `ti.barekit` module
(`Worklet` + `IPC` wrapping the holepunchto/bare-kit runtime).

## What it does

On launch it:

1. Creates a `Worklet` with a 24 MB memory limit.
2. Attaches an `IPC` channel to it.
3. Starts the worklet with an inline source that:
   - logs `hello from the worklet`,
   - echoes any data it receives over IPC (`echo: <data>`),
   - handles push messages by replying `pong: <payload>`,
   - reports uncaught exceptions over IPC.
4. From the main side it:
   - installs `readable`/`writable` polling callbacks,
   - does an async `write` + `read` round-trip,
   - sends a `push` and prints the worklet's reply,
   - suspends at 2 s, resumes at 4 s, terminates at 6 s.

Output is mirrored into an on-screen text area as well as the console
(`Ti.API.info` / logcat).

## Prerequisites

- Titanium SDK 14.0.0 (set as `<sdk-version>` in `tiapp.xml`).
- The `ti.barekit` module built and installed. Build it first from the
  module root:

  ```bash
  cd /Users/marcbender/Titanium-Modules/TiBareKit
  ti build -p ios --build-only      # -> ios/dist/ti.barekit-iphone-1.0.0.zip
  ti build -p android --build-only  # -> android/dist/ti.barekit-android-1.0.0.zip
  ```

  Install the module so this app can find it. Either copy the zip into
  the global Titanium modules dir:

  ```bash
  cp ios/dist/ti.barekit-iphone-1.0.0.zip   ~/Library/Application\ Support/Titanium/
  cp android/dist/ti.barekit-android-1.0.0.zip  ~/.titanium/   # Linux; same path on macOS works too
  ```

  ...or drop the zip into this app's root directory and `ti build` will
  extract it automatically.

## Run

```bash
cd DemoApp/BareKitDemo
ti build -p ios       # simulator
ti build -p android   # emulator / device
```

Watch the console for `[BareKitDemo]` lines; the on-screen text area
mirrors the same log.

## Notes

- Native callbacks deliver a single result dict (`{reply}` / `{data}` /
  `{error}` / `{}`) — not `(value, err)` pairs. The demo's callbacks
  unpack that dict.
- The worklet source is inline JS passed as the `source` argument to
  `worklet.start(filename, source, arguments)`. For a bundled app, pass
  `null` as `source` and a `.bundle` filename — see the module README.