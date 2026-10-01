import { execFile } from "node:child_process";

/** Oldest portage-cli these tools are written against (`find --store` landed in 0.12.0). */
export const MIN_CLI_VERSION = "0.12.0";

const MAX_BUFFER = 16 * 1024 * 1024;
const STDERR_TAIL = 500;

export type RunResult =
  | { ok: true; data: unknown; exitCode: number }
  | { ok: false; message: string };

export interface Runner {
  run(args: string[], opts?: { timeoutSeconds?: number }): Promise<RunResult>;
}

interface ExecOutcome {
  error: (NodeJS.ErrnoException & { killed?: boolean; signal?: string | null; code?: unknown }) | null;
  stdout: string;
  stderr: string;
}

function exec(bin: string, args: string[], timeoutMs: number): Promise<ExecOutcome> {
  return new Promise((resolve) => {
    // execFile with an argument array: no shell, no interpolation.
    execFile(
      bin,
      args,
      { timeout: timeoutMs, maxBuffer: MAX_BUFFER, encoding: "utf8", shell: false, windowsHide: true },
      (error, stdout, stderr) => resolve({ error: error as ExecOutcome["error"], stdout: String(stdout ?? ""), stderr: String(stderr ?? "") }),
    );
  });
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
  const e = o.error;
  if (!e) return null;
  if (e.killed || e.signal === "SIGTERM") {
    return `portage timed out after ${Math.round(timeoutMs / 1000)}s`;
  }
  if (typeof e.code === "string") {
    if (e.code === "ENOENT") return `could not run "${bin}": not found. Install portage-cli (brew install tomtom87/portage/portage, or gem install portage-cli) or set portageBin in the plugin config.`;
    if (e.code === "EACCES") return `could not run "${bin}": permission denied`;
    return `could not run "${bin}": ${e.code}`;
  }
  return null; // non-zero exit: handled by the caller
}

export function createRunner(config: { portageBin: string; timeoutSeconds: number }): Runner {
  const bin = config.portageBin;
  let versionCheck: Promise<string | null> | undefined;

  async function checkVersion(): Promise<string | null> {
    const o = await exec(bin, ["--version"], Math.min(config.timeoutSeconds, 30) * 1000);
    const spawnFail = describeFailure(bin, o, Math.min(config.timeoutSeconds, 30) * 1000);
    if (spawnFail) return spawnFail;
    const v = parseVersion(o.stdout);
    if (!v) return `could not read the portage version from "${bin} --version"; need portage-cli ${MIN_CLI_VERSION} or newer`;
    if (!versionAtLeast(v, MIN_CLI_VERSION)) {
      return `portage-cli ${v.join(".")} is too old; this plugin needs ${MIN_CLI_VERSION} or newer. Upgrade with: brew upgrade portage (or gem update portage-cli)`;
    }
    return null;
  }

  return {
    async run(args, opts) {
      // Cache only a passing check, so installing/upgrading portage mid-session recovers.
      versionCheck ??= checkVersion();
      const problem = await versionCheck;
      if (problem) {
        versionCheck = undefined;
        return { ok: false, message: problem };
      }
      const timeoutMs = (opts?.timeoutSeconds ?? config.timeoutSeconds) * 1000;
      const o = await exec(bin, args, timeoutMs);
      const failure = describeFailure(bin, o, timeoutMs);
      if (failure) return { ok: false, message: failure };
      const exitCode = o.error ? (typeof o.error.code === "number" ? o.error.code : 1) : 0;
      let data: unknown;
      try {
        data = JSON.parse(o.stdout);
      } catch {
        const err = tail(o.stderr);
        return {
          ok: false,
          message: `portage ${args[0] ?? ""} exited ${exitCode} without valid JSON output${err ? `; stderr: ${err}` : ""}`,
        };
      }
      return { ok: true, data, exitCode };
    },
  };
}
