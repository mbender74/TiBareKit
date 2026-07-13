#!/usr/bin/env bash
# scripts/scaffold-barekit-plugin.sh -- scaffold a TiBareKit build plugin into
# a Titanium app so `ti build` runs bare-pack on the app's worklet source.
#
# The demo app (DemoApp/BareKitDemo) ships with plugins/tibarekit-spike/1.0.0/
# checked in. New apps do not -- this script copies that plugin into a target
# app, parameterized for the app's worklet entry name, and optionally seeds a
# starter worklet/ directory.
#
# What the plugin does at build.pre.compile:
#   iOS      -> bare-pack --offload-addons -> Resources/<name>.bundle
#   Android  -> bare-pack x4 (one per ABI) -> Resources/<name>-android-<abi>.bundle
#              + relocateAddonsToAssets post-process so the stock worklet
#              extracts embedded .bare addons to the runtime assets dir.
#
# Usage:
#   scripts/scaffold-barekit-plugin.sh --app-dir /path/to/app [options]
#
# Options:
#   --app-dir PATH       Titanium app root (contains tiapp.xml) (required)
#   --name NAME          Worklet entry + bundle prefix (default: app)
#                        -> worklet/<name>.js, Resources/<name>.bundle,
#                           Resources/<name>-android-<abi>.bundle
#   --plugin-name ID     Plugin id used in tiapp.xml + logs (default: tibarekit)
#   --version VER        Plugin version dir (default: 1.0.0)
#   --with-worklet       Also seed worklet/<name>.js + worklet/package.json
#                        (skipped if worklet/ already exists)
#   -h, --help           show this help
#
# After running, add these lines to the app's tiapp.xml (the script prints a
# ready-to-paste snippet):
#   <modules>
#     <module version="1.0.0">ti.barekit</module>
#   </modules>
#   <plugins>
#     <plugin><plugin-name></plugin>
#   </plugins>
#
# Prereqs (checked at start):
#   - Node.js + npm
#   - bare-pack on PATH (npm install --global bare-pack) -- only needed at
#     `ti build` time, not at scaffold time
#
# Then in the app:
#   cd <app-dir>/worklet && npm install
#   ti build -p [ios|android]
set -euo pipefail

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
info()  { printf '\033[1m[scaffold]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[scaffold]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[scaffold]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1${2:+ ($2)}"
}

# ---------------------------------------------------------------------------
# defaults + arg parsing
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_DIR=""
NAME="app"
PLUGIN_NAME="tibarekit"
VERSION="1.0.0"
WITH_WORKLET=0

show_help() {
  awk 'NR==1{next} /^set -euo pipefail$/{exit} {sub(/^# ?/,""); print}' "$0"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app-dir)       APP_DIR="$2"; shift 2;;
    --name)          NAME="$2"; shift 2;;
    --plugin-name)   PLUGIN_NAME="$2"; shift 2;;
    --version)       VERSION="$2"; shift 2;;
    --with-worklet)  WITH_WORKLET=1; shift;;
    -h|--help)       show_help;;
    *) die "unknown arg: $1 (try --help)";;
  esac
done

[ -n "$APP_DIR" ] || die "--app-dir <path> is required (try --help)"
[ -d "$APP_DIR" ] || die "--app-dir path does not exist: $APP_DIR"
[ -f "$APP_DIR/tiapp.xml" ] || die "--app-dir is not a Titanium app root (no tiapp.xml): $APP_DIR"
APP_DIR="$(cd "$APP_DIR" && pwd)"

# Validate name + plugin-name (used as JS identifiers + filenames).
case "$NAME" in
  *[!a-zA-Z0-9_-]*) die "--name must match [a-zA-Z0-9_-] (got: $NAME)";;
esac
case "$PLUGIN_NAME" in
  *[!a-zA-Z0-9_-]*) die "--plugin-name must match [a-zA-Z0-9_-] (got: $PLUGIN_NAME)";;
esac

