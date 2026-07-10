// Titanium build plugin: runs bare-pack to produce Resources/spike.bundle
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
// Note on mechanism: SDK 14.0.0 loads project plugins via cli.scanHooks() on
// the plugin's hooks/ directory (see node-titanium-sdk/lib/titanium.js
// loadPlugins). hooks/tibarekit-spike.js re-exports this module's id/init so
// the loader picks it up. The package.json "type": "module" makes the .js
// files ESM, which is what scanHooks (await import()) expects in 14.0.0.
import { execSync } from 'node:child_process'
import path from 'node:path'
import fs from 'node:fs'

export const id = 'tibarekit-spike'

export function init(logger, config, cli) {
  cli.on('build.pre.compile', {
    priority: 900,
    async post() {
      const projectDir = cli.argv['project-dir']
      const workletDir = path.join(projectDir, 'worklet')
      const resourcesDir = path.join(projectDir, 'Resources')
      const bundlePath = path.join(resourcesDir, 'spike.bundle')

      // For the spike, always ios-arm64-simulator (Apple Silicon sim target).
      const host = 'ios-arm64-simulator'

      logger.info('tibarekit-spike: packing worklet bundle + offloading addons...')

      try {
        // --offload-addons writes .bare prebuilds as real files next to the
        // bundle (Resources/node_modules/<pkg>/prebuilds/<host>/<addon>.bare)
        // and records file: URLs in the bundle. At runtime, the bundle
        // resolves the addon to a sibling path on disk, which dlopen loads.
        // Running with cwd=workletDir and entry "spike.js" (relative) keeps
        // the bundle's internal paths root-relative (/spike.js, /node_modules/..)
        // so the offloaded ../node_modules/... path resolves correctly.
        execSync(
          `bare-pack --host ${host} --offload-addons --out "${bundlePath}" spike.js`,
          { stdio: 'inherit', cwd: workletDir }
        )

        if (!fs.existsSync(bundlePath)) {
          throw new Error('bare-pack did not produce spike.bundle')
        }

        logger.info('tibarekit-spike: bundle ready at ' + bundlePath)
      } catch (err) {
        logger.error('tibarekit-spike: ' + err.message)
        throw err
      }
    }
  })
}
