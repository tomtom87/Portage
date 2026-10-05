#!/usr/bin/env node
// Copies the repo's buy and shop-research skills into the plugin's skills/ directory (build output,
// gitignored). The hand-written skills/portage-openclaw is never touched.
//
// The buy skill's "No CLI available" section tells the agent to install `portage` and stop. In
// OpenClaw every step goes through the plugin's portage_* tools, so the copy swaps that section for
// one that names them.
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const BUNDLED = ["buy", "shop-research"];

const NO_CLI_HEADING = "## 6. No CLI available";

export const NO_CLI_SECTION = `${NO_CLI_HEADING}

In OpenClaw every step goes through the \`portage_*\` tools, which need the \`portage\` CLI. If \`portage\` isn't installed or \`portage_doctor\` fails, tell the user to install or upgrade it (\`brew install tomtom87/portage/portage\` or \`gem install portage-cli\`) and stop. Never drive a store's UCP or MCP endpoint, cart, checkout or payment yourself, with a shell, a web fetch or a browser: that skips Portage's spending policy, approval and checkout-mismatch checks.
`;

const here = dirname(fileURLToPath(import.meta.url));

/** Swaps the buy skill's "No CLI available" section for NO_CLI_SECTION. Throws if the section moved. */
export function replaceNoCliSection(skill) {
  const start = skill.indexOf(NO_CLI_HEADING);
  if (start === -1) throw new Error(`buy/SKILL.md: "${NO_CLI_HEADING}" not found; update scripts/copy-skills.mjs`);
  const next = skill.indexOf("\n## ", start + NO_CLI_HEADING.length);
  const rest = next === -1 ? "" : skill.slice(next + 1);
  return `${skill.slice(0, start)}${NO_CLI_SECTION}${rest ? `\n${rest}` : ""}`;
}

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
  const buy = join(target, "buy", "SKILL.md");
  writeFileSync(buy, replaceNoCliSection(readFileSync(buy, "utf8")));
  return BUNDLED;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const names = copySkills(process.argv[2] ? resolve(process.argv[2]) : undefined);
  console.log(`copied skills: ${names.join(", ")}`);
}