require_cmd node "required for bare-pack at build time"
require_cmd npm "required for worklet npm install"

PLUGIN_DIR="$APP_DIR/plugins/$PLUGIN_NAME/$VERSION"
HOOKS_DIR="$PLUGIN_DIR/hooks"

info "app:         $APP_DIR"
info "name:        $NAME (worklet/$NAME.js, Resources/$NAME.bundle, Resources/$NAME-android-<abi>.bundle)"
info "plugin id:   $PLUGIN_NAME"
info "version:     $VERSION"
info "plugin dir:  $PLUGIN_DIR"

# ---------------------------------------------------------------------------
# write the plugin files
# ---------------------------------------------------------------------------
[ -d "$PLUGIN_DIR" ] && die "plugin dir already exists: $PLUGIN_DIR (remove it first or pick a different --plugin-name / --version)"
mkdir -p "$HOOKS_DIR"

# package.json
cat > "$PLUGIN_DIR/package.json" <<EOF
{
  "name": "$PLUGIN_NAME",
  "version": "$VERSION",
  "main": "plugin.js",
  "type": "module"
}
EOF

# hooks/<plugin-name>.js -- re-exports id + init from ../plugin.js so the
# Titanium CLI hook loader (cli.scanHooks on hooks/) discovers it.
cat > "$HOOKS_DIR/$PLUGIN_NAME.js" <<EOF
// Hook adapter: scanHooks() loads files from the plugin's hooks/ directory.
// The real logic lives in ../plugin.js. This file re-exports id + init so
// the Titanium CLI hook loader discovers and invokes it.
export { id, init } from '../plugin.js'
EOF

# plugin.js -- parameterized from DemoApp/BareKitDemo/plugins/tibarekit-spike/1.0.0/plugin.js
# with: spike -> $NAME, tibarekit-spike -> $PLUGIN_NAME
cat > "$PLUGIN_DIR/plugin.js" <<EOF
// Titanium build plugin: runs bare-pack to produce Resources/$NAME*.bundle
// + relocates native addon .bare prebuilds so the stock bare worklet can
// extract them at runtime (before the Titanium compile step).
//
// Addon resolution differs by platform:
//
// iOS: one host (ios-arm64-simulator), one bundle (Resources/$NAME.bundle).
// bare-pack runs with --offload-addons, which writes each .bare as a real
// file next to the bundle (Resources/node_modules/<pkg>/prebuilds/<host>/
// <addon>.bare) and records file: URLs in the bundle. iOS resolves those
// file: URLs through NSBundle at runtime so dlopen sees a real file. This
// is required on iOS because the Bare bundle protocol does not extract
// embedded addons to disk before dlopen -- the .bare must be a real file at
// a path the bundle can resolve. Without --offload-addons, the .bare is
// embedded in the bundle as a virtual path, dlopen fails, and the worklet
// aborts (SIGABRT).
//
// Android: all 4 ABIs -- bare-pack runs once per android host (no
// --offload-addons), producing Resources/$NAME-android-<host>.bundle for
// each. Android's APK assets are not on the filesystem, so dlopen on an
// offloaded path fails; instead the addons are embedded in the bundle and
// relocateAddonsToAssets() (below) moves their keys from bundle.addons into
// bundle.assets (concat, not replace). The stock bare worklet only
// extracts bundle.assets to the filesystem (not bundle.addons), so this
// relocation makes the worklet extract the .bare bytes to the runtime
// assets dir and rewrite each binding.js \`.\` resolution to a file: URL
// Bare.Addon.load can dlopen. app.js passes that writable assets dir
// (resolved from applicationDataDirectory) and picks the bundle matching
// the runtime ABI.
//
// Note on mechanism: SDK 14.0.0 loads project plugins via cli.scanHooks() on
// the plugin's hooks/ directory (see node-titanium-sdk/lib/titanium.js
// loadPlugins). hooks/$PLUGIN_NAME.js re-exports this module's id/init so
// the loader picks it up. The package.json "type": "module" makes the .js
// files ESM, which is what scanHooks (await import()) expects in 14.0.0.
import { execSync } from 'node:child_process'
import { createRequire } from 'node:module'
import path from 'node:path'
import fs from 'node:fs'

