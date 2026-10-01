// openclaw/plugin-sdk/process-runtime ships without types. Its runCommandWithTimeout is the helper
// OpenClaw injects into plugins as api.runtime.system.runCommandWithTimeout, so the tests run the
// runner against the real thing.
declare module "openclaw/plugin-sdk/process-runtime" {
  export const runCommandWithTimeout: import("../src/runner.js").RunCommand;
}
