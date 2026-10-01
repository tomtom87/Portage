import { basename } from "node:path";
import type { OpenClawPluginApi } from "openclaw/plugin-sdk/plugin-entry";

/** Oldest portage-cli these tools are written against (`find --store` landed in 0.12.0). */
export const MIN_CLI_VERSION = "0.12.0";

/** The only executable names the runner will start, whatever directory portageBin points into. */
const ALLOWED_BIN_NAMES = new Set(["portage", "portage.exe"]);

/** True when portageBin names the portage executable (bare, or a path ending in it). */
export function isPortageBin(bin: string): boolean {
  return ALLOWED_BIN_NAMES.has(basename(bin.replace(/\\/g, "/")));
}

const MAX_BUFFER = 16 * 1024 * 1024;
const STDERR_TAIL = 500;

export type RunResult =
  | { ok: true; data: unknown; exitCode: number }
  | { ok: false; message: string };

export interface Runner {
  run(args: string[], opts?: { timeoutSeconds?: number }): Promise<RunResult>;
}

/** OpenClaw's subprocess helper for plugins, injected as api.runtime.system.runCommandWithTimeout. */
export type RunCommand = OpenClawPluginApi["runtime"]["system"]["runCommandWithTimeout"];

type ExecOutcome =
  | { result: Awaited<ReturnType<RunCommand>>; spawnError?: undefined }
  | { result?: undefined; spawnError: { code?: unknown; message?: unknown } };

async function exec(runCommand: RunCommand, bin: string, args: string[], timeoutMs: number): Promise<ExecOutcome> {
  try {
    // The plugin's only subprocess, started by OpenClaw's helper: an argument array, never a shell;
    // bin is always the portage CLI (see isPortageBin), bounded by a timeout and an output cap.
    // stdin is an empty pipe, never the gateway's terminal.
    const result = await runCommand([bin, ...args], {
      timeoutMs,
      input: "",
      maxOutputBytes: MAX_BUFFER,
      terminateOnOutputLimit: true,
    });
    return { result };
  } catch (error) {
    // The helper throws when the executable can't be started (missing, not executable).
    return { spawnError: (error ?? {}) as { code?: unknown; message?: unknown } };
  }
}

function tail(text: string): string {
  const t = text.trim();
  return t.length > STDERR_TAIL ? `...${t.slice(-STDERR_TAIL)}` : t;
}

export function parseVersion(text: string): [number, number, number] | null {
  const m = /(\d+)\.(\d+)\.(\d+)/.exec(text);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

export function versionAtLeast(have: [number, number, number], min: string): boolean {
  const want = parseVersion(min)!;
  for (let i = 0; i < 3; i++) {
    if (have[i]! !== want[i]!) return have[i]! > want[i]!;
  }
  return true;
}

function describeFailure(bin: string, o: ExecOutcome, timeoutMs: number): string | null {
  const e = o.spawnError;
  if (e) {
    if (e.code === "ENOENT") return `could not run "${bin}": not found. Install portage-cli (brew install tomtom87/portage/portage, or gem install portage-cli) or set portageBin in the plugin config.`;
    if (e.code === "EACCES") return `could not run "${bin}": permission denied`;
    return `could not run "${bin}": ${typeof e.code === "string" ? e.code : String(e.message ?? "unknown error")}`;
  }
  const r = o.result!;
  if (r.termination === "timeout" || r.termination === "no-output-timeout") {
    return `portage timed out after ${Math.round(timeoutMs / 1000)}s`;
  }
  // Hosts that can't stop the process at the cap still truncate what they capture; either way, fail.
  if (r.outputLimitExceeded || r.stdoutTruncatedBytes || r.stderrTruncatedBytes) {
    return `portage output exceeded the ${MAX_BUFFER / (1024 * 1024)} MB cap`;
  }
  return null; // non-zero exit: handled by the caller
}

export function createRunner(config: { portageBin: string; timeoutSeconds: number }, runCommand: RunCommand): Runner {
  const bin = config.portageBin;
  let versionCheck: Promise<string | null> | undefined;

  async function checkVersion(): Promise<string | null> {
    const o = await exec(runCommand, bin, ["--version"], Math.min(config.timeoutSeconds, 30) * 1000);
    const spawnFail = describeFailure(bin, o, Math.min(config.timeoutSeconds, 30) * 1000);
    if (spawnFail) return spawnFail;
    const v = parseVersion(o.result!.stdout);
    if (!v) return `could not read the portage version from "${bin} --version"; need portage-cli ${MIN_CLI_VERSION} or newer`;
    if (!versionAtLeast(v, MIN_CLI_VERSION)) {
      return `portage-cli ${v.join(".")} is too old; this plugin needs ${MIN_CLI_VERSION} or newer. Upgrade with: brew upgrade portage (or gem update portage-cli)`;
    }
    return null;
  }

  return {
    async run(args, opts) {
      // The plugin's one subprocess is the portage CLI: never start anything else, even if configured to.
      if (!isPortageBin(bin)) {
        return { ok: false, message: `refusing to run "${bin}": portageBin must name the portage executable (portage, or a path ending in /portage)` };
      }
      // Cache only a passing check, so installing/upgrading portage mid-session recovers.
      versionCheck ??= checkVersion();
      const problem = await versionCheck;
      if (problem) {
        versionCheck = undefined;
        return { ok: false, message: problem };
      }
      const timeoutMs = (opts?.timeoutSeconds ?? config.timeoutSeconds) * 1000;
      const o = await exec(runCommand, bin, args, timeoutMs);
      const failure = describeFailure(bin, o, timeoutMs);
      if (failure) return { ok: false, message: failure };
      const { stdout, stderr, code } = o.result!;
      const exitCode = code ?? 1; // null: killed by a signal
      let data: unknown;
      try {
        data = JSON.parse(stdout);
      } catch {
        const err = tail(stderr);
        return {
          ok: false,
          message: `portage ${args[0] ?? ""} exited ${exitCode} without valid JSON output${err ? `; stderr: ${err}` : ""}`,
        };
      }
      return { ok: true, data, exitCode };
    },
  };
}