export const id = '$PLUGIN_NAME'

// The stock bare worklet (bare-kit shared/worklet.js:110) runs
// \`unpack(bundle, { files: false, assets: true }, cb)\` -- it extracts
// \`bundle.assets\` to the filesystem + rewrites their URLs to \`file:\`, but it
// does NOT touch \`bundle.addons\` (bare-unpack defaults \`addons = files = false\`
// when files:false and addons not explicit). So embedded \`.bare\` native
// addons registered as \`bundle.addons\` stay as virtual bundle paths and dlopen
// fails on Android (APK assets aren't on the filesystem; iOS dodges this via
// NSBundle + --offload-addons).
//
// Workaround: after bare-pack (which embeds the addon bytes under the same
// keys), move each addon key from \`bundle.addons\` into \`bundle.assets\`. The
// worklet's asset-unpack path then extracts the \`.bare\` bytes to the runtime
// \`assets\` dir and rewrites each binding.js \`.\` resolution to a \`file:\` URL
// pointing at the extracted file, which \`Bare.Addon.load\` can dlopen. No
// bare-kit rebuild or Java bundle parser needed.
//
// bare-bundle is resolved lazily (inside this function) so iOS builds -- which
// never call relocateAddonsToAssets -- do not pay the \`npm root -g\` +
// createRequire cost or depend on bare-bundle being resolvable from global
// bare-pack. bare-bundle lives inside the globally-installed bare-pack
// package; resolve it through createRequire pointed at bare-pack's bin so
// this plugin doesn't depend on the plugin's own node_modules layout.
function relocateAddonsToAssets(bundlePath) {
  const npmRootG = execSync('npm root -g').toString().trim()
  const barePackRequire = createRequire(path.join(npmRootG, 'bare-pack', 'bin.js'))
  const Bundle = barePackRequire('bare-bundle')
  const bundle = Bundle.from(fs.readFileSync(bundlePath))
  if (bundle.addons.length === 0) return
  // Concat into bundle.assets rather than replacing it. A future bundle may
  // have both native addons AND non-addon assets; a replace would silently
  // drop the non-addon assets.
  bundle.assets = [...bundle.assets, ...bundle.addons]
  bundle.addons = []
  fs.writeFileSync(bundlePath, bundle.toBuffer())
}

// Map each android ABI to its bare-pack host + bundle name. All 4 ship in the
// APK; app.js selects the one matching the runtime ABI.
const ANDROID_TARGETS = [
  { host: 'android-arm64', bundle: '$NAME-android-arm64.bundle' },
  { host: 'android-arm',   bundle: '$NAME-android-arm.bundle' },
  { host: 'android-ia32',  bundle: '$NAME-android-ia32.bundle' },
  { host: 'android-x64',   bundle: '$NAME-android-x64.bundle' }
]

