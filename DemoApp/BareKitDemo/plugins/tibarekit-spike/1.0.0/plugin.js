// Titanium build plugin: runs bare-pack to produce Resources/spike.bundle
// before the Titanium compile step. Task 1's version has no native prebuilds
// to copy; later tasks extend the copy step.
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
      // If the sim is x86_64, the implementer adjusts --host (determined in Step 8).
      const host = 'ios-arm64-simulator'

      logger.info('tibarekit-spike: packing worklet bundle...')

      try {
        // Run bare-pack. --host ios-arm64-simulator is the 2.x CLI form
        // (replaces the older --platform/--arch/--simulator flags).
        execSync(
          `bare-pack --host ${host} --out "${bundlePath}" "${path.join(workletDir, 'spike.js')}"`,
          { stdio: 'inherit', cwd: workletDir }
        )

        if (!fs.existsSync(bundlePath)) {
          throw new Error('bare-pack did not produce spike.bundle')
        }

        // Copy native addon prebuilds into Resources/prebuilds/<platform-arch>/.
        // The Bare runtime's require-addon resolves .bare files from here at
        // runtime. Walks all node_modules with ios-arm64-simulator prebuilds
        // so Task 3's additional native deps are picked up automatically.
        const prebuildsDir = path.join(resourcesDir, 'prebuilds', host)
        fs.mkdirSync(prebuildsDir, { recursive: true })

        const nodeModulesDir = path.join(workletDir, 'node_modules')
        if (fs.existsSync(nodeModulesDir)) {
          for (const modName of fs.readdirSync(nodeModulesDir)) {
            const modPrebuilds = path.join(nodeModulesDir, modName, 'prebuilds', host)
            if (!fs.existsSync(modPrebuilds)) continue
            for (const file of fs.readdirSync(modPrebuilds)) {
              if (file.endsWith('.bare')) {
                fs.copyFileSync(path.join(modPrebuilds, file), path.join(prebuildsDir, file))
                logger.info('tibarekit-spike: copied ' + modName + '/' + file)
              }
            }
          }
        }

        logger.info('tibarekit-spike: bundle ready at ' + bundlePath)
      } catch (err) {
        logger.error('tibarekit-spike: ' + err.message)
        throw err
      }
    }
  })
}