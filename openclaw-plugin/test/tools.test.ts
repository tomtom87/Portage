import { describe, expect, it } from "vitest";
import { runTool } from "../src/execute.js";
import { allTools } from "../src/tools/index.js";
import { setup } from "./helpers.js";

const tool = (n: string) => allTools.find((t) => t.name === n)!;
const args = (n: string, p: Record<string, unknown> = {}) => tool(n).buildArgs(p);

describe("argument building", () => {
  it("covers exactly the phase 1 tools, none optional", () => {
    expect(allTools.map((t) => t.name).sort()).toEqual(
      [
        "portage_doctor", "portage_find", "portage_find_store", "portage_check", "portage_compare",
        "portage_index_search", "portage_index_show", "portage_index_sources", "portage_history",
        "portage_orders_reconcile", "portage_policy_show", "portage_payment_list", "portage_browser_profile_status",
      ].sort(),
    );
    expect(allTools.every((t) => !t.optional)).toBe(true);
  });

  it("builds each command", () => {
    expect(args("portage_doctor")).toEqual(["doctor", "--json"]);
    expect(args("portage_find", { query: "red mug", max_price: 20, limit: 5 })).toEqual(
      ["find", "--query", "red mug", "--max-price", "20", "--limit", "5", "--json"],
    );
    expect(args("portage_find_store", { store: "https://shop.example", query: "mug", max_price: 9.5 })).toEqual(
      ["find", "--store", "https://shop.example", "--query", "mug", "--max-price", "9.5", "--json"],
    );
    expect(args("portage_check", { url: "https://shop.example" })).toEqual(["check", "https://shop.example", "--json"]);
    expect(args("portage_compare", { url: "http://s.example/p", product_id: "42", ids: ["a", "b"], results: 3 })).toEqual(
      ["compare", "http://s.example/p", "--product-id", "42", "--id", "a", "--id", "b", "--results", "3", "--json"],
    );
    expect(args("portage_index_search", { query: "lamp", category: "home", store: "x.com", limit: 4 })).toEqual(
      ["index", "search", "lamp", "--category", "home", "--store", "x.com", "--limit", "4", "--json"],
    );
    expect(args("portage_index_show")).toEqual(["index", "show", "--json"]);
    expect(args("portage_index_show", { view: "products", page: 2, per_page: 10 })).toEqual(
      ["index", "show", "--products", "--page", "2", "--per-page", "10", "--json"],
    );
    expect(args("portage_index_show", { view: "stores" })).toEqual(["index", "show", "--stores", "--json"]);
    expect(args("portage_index_sources")).toEqual(["index", "sources", "--json"]);
    expect(args("portage_history")).toEqual(["history", "list", "--json"]);
    expect(args("portage_history", { kind: "purchases", limit: 3 })).toEqual(["history", "list", "--purchases", "--limit", "3", "--json"]);
    expect(args("portage_orders_reconcile", { checkout: "c_1" })).toEqual(["orders", "reconcile", "--checkout", "c_1", "--json"]);
    expect(args("portage_policy_show")).toEqual(["policy", "show", "--json"]);
    expect(args("portage_payment_list")).toEqual(["payment", "list", "--json"]);
    expect(args("portage_browser_profile_status")).toEqual(["browser", "profile", "status", "--json"]);
  });

  it("rejects invalid values", () => {
    expect(() => args("portage_find", { query: "" })).toThrow();
    expect(() => args("portage_find", { query: "x", limit: 0 })).toThrow(/positive/);
    expect(() => args("portage_find", { query: "x", limit: 1.5 })).toThrow();
    expect(() => args("portage_find", { query: "x", max_price: -1 })).toThrow();
    expect(() => args("portage_find", { query: "x", max_price: "5" })).toThrow();
    expect(() => args("portage_find", { query: 5 })).toThrow();
    expect(() => args("portage_find_store", { store: "ftp://x.com", query: "a" })).toThrow(/http/);
    expect(() => args("portage_find_store", { store: "file:///etc/passwd", query: "a" })).toThrow();
    expect(() => args("portage_find_store", { store: "javascript:alert(1)", query: "a" })).toThrow();
    expect(() => args("portage_check", { url: "not a url" })).toThrow();
    expect(() => args("portage_index_show", { view: "products", page: -2 })).toThrow();
    expect(() => args("portage_index_show", { page: 1 })).toThrow(/products/);
    expect(() => args("portage_index_show", { view: "all" })).toThrow();
    expect(() => args("portage_history", { kind: "everything" })).toThrow();
    expect(() => args("portage_compare", { url: "https://s.example", product_id: "1", ids: "a" })).toThrow();
  });
});

