#!/usr/bin/env node
// Copies the repo's buy and shop-research skills into the plugin's skills/ directory (build output,
// gitignored). The hand-written skills/portage-openclaw is never touched.
import { cpSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const BUNDLED = ["buy", "shop-research"];

const here = dirname(fileURLToPath(import.meta.url));

/** Copies each bundled skill to `<target>/<name>`, replacing any stale copy. Returns the names copied. */
export function copySkills(target = join(here, "..", "skills"), source = join(here, "..", "..", "plugins", "buy", "skills")) {
  mkdirSync(target, { recursive: true });
  for (const name of BUNDLED) {
    const from = join(source, name);
    if (!existsSync(join(from, "SKILL.md"))) throw new Error(`skill not found: ${from}`);
    const to = join(target, name);
    rmSync(to, { recursive: true, force: true });
    cpSync(from, to, { recursive: true });
  }
  return BUNDLED;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const names = copySkills(process.argv[2] ? resolve(process.argv[2]) : undefined);
  console.log(`copied skills: ${names.join(", ")}`);
}
