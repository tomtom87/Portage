import { describe, expect, it, vi } from "vitest";

vi.mock("openclaw/plugin-sdk/plugin-entry", () => ({ definePluginEntry: (e: unknown) => e }));

import { resolveConfig } from "../src/config.js";
import plugin from "../src/index.js";
import { FAKE, setup } from "./helpers.js";

describe("plugin entry", () => {
  it("registers every tool with a schema, and runs through the configured binary", async () => {
    const s = setup();
    const registered: { tool: any; opts: any }[] = [];
    (plugin as any).register({
      pluginConfig: { portageBin: FAKE, timeoutSeconds: 30 },
      registerTool: (tool: unknown, opts: unknown) => registered.push({ tool, opts }),
    });
    expect(registered).toHaveLength(13);
    for (const { tool, opts } of registered) {
      expect(tool.parameters.type).toBe("object");
      expect(opts).toEqual({ name: tool.name, optional: false });
      expect(tool.description.length).toBeGreaterThan(10);
    }
    const find = registered.find((r) => r.tool.name === "portage_find")!.tool;
    const res = await find.execute("call1", { query: "mug" });
    expect(res.details.ok).toBe(true);
    expect(s.calls()).toEqual([["find", "--query", "mug", "--json"]]);
  });
});

describe("config", () => {
  it("defaults and sanitises", () => {
    expect(resolveConfig(undefined)).toEqual({ portageBin: "portage", timeoutSeconds: 120 });
    expect(resolveConfig({ portageBin: "", timeoutSeconds: -3 })).toEqual({ portageBin: "portage", timeoutSeconds: 120 });
    expect(resolveConfig({ portageBin: "/x/portage", timeoutSeconds: 5 })).toEqual({ portageBin: "/x/portage", timeoutSeconds: 5 });
  });
});
