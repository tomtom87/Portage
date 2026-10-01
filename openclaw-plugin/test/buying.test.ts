import { describe, expect, it } from "vitest";
import { runTool } from "../src/execute.js";
import { allTools } from "../src/tools/index.js";
import { setup } from "./helpers.js";

const tool = (n: string) => allTools.find((t) => t.name === n)!;
const args = (n: string, p: Record<string, unknown> = {}) => tool(n).buildArgs(p);

describe("buying tool argument building", () => {
  it("portage_pick", () => {
    expect(args("portage_pick")).toEqual(["pick", "--json"]);
    expect(args("portage_pick", { search: "se_1a2b3c4d", choose: "of_1a2b3c" })).toEqual(
      ["pick", "--search", "se_1a2b3c4d", "--choose", "of_1a2b3c", "--json"],
    );
    expect(args("portage_pick", { compare: "of_1a2b3c" })).toEqual(["pick", "--compare", "of_1a2b3c", "--json"]);
    expect(args("portage_pick", { view: "of_1a2b3c" })).toEqual(["pick", "--view", "of_1a2b3c", "--json"]);
    expect(() => args("portage_pick", { choose: "a", view: "b" })).toThrow(/at most one/);
    expect(() => args("portage_pick", { choose: "two words" })).toThrow(/identifier/);
  });

  it("portage_dry_run by offer or by store", () => {
    expect(args("portage_dry_run", { offer: "of_1a2b3c" })).toEqual(["buy", "--offer", "of_1a2b3c", "--dry-run", "--json"]);
    expect(args("portage_dry_run", { offer: "of_1a2b3c", qty: 2 })).toEqual(
      ["buy", "--offer", "of_1a2b3c", "--qty", "2", "--dry-run", "--json"],
    );
    expect(args("portage_dry_run", { store: "https://shop.example", query: "cold brew", product_id: "42", qty: 3 })).toEqual(
      ["buy", "https://shop.example", "--query", "cold brew", "--product-id", "42", "--qty", "3", "--dry-run", "--json"],
    );
    expect(() => args("portage_dry_run")).toThrow(/either offer/);
    expect(() => args("portage_dry_run", { offer: "of_1", store: "https://s.example", query: "q", product_id: "1" })).toThrow(/not both/);
    expect(() => args("portage_dry_run", { store: "https://s.example", query: "q" })).toThrow(/together/);
    expect(() => args("portage_dry_run", { offer: "of_1", qty: 0 })).toThrow(/positive/);
    expect(() => args("portage_dry_run", { store: "ftp://s.example", query: "q", product_id: "1" })).toThrow(/http/);
  });

  it("portage_approve", () => {
    expect(args("portage_approve", { quote_id: "qt_0123456789ab" })).toEqual(["approve", "qt_0123456789ab", "--json"]);
    expect(args("portage_approve", { quote_id: "qt_0123456789ab", relayed_yes: false })).toEqual(["approve", "qt_0123456789ab", "--json"]);
    expect(args("portage_approve", { quote_id: "qt_0123456789ab", relayed_yes: true })).toEqual(
      ["approve", "qt_0123456789ab", "--relayed-yes", "--json"],
    );
    expect(args("portage_approve", { quote_id: "qt_0123456789ab", view: true })).toEqual(["approve", "qt_0123456789ab", "--view", "--json"]);
    expect(() => args("portage_approve", { quote_id: "qt_0123456789ab", relayed_yes: true, view: true })).toThrow();
    for (const bad of ["true", "yes", 1, null, {}, []]) {
      expect(() => args("portage_approve", { quote_id: "qt_0123456789ab", relayed_yes: bad })).toThrow(/true or false/);
    }
  });

  it("portage_buy_quote is the one buy --quote --yes", () => {
    expect(args("portage_buy_quote", { quote_id: "qt_0123456789ab" })).toEqual(["buy", "--quote", "qt_0123456789ab", "--yes", "--json"]);
    expect(() => args("portage_buy_quote", {})).toThrow();
    expect(() => args("portage_buy_quote", { quote_id: "--yes" })).toThrow();
  });

  it("portage_handoff", () => {
    expect(args("portage_handoff", { offer: "of_1a2b3c" })).toEqual(["buy", "--offer", "of_1a2b3c", "--json"]);
    expect(args("portage_handoff", { offer: "of_1a2b3c", target: "profile", qty: 2 })).toEqual(
      ["buy", "--offer", "of_1a2b3c", "--qty", "2", "--handoff-target", "profile", "--json"],
    );
    expect(args("portage_handoff", { store: "https://s.example", query: "mug", product_id: "9", target: "print", wait: true, wait_timeout: "45m" })).toEqual(
      ["buy", "https://s.example", "--query", "mug", "--product-id", "9", "--handoff-target", "print", "--wait", "--wait-timeout", "45m", "--json"],
    );
    expect(() => args("portage_handoff", { offer: "of_1", target: "agent:evil" })).toThrow(/one of/);
    expect(() => args("portage_handoff", { offer: "of_1", wait_timeout: "5m" })).toThrow(/needs wait/);
    expect(() => args("portage_handoff", { offer: "of_1", wait: true, wait_timeout: "forever" })).toThrow(/45s/);
    expect(() => args("portage_handoff", { offer: "of_1", wait: true, wait_timeout: "off" })).toThrow();
  });

  it("portage_handoff gets a long timeout only for --wait", () => {
    const t = tool("portage_handoff");
    expect(t.timeoutFor?.({ offer: "of_1" })).toBeUndefined();
    expect(t.timeoutFor?.({ offer: "of_1", wait: true })).toBe(1860);
    expect(t.timeoutFor?.({ offer: "of_1", wait: true, wait_timeout: "2h" })).toBe(7260);
    expect(t.timeoutFor?.({ offer: "of_1", wait: true, wait_timeout: "90s" })).toBe(150);
  });
});