describe("flag injection", () => {
  const flagish = ["--yes", "-y", "--relayed-yes", "--payment-token=abc", "--proxy", "-"];
  const stringParams: [string, string][] = [
    ["portage_find", "query"],
    ["portage_find_store", "query"],
    ["portage_compare", "product_id"],
    ["portage_index_search", "query"],
    ["portage_index_search", "category"],
    ["portage_index_search", "store"],
    ["portage_orders_reconcile", "checkout"],
  ];
  const base: Record<string, Record<string, unknown>> = {
    portage_find: { query: "q" },
    portage_find_store: { store: "https://s.example", query: "q" },
    portage_compare: { url: "https://s.example", product_id: "1" },
    portage_index_search: { query: "q" },
    portage_orders_reconcile: {},
    portage_check: { url: "https://s.example" },
  };

  for (const [name, param] of stringParams) {
    for (const bad of flagish) {
      it(`${name}.${param} rejects ${JSON.stringify(bad)}`, () => {
        expect(() => args(name, { ...base[name], [param]: bad })).toThrow(/must not start with "-"/);
      });
    }
    it(`${name}.${param} tolerates leading whitespace trick`, () => {
      expect(() => args(name, { ...base[name], [param]: "  --yes" })).toThrow();
    });
  }

  it("rejects flag-shaped compare ids", () => {
    expect(() => args("portage_compare", { url: "https://s.example", product_id: "1", ids: ["ok", "--yes"] })).toThrow();
  });

  it("a flag-like substring inside free text stays one argv element", () => {
    const a = args("portage_find", { query: "mug --yes --limit 1" });
    expect(a).toEqual(["find", "--query", "mug --yes --limit 1", "--json"]);
  });

  it("no tool can emit buying or credential flags for benign input", () => {
    const forbidden = ["--yes", "--relayed-yes", "--payment-token", "--via", "--decision-backend", "--min-confidence", "--proxy"];
    for (const t of allTools) {
      const a = t.buildArgs(base[t.name] ?? {});
      for (const f of forbidden) expect(a).not.toContain(f);
      expect(["policy", "payment", "history", "browser", "index", "orders", "doctor", "find", "check", "compare"]).toContain(a[0]);
      if (a[0] === "policy") expect(a[1]).toBe("show");
      if (a[0] === "payment") expect(a[1]).toBe("list");
      if (a[0] === "history") expect(a[1]).toBe("list");
      if (a[0] === "browser") expect(a.slice(1, 3)).toEqual(["profile", "status"]);
    }
  });
});

describe("runTool results", () => {
  it("returns content text and details from parsed JSON", async () => {
    const s = setup();
    const r = await runTool(s.runner, tool("portage_find"), { query: "mug" });
    expect(r.details).toMatchObject({ ok: true });
    expect(JSON.parse(r.content[0]!.text)).toEqual(r.details);
    expect(s.calls()).toEqual([["find", "--query", "mug", "--json"]]);
  });

  it("returns non-zero-exit JSON as a normal result", async () => {
    const s = setup({ FAKE_PORTAGE_MODE: "exit3json" });
    const r = await runTool(s.runner, tool("portage_policy_show"), {});
    expect(r.details).toMatchObject({ status: "needs_approval" });
  });

  it("returns an error result (not a throw) for bad input without spawning", async () => {
    const s = setup();
    const r = await runTool(s.runner, tool("portage_find"), { query: "--yes" });
    expect(r.details).toMatchObject({ error: expect.stringMatching(/invalid input/) });
    expect(s.calls()).toEqual([]);
  });

  it("returns an error result for garbage output", async () => {
    const s = setup({ FAKE_PORTAGE_MODE: "garbage" });
    const r = await runTool(s.runner, tool("portage_doctor"), {});
    expect(r.content[0]!.text).toMatch(/^Error:/);
  });
});
