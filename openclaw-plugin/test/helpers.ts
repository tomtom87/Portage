import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRunner } from "../src/runner.js";

export const FAKE = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "bin", "portage");

export function setup(env: Record<string, string> = {}, timeoutSeconds = 20) {
  const dir = mkdtempSync(join(tmpdir(), "portage-fake-"));
  const log = join(dir, "argv.log");
  process.env.FAKE_PORTAGE_LOG = log;
  for (const k of ["FAKE_PORTAGE_MODE", "FAKE_PORTAGE_VERSION"]) delete process.env[k];
  Object.assign(process.env, env);
  const runner = createRunner({ portageBin: FAKE, timeoutSeconds });
  /** argv of every call except the cached --version probe. */
  const calls = () =>
    (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean) : [])
      .map((l) => JSON.parse(l) as string[])
      .filter((a) => a[0] !== "--version");
  const versionCalls = () =>
    (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean) : []).filter((l) =>
      l.includes("--version"),
    ).length;
  return { dir, runner, calls, versionCalls };
}