describe("index mutation and import argument building", () => {
  it("portage_index_add / remove", () => {
    expect(args("portage_index_add", { url: "https://shop.example" })).toEqual(["index", "add", "https://shop.example", "--json"]);
    expect(args("portage_index_add", { url: "https://shop.example", crawl: true })).toEqual(
      ["index", "add", "https://shop.example", "--crawl", "--json"],
    );
    expect(args("portage_index_remove", { host: "shop.example" })).toEqual(["index", "remove", "shop.example", "--json"]);
    expect(() => args("portage_index_remove", { host: "https://shop.example/x" })).toThrow(/host name/);
    expect(() => args("portage_index_add", { url: "file:///etc/passwd" })).toThrow();
  });

  it("portage_index_build / refresh, with the long timeout", () => {
    expect(args("portage_index_build")).toEqual(["index", "build", "--json"]);
    expect(args("portage_index_build", { sources: ["stores_file", "browser"], dry_run: true })).toEqual(
      ["index", "build", "--sources", "stores_file,browser", "--dry-run", "--json"],
    );
    expect(args("portage_index_refresh", { sources: ["wikidata"] })).toEqual(["index", "refresh", "--sources", "wikidata", "--json"]);
    expect(tool("portage_index_build").timeoutSeconds).toBe(1800);
    expect(tool("portage_index_refresh").timeoutSeconds).toBe(1800);
    expect(() => args("portage_index_build", { sources: [] })).toThrow();
    expect(() => args("portage_index_build", { sources: ["a,b"] })).toThrow();
    expect(() => args("portage_index_build", { sources: "wikidata" })).toThrow(/array/);
    expect(() => args("portage_index_build", { sources: ["/etc/passwd"] })).toThrow();
  });

  it("portage_browser_import previews by default and saves only with confirm: true", () => {
    expect(args("portage_browser_import")).toEqual(["browser", "import", "--dry-run", "--json"]);
    expect(args("portage_browser_import", { browser: "chrome", history_days: 30, include_product_pages: true, max_probes: 50, exclude: ["a.example", "b.example"] })).toEqual(
      ["browser", "import", "--browser", "chrome", "--history-days", "30", "--include-product-pages", "--max-probes", "50", "--exclude", "a.example,b.example", "--dry-run", "--json"],
    );
    expect(args("portage_browser_import", { confirm: true, exclude: ["a.example"] })).toEqual(
      ["browser", "import", "--exclude", "a.example", "--yes", "--json"],
    );
    expect(args("portage_browser_import", { confirm: false })).toContain("--dry-run");
    expect(() => args("portage_browser_import", { confirm: "true" })).toThrow(/true or false/);
    expect(() => args("portage_browser_import", { browser: "netscape" })).toThrow();
  });
});

describe("runTool timeouts", () => {
  it("passes a per-call timeout through to the runner", async () => {
    const s = setup({ FAKE_PORTAGE_MODE: "hang" }, 20);
    const spec = { ...tool("portage_pick"), timeoutFor: () => 1 };
    const r = await runTool(s.runner, spec, {});
    expect(r.details).toMatchObject({ error: expect.stringMatching(/timed out after 1s/) });
  });
});
