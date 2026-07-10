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
import path from 'node:path'
import fs from 'node:fs'

export const id = 'tibarekit-spike'

// Map each android ABI to its bare-pack host + bundle name. All 4 ship in the
// APK; app.js selects the one matching the runtime ABI.
const ANDROID_TARGETS = [
  { host: 'android-arm64', bundle: 'spike-android-arm64.bundle' },
  { host: 'android-arm',   bundle: 'spike-android-arm.bundle' },
  { host: 'android-ia32',  bundle: 'spike-android-ia32.bundle' },
  { host: 'android-x64',   bundle: 'spike-android-x64.bundle' }
]

// Copy every <pkg>/prebuilds/<host>/*.bare from the worklet node_modules into
// Resources/node_modules/<pkg>/prebuilds/<host>/ so the offloaded file: URLs
// in the bundle resolve to real files in the APK assets.
function copyPrebuilds(workletDir, resourcesDir, host) {
  const nmSrc = path.join(workletDir, 'node_modules')
  const nmDst = path.join(resourcesDir, 'node_modules')
  if (!fs.existsSync(nmSrc)) return
  for (const pkg of fs.readdirSync(nmSrc)) {
    const pbSrc = path.join(nmSrc, pkg, 'prebuilds', host)
    if (!fs.existsSync(pbSrc)) continue
    const pbDst = path.join(nmDst, pkg, 'prebuilds', host)
    fs.mkdirSync(pbDst, { recursive: true })
    for (const f of fs.readdirSync(pbSrc)) {
      if (!f.endsWith('.bare')) continue
      fs.copyFileSync(path.join(pbSrc, f), path.join(pbDst, f))
    }
  }
}

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
            execSync(
              `bare-pack --host ${t.host} --offload-addons --out "${bundlePath}" spike.js`,
              { stdio: 'inherit', cwd: workletDir }
            )
            if (!fs.existsSync(bundlePath)) {
              throw new Error('bare-pack did not produce ' + t.bundle)
            }
            copyPrebuilds(workletDir, resourcesDir, t.host)
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