import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
// @ts-expect-error plain .mjs build script
import { copySkills, NO_CLI_SECTION, replaceNoCliSection } from "../scripts/copy-skills.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("copy-skills", () => {
  it("copies buy and shop-research (with references) into the target, replaces stale copies, leaves portage-openclaw alone", () => {
    const target = mkdtempSync(join(tmpdir(), "portage-skills-"));
    mkdirSync(join(target, "portage-openclaw"));
    writeFileSync(join(target, "portage-openclaw", "SKILL.md"), "mine");
    mkdirSync(join(target, "buy"));
    writeFileSync(join(target, "buy", "stale.txt"), "old");

    expect(copySkills(target)).toEqual(["buy", "shop-research"]);

    const source = (n: string) => readFileSync(join(ROOT, "..", "plugins", "buy", "skills", n, "SKILL.md"), "utf8");
    expect(readFileSync(join(target, "shop-research", "SKILL.md"), "utf8")).toBe(source("shop-research"));
    expect(readFileSync(join(target, "buy", "SKILL.md"), "utf8")).toBe(replaceNoCliSection(source("buy")));
    expect(existsSync(join(target, "buy", "references", "outcomes.md"))).toBe(true);
    expect(existsSync(join(target, "buy", "stale.txt"))).toBe(false);
    expect(readFileSync(join(target, "portage-openclaw", "SKILL.md"), "utf8")).toBe("mine");
  });

  it("ships no direct-checkout fallback and points the buy skill back at the tools", () => {
    const target = mkdtempSync(join(tmpdir(), "portage-skills-"));
    copySkills(target);

    expect(existsSync(join(target, "buy", "references", "raw-ucp.md"))).toBe(false);
    const buy = readFileSync(join(target, "buy", "SKILL.md"), "utf8");
    expect(buy).toContain(NO_CLI_SECTION);
    expect(buy.trimEnd().endsWith(NO_CLI_SECTION.trimEnd())).toBe(true);
    for (const n of ["buy", "shop-research"]) {
      for (const file of readdirSync(join(target, n), { recursive: true, encoding: "utf8" })) {
        if (!file.endsWith(".md")) continue;
        const text = readFileSync(join(target, n, file), "utf8");
        expect(text, `${n}/${file}`).not.toMatch(/raw-ucp|complete_checkout|over MCP by hand/);
      }
    }
  });

  it("finds no direct-checkout fallback in the source skills either", () => {
    const source = join(ROOT, "..", "plugins", "buy", "skills");
    for (const file of readdirSync(source, { recursive: true, encoding: "utf8" })) {
      if (!file.endsWith(".md")) continue;
      expect(readFileSync(join(source, file), "utf8"), file).not.toMatch(/raw-ucp|complete_checkout|over MCP by hand/);
    }
  });

  it("keeps any section after the replaced one, and fails loudly if the section is gone", () => {
    const skill = "# Buy\n\n## 6. No CLI available\n\nraw fallback\n\n## 7. Later\n\nkept\n";
    expect(replaceNoCliSection(skill)).toBe(`# Buy\n\n${NO_CLI_SECTION}\n## 7. Later\n\nkept\n`);
    expect(() => replaceNoCliSection("# Buy\n")).toThrow(/No CLI available/);
  });
});
