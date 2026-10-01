import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
// @ts-expect-error plain .mjs build script
import { copySkills } from "../scripts/copy-skills.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("copy-skills", () => {
  it("copies buy and shop-research (with references) into the target, replaces stale copies, leaves portage-openclaw alone", () => {
    const target = mkdtempSync(join(tmpdir(), "portage-skills-"));
    mkdirSync(join(target, "portage-openclaw"));
    writeFileSync(join(target, "portage-openclaw", "SKILL.md"), "mine");
    mkdirSync(join(target, "buy"));
    writeFileSync(join(target, "buy", "stale.txt"), "old");

    expect(copySkills(target)).toEqual(["buy", "shop-research"]);

    for (const n of ["buy", "shop-research"]) {
      const copied = readFileSync(join(target, n, "SKILL.md"), "utf8");
      expect(copied).toBe(readFileSync(join(ROOT, "..", "plugins", "buy", "skills", n, "SKILL.md"), "utf8"));
    }
    expect(existsSync(join(target, "buy", "references", "outcomes.md"))).toBe(true);
    expect(existsSync(join(target, "buy", "stale.txt"))).toBe(false);
    expect(readFileSync(join(target, "portage-openclaw", "SKILL.md"), "utf8")).toBe("mine");
  });
});
