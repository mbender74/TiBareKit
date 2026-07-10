// Titanium build plugin: runs bare-pack to produce Resources/spike*.bundle
// + offloads native addon .bare prebuilds to Resources/node_modules/ before
// the Titanium compile step.
//
// --offload-addons writes .bare files as real files next to the bundle
// (Resources/node_modules/<pkg>/prebuilds/<host>/<addon>.bare) and records
// file: URLs in the bundle that resolve to those real paths at runtime.
// This is required because the Bare bundle protocol does not extract
// embedded addons to disk before dlopen -- the .bare must be a real file
// at a path the bundle can resolve. Without --offload-addons, the .bare is
// embedded in the bundle as a virtual path, dlopen fails, and the worklet
// aborts (SIGABRT).
//
// iOS: one host (ios-arm64-simulator), one bundle (Resources/spike.bundle).
// Android: all 4 ABIs -- bare-pack runs once per android host, producing
// Resources/spike-android-<host>.bundle for each. The plugin copies each
// host's .bare prebuilds from worklet/node_modules/<pkg>/prebuilds/<host>/
// to Resources/node_modules/<pkg>/prebuilds/<host>/ so every ABI's native
// addons ship in the APK. app.js picks the bundle matching the runtime ABI.
//
// Note on mechanism: SDK 14.0.0 loads project plugins via cli.scanHooks() on
// the plugin's hooks/ directory (see node-titanium-sdk/lib/titanium.js
// loadPlugins). hooks/tibarekit-spike.js re-exports this module's id/init so
// the loader picks it up. The package.json "type": "module" makes the .js
// files ESM, which is what scanHooks (await import()) expects in 14.0.0.
import { execSync } from 'node:child_process'
import { createRequire } from 'node:module'
import path from 'node:path'
import fs from 'node:fs'

export const id = 'tibarekit-spike'

// bare-bundle lives inside the globally-installed bare-pack package. Resolve
// it through createRequire pointed at bare-pack's bin so this plugin doesn't
// depend on the plugin's own node_modules layout.
const npmRootG = execSync('npm root -g').toString().trim()
const barePackRequire = createRequire(path.join(npmRootG, 'bare-pack', 'bin.js'))
const Bundle = barePackRequire('bare-bundle')

// The stock bare worklet (bare-kit shared/worklet.js:110) runs
// `unpack(bundle, { files: false, assets: true }, cb)` -- it extracts
// `bundle.assets` to the filesystem + rewrites their URLs to `file:`, but it
// does NOT touch `bundle.addons` (bare-unpack defaults `addons = files = false`
// when files:false and addons not explicit). So embedded `.bare` native
// addons registered as `bundle.addons` stay as virtual bundle paths and dlopen
// fails on Android (APK assets aren't on the filesystem; iOS dodges this via
// NSBundle + --offload-addons).
//
// Workaround: after bare-pack (which embeds the addon bytes under the same
// keys), move each addon key from `bundle.addons` into `bundle.assets`. The
// worklet's asset-unpack path then extracts the `.bare` bytes to the runtime
// `assets` dir and rewrites each binding.js `.` resolution to a `file:` URL
// pointing at the extracted file, which `Bare.Addon.load` can dlopen. No
// bare-kit rebuild or Java bundle parser needed.
function relocateAddonsToAssets(bundlePath) {
  const bundle = Bundle.from(fs.readFileSync(bundlePath))
  if (bundle.addons.length === 0) return
  bundle.assets = bundle.addons.slice()
  bundle.addons = []
  fs.writeFileSync(bundlePath, bundle.toBuffer())
}

// Map each android ABI to its bare-pack host + bundle name. All 4 ship in the
// APK; app.js selects the one matching the runtime ABI.
const ANDROID_TARGETS = [
  { host: 'android-arm64', bundle: 'spike-android-arm64.bundle' },
  { host: 'android-arm',   bundle: 'spike-android-arm.bundle' },
  { host: 'android-ia32',  bundle: 'spike-android-ia32.bundle' },
  { host: 'android-x64',   bundle: 'spike-android-x64.bundle' }
]

export function init(logger, config, cli) {
  cli.on('build.pre.compile', {
    priority: 900,
    async post() {
      const projectDir = cli.argv['project-dir']
      const workletDir = path.join(projectDir, 'worklet')
      const resourcesDir = path.join(projectDir, 'Resources')
      const platform = cli.argv.platform

      logger.info('tibarekit-spike: packing worklet bundle + offloading addons...')

      try {
        if (platform === 'android') {
          for (const t of ANDROID_TARGETS) {
            const bundlePath = path.join(resourcesDir, t.bundle)
            // Embed addons in the bundle (no --offload-addons). iOS can resolve
            // offloaded addon file: URLs through NSBundle, but Android's APK
            // assets are not on the filesystem, so dlopen on an offloaded path
            // fails. The stock bare worklet also does NOT extract embedded
            // `bundle.addons` to the filesystem (only `bundle.assets`), so
            // embedded addons alone would still leave dlopen pointing at a
            // virtual bundle path. relocateAddonsToAssets (below) moves the
            // addon keys into `bundle.assets`, after which the worklet's
            // asset-unpack path extracts the .bare bytes to the runtime
            // `assets` dir and rewrites each binding.js `.` resolution to a
            // file: URL Bare.Addon.load can dlopen. app.js passes that writable
            // `assets` dir (resolved from applicationDataDirectory via
            // Ti.File.nativePath, since applicationDataDirectory is the scheme
            // "appdata-private://" on Android, not a real filesystem path).
            execSync(
              `bare-pack --host ${t.host} --out "${bundlePath}" spike.js`,
              { stdio: 'inherit', cwd: workletDir }
            )
            if (!fs.existsSync(bundlePath)) {
              throw new Error('bare-pack did not produce ' + t.bundle)
            }
            relocateAddonsToAssets(bundlePath)
            logger.info('tibarekit-spike: ' + t.bundle + ' ready (host ' + t.host + ')')
          }
        } else {
          // iOS branch: single host, single bundle (unchanged from the original
          // spike plugin).
          const host = 'ios-arm64-simulator'
          const bundlePath = path.join(resourcesDir, 'spike.bundle')
          execSync(
            `bare-pack --host ${host} --offload-addons --out "${bundlePath}" spike.js`,
            { stdio: 'inherit', cwd: workletDir }
          )
          if (!fs.existsSync(bundlePath)) {
            throw new Error('bare-pack did not produce spike.bundle')
          }
          logger.info('tibarekit-spike: bundle ready at ' + bundlePath)
        }
      } catch (err) {
        logger.error('tibarekit-spike: ' + err.message)
        throw err
      }
    }
  })
}