export function init(logger, config, cli) {
  cli.on('build.pre.compile', {
    priority: 900,
    async post() {
      const projectDir = cli.argv['project-dir']
      const workletDir = path.join(projectDir, 'worklet')
      const resourcesDir = path.join(projectDir, 'Resources')
      const platform = cli.argv.platform

      logger.info('$PLUGIN_NAME: packing worklet bundle + offloading addons...')

      try {
        if (platform === 'android') {
          for (const t of ANDROID_TARGETS) {
            const bundlePath = path.join(resourcesDir, t.bundle)
            // Embed addons in the bundle (no --offload-addons). iOS can resolve
            // offloaded addon file: URLs through NSBundle, but Android's APK
            // assets are not on the filesystem, so dlopen on an offloaded path
            // fails. The stock bare worklet also does NOT extract embedded
            // \`bundle.addons\` to the filesystem (only \`bundle.assets\`), so
            // embedded addons alone would still leave dlopen pointing at a
            // virtual bundle path. relocateAddonsToAssets (below) moves the
            // addon keys into \`bundle.assets\`, after which the worklet's
            // asset-unpack path extracts the .bare bytes to the runtime
            // \`assets\` dir and rewrites each binding.js \`.\` resolution to a
            // file: URL Bare.Addon.load can dlopen. app.js passes that writable
            // \`assets\` dir (resolved from applicationDataDirectory via
            // Ti.File.nativePath, since applicationDataDirectory is the scheme
            // "appdata-private://" on Android, not a real filesystem path).
            execSync(
              \`bare-pack --host \${t.host} --out "\${bundlePath}" $NAME.js\`,
              { stdio: 'inherit', cwd: workletDir }
            )
            if (!fs.existsSync(bundlePath)) {
              throw new Error('bare-pack did not produce ' + t.bundle)
            }
            relocateAddonsToAssets(bundlePath)
            logger.info('$PLUGIN_NAME: ' + t.bundle + ' ready (host ' + t.host + ')')
          }
        } else {
          // iOS branch: single host, single bundle.
          const host = 'ios-arm64-simulator'
          const bundlePath = path.join(resourcesDir, '$NAME.bundle')
          execSync(
            \`bare-pack --host \${host} --offload-addons --out "\${bundlePath}" $NAME.js\`,
            { stdio: 'inherit', cwd: workletDir }
          )
          if (!fs.existsSync(bundlePath)) {
            throw new Error('bare-pack did not produce $NAME.bundle')
          }
          logger.info('$PLUGIN_NAME: bundle ready at ' + bundlePath)
        }
      } catch (err) {
        logger.error('$PLUGIN_NAME: ' + err.message)
        throw err
      }
    }
  })
}
EOF

info "wrote: $PLUGIN_DIR/{plugin.js, package.json, hooks/$PLUGIN_NAME.js}"

# ---------------------------------------------------------------------------
# optionally seed worklet/ starter
# ---------------------------------------------------------------------------
if [ "$WITH_WORKLET" = 1 ] && [ ! -d "$APP_DIR/worklet" ]; then
  mkdir -p "$APP_DIR/worklet"
  cat > "$APP_DIR/worklet/package.json" <<EOF
{
  "name": "$NAME-worklet",
  "version": "1.0.0",
  "private": true,
  "type": "commonjs",
  "dependencies": {
    "sodium-native": "^4.1.1",
    "hyperswarm": "^4.17.0",
    "framed-stream": "^1.0.1"
  }
}
EOF
  cat > "$APP_DIR/worklet/$NAME.js" <<EOF
// Bare worklet entry. Runs in an isolated thread with its own heap + libuv
// loop. Talk to the Titanium host over BareKit.IPC.
const BareKit = require('bare-kit')

BareKit.IPC.on('data', (d) => {
  BareKit.IPC.write('echo: ' + d.toString())
})
EOF
  info "seeded: $APP_DIR/worklet/{$NAME.js, package.json}"
  info "next: cd $APP_DIR/worklet && npm install"
elif [ "$WITH_WORKLET" = 1 ]; then
  warn "worklet/ already exists -- left untouched (remove --with-worklet to skip this warning)"
elif [ ! -d "$APP_DIR/worklet" ]; then
  warn "no worklet/ in $APP_DIR -- create it (or re-run with --with-worklet) before 'ti build'"
fi

# ---------------------------------------------------------------------------
# print the tiapp.xml snippet
# ---------------------------------------------------------------------------
info "add this to $APP_DIR/tiapp.xml:"
cat <<EOF

  <modules>
    <module version="1.0.0">ti.barekit</module>
  </modules>

  <plugins>
    <plugin>$PLUGIN_NAME</plugin>
  </plugins>

EOF

info "done. then: cd $APP_DIR && ti build -p [ios|android]"