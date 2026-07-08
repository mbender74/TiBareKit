// Hook adapter: scanHooks() loads files from the plugin's hooks/ directory.
// The real logic lives in ../plugin.js (kept there per the task brief's file
// list). This file re-exports id + init so the Titanium CLI hook loader
// discovers and invokes it.
export { id, init } from '../plugin.js'