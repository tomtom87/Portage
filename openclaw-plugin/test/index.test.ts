import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it, vi } from "vitest";

vi.mock("openclaw/plugin-sdk/plugin-entry", () => ({ definePluginEntry: (e: unknown) => e }));

import { resolveConfig } from "../src/config.js";
import plugin from "../src/index.js";
import { allTools } from "../src/tools/index.js";
import { FAKE, runCommandWithTimeout, setup } from "./helpers.js";

describe("plugin entry", () => {
  it("registers every tool with a schema, and runs through the configured binary", async () => {
    const s = setup();
    const registered: { tool: any; opts: any }[] = [];
    (plugin as any).register({
      pluginConfig: { portageBin: FAKE, timeoutSeconds: 30 },
      registerTool: (tool: unknown, opts: unknown) => registered.push({ tool, opts }),
      runtime: { system: { runCommandWithTimeout } },
    });
    expect(registered).toHaveLength(23);
    const optional = new Set([
      "portage_pick", "portage_dry_run", "portage_approve", "portage_buy_quote", "portage_handoff",
      "portage_index_add", "portage_index_remove", "portage_index_build", "portage_index_refresh",
      "portage_browser_import",
    ]);
    for (const { tool, opts } of registered) {
      expect(tool.parameters.type).toBe("object");
      expect(opts).toEqual({ name: tool.name, optional: optional.has(tool.name) });
      expect(tool.description.length).toBeGreaterThan(10);
    }
    expect(registered.filter((r) => r.opts.optional)).toHaveLength(10);
    expect(registered.filter((r) => !r.opts.optional)).toHaveLength(13);
    const find = registered.find((r) => r.tool.name === "portage_find")!.tool;
    const res = await find.execute("call1", { query: "mug" });
    expect(res.details.ok).toBe(true);
    expect(registered.find((r) => r.tool.name === "portage_find")!.tool.outputSchema).toBeDefined();
    expect(s.calls()).toEqual([["find", "--query", "mug", "--json"]]);
  });
});

describe("manifest", () => {
  it("lists every registered tool in contracts.tools, and marks exactly the optional ones in toolMetadata", () => {
    const manifest = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "openclaw.plugin.json"), "utf8"));
    expect([...manifest.contracts.tools].sort()).toEqual(allTools.map((t) => t.name).sort());
    const flagged = Object.entries(manifest.toolMetadata as Record<string, { optional?: boolean }>)
      .filter(([, m]) => m.optional === true)
      .map(([n]) => n);
    expect(flagged.sort()).toEqual(allTools.filter((t) => t.optional).map((t) => t.name).sort());
    expect(Object.keys(manifest.toolMetadata).sort()).toEqual(flagged.sort());
  });

  it("marks sideEffecting in the manifest exactly where the code does, and only on optional tools", () => {
    const manifest = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "openclaw.plugin.json"), "utf8"));
    const flagged = Object.entries(manifest.toolMetadata as Record<string, { sideEffecting?: boolean }>)
      .filter(([, m]) => m.sideEffecting === true)
      .map(([n]) => n);
    expect(flagged.sort()).toEqual(allTools.filter((t) => t.sideEffecting).map((t) => t.name).sort());
    expect(allTools.filter((t) => t.sideEffecting && !t.optional)).toEqual([]);
    expect(flagged).toHaveLength(10);
  });

  it("declares the skills directory, which holds the bundled and hand-written skills", () => {
    const root = join(dirname(fileURLToPath(import.meta.url)), "..");
    const manifest = JSON.parse(readFileSync(join(root, "openclaw.plugin.json"), "utf8"));
    expect(manifest.skills).toEqual(["skills"]);
    expect(readFileSync(join(root, "skills", "portage-openclaw", "SKILL.md"), "utf8")).toMatch(/^name: portage-openclaw$/m);
  });
});

describe("config", () => {
  it("defaults and sanitises", () => {
    expect(resolveConfig(undefined)).toEqual({ portageBin: "portage", timeoutSeconds: 120 });
    expect(resolveConfig({ portageBin: "", timeoutSeconds: -3 })).toEqual({ portageBin: "portage", timeoutSeconds: 120 });
    expect(resolveConfig({ portageBin: "/x/portage", timeoutSeconds: 5 })).toEqual({ portageBin: "/x/portage", timeoutSeconds: 5 });
  });
});
