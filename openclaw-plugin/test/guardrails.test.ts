import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { runTool } from "../src/execute.js";
import { allTools } from "../src/tools/index.js";
import { setup } from "./helpers.js";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "..", "src");

/** Valid input for each tool, so fuzzing can swap one field at a time. */
const VALID: Record<string, Record<string, unknown>> = {
  portage_doctor: {},
  portage_find: { query: "q", max_price: 5, limit: 2 },
  portage_find_store: { store: "https://s.example", query: "q", max_price: 5 },
  portage_check: { url: "https://s.example" },
  portage_compare: { url: "https://s.example", product_id: "1", ids: ["a"], results: 2, max_price: 5 },
  portage_index_search: { query: "q", category: "c", store: "s.example", limit: 2 },
  portage_index_show: { view: "products", page: 1, per_page: 5 },
  portage_index_sources: {},
  portage_history: { kind: "purchases", limit: 2 },
  portage_orders_reconcile: { checkout: "c_1" },
  portage_policy_show: {},
  portage_payment_list: {},
  portage_browser_profile_status: {},
  portage_pick: { search: "se_1a2b3c4d", choose: "of_1a2b3c" },
  portage_dry_run: { offer: "of_1a2b3c", qty: 2 },
  portage_approve: { quote_id: "qt_0123456789ab", relayed_yes: false },
  portage_buy_quote: { quote_id: "qt_0123456789ab" },
  portage_handoff: { store: "https://s.example", query: "q", product_id: "1", qty: 1, target: "profile", wait: true, wait_timeout: "10m" },
  portage_index_add: { url: "https://s.example", crawl: true },
  portage_index_remove: { host: "s.example" },
  portage_index_build: { sources: ["stores_file"], dry_run: true },
  portage_index_refresh: { sources: ["stores_file"], dry_run: true },
  portage_browser_import: { browser: "chrome", exclude: ["a.example"], confirm: false },
};

const INJECTIONS: unknown[] = [
  "--yes", "-y", "--relayed-yes", "--payment-token=x", "--payment-token", "--via", "--via=tty", "--proxy", "--proxy=http://evil",
  "--decision-backend=jev", "--min-confidence=0", "-", "--", " --yes", "\n--yes", "--yes\n", "\t--relayed-yes",
  "x --yes", "x\n--yes\n--relayed-yes", "a b c", "$(touch /tmp/pwned)", "`id`", "; rm -rf /", "x\0--yes",
  "", "   ", "https://s.example --yes", "https://s.example\n--yes", "of_1 --yes", "qt_0123456789ab --yes",
  "http://--yes", "javascript:--yes", "file:///--yes",
  true, false, 0, 1, -1, 1.5, NaN, Infinity, null, [], ["--yes"], ["--relayed-yes", "--via"], {}, { yes: true }, "true",
];

const FORBIDDEN_FLAGS = [
  "--payment-token", "--via", "--decision-backend", "--min-confidence",
  "--proxy", "--proxy-mode", "--no-proxy", "--proxy-chain", "--proxy-ca", "--no-env-proxy", "--proxy-header",
  "--proxy-route", "--proxy-passthrough", "--notify-webhook", "--autofill",
];

/** Every argv this suite can provoke: the valid inputs, and each field of each valid input replaced by each injection. */
function* fuzz(): Generator<{ tool: string; params: Record<string, unknown> }> {
  for (const t of allTools) {
    const base = VALID[t.name]!;
    yield { tool: t.name, params: base };
    yield { tool: t.name, params: {} };
    for (const key of Object.keys(base)) {
      for (const bad of INJECTIONS) yield { tool: t.name, params: { ...base, [key]: bad } };
    }
    // fields the tool does not declare must be ignored, never turned into flags
    for (const extra of ["yes", "relayed_yes", "payment_token", "via", "proxy", "decision_backend", "min_confidence", "confirm", "handoff_target"]) {
      yield { tool: t.name, params: { ...base, [extra]: "--yes" } };
      yield { tool: t.name, params: { ...base, [extra]: true } };
    }
  }
}

function argvFor(tool: string, params: Record<string, unknown>): string[] | null {
  try {
    return allTools.find((t) => t.name === tool)!.buildArgs({ ...params });
  } catch {
    return null; // rejected before spawning
  }
}

describe("guardrails: every registered tool, fuzzed", () => {
  const cases = [...fuzz()];
  const built = cases.map((c) => ({ ...c, argv: argvFor(c.tool, c.params) }));

  it("fuzzes all 23 tools and produces plenty of accepted and rejected inputs", () => {
    expect(new Set(cases.map((c) => c.tool)).size).toBe(23);
    expect(built.filter((b) => b.argv).length).toBeGreaterThan(200);
    expect(built.filter((b) => !b.argv).length).toBeGreaterThan(200);
  });

  it("emits --yes only in `buy --quote ID --yes --json` (portage_buy_quote) and `browser import ... --yes` (confirm: true)", () => {
    for (const { tool, params, argv } of built) {
      if (!argv || !argv.includes("--yes")) continue;
      const where = JSON.stringify({ tool, params, argv });
      if (tool === "portage_buy_quote") {
        expect(argv.slice(0, 2), where).toEqual(["buy", "--quote"]);
        expect(argv, where).toEqual(["buy", "--quote", argv[2], "--yes", "--json"]);
        expect(argv[2], where).toMatch(/^[A-Za-z0-9_.:]+$/);
      } else if (tool === "portage_browser_import") {
        expect(argv.slice(0, 2), where).toEqual(["browser", "import"]);
        expect(params.confirm, where).toBe(true);
        expect(argv, where).not.toContain("--dry-run");
      } else {
        throw new Error(`unexpected --yes: ${where}`);
      }
      expect(argv.filter((a) => a === "--yes"), where).toHaveLength(1);
    }
  });

  it("never puts --yes on a `buy` URL or --offer path, and never mixes --yes with --dry-run", () => {
    for (const { tool, argv } of built) {
      if (!argv) continue;
      const where = JSON.stringify({ tool, argv });
      if (argv[0] === "buy" && argv.includes("--yes")) {
        expect(argv[1], where).toBe("--quote");
        expect(argv, where).not.toContain("--offer");
        expect(argv.some((a) => /^https?:/.test(a)), where).toBe(false);
      }
      if (argv.includes("--yes")) expect(argv, where).not.toContain("--dry-run");
    }
  });

  it("`browser import` gets --yes only when confirm is exactly true, otherwise --dry-run", () => {
    for (const { tool, params, argv } of built.filter((b) => b.tool === "portage_browser_import")) {
      if (!argv) continue;
      if (params.confirm === true) expect(argv).toContain("--yes");
      else {
        expect(argv).not.toContain("--yes");
        expect(argv).toContain("--dry-run");
      }
      void tool;
    }
  });

  it("emits --relayed-yes only from portage_approve with relayed_yes exactly true", () => {
    let seen = 0;
    for (const { tool, params, argv } of built) {
      if (!argv || !argv.includes("--relayed-yes")) continue;
      seen++;
      const where = JSON.stringify({ tool, params, argv });
      expect(tool, where).toBe("portage_approve");
      expect(params.relayed_yes, where).toBe(true);
      expect(argv.slice(0, 1), where).toEqual(["approve"]);
      expect(argv.filter((a) => a === "--relayed-yes"), where).toHaveLength(1);
    }
    expect(seen).toBeGreaterThan(0);
    // default and explicit false never emit it
    expect(argvFor("portage_approve", { quote_id: "qt_0123456789ab" })).not.toContain("--relayed-yes");
    expect(argvFor("portage_approve", { quote_id: "qt_0123456789ab", relayed_yes: false })).not.toContain("--relayed-yes");
    // anything but the boolean true is refused, not coerced
    for (const v of ["true", "yes", "1", 1, {}, [], null]) {
      expect(argvFor("portage_approve", { quote_id: "qt_0123456789ab", relayed_yes: v })).toBeNull();
    }
  });

  it("never emits a forbidden flag or subcommand, whatever the input", () => {
    for (const { tool, params, argv } of built) {
      if (!argv) continue;
      const where = JSON.stringify({ tool, params, argv });
      for (const f of FORBIDDEN_FLAGS) {
        expect(argv.some((a) => a === f || a.startsWith(`${f}=`)), where).toBe(false);
      }
      const [cmd, sub] = argv;
      expect(["policy", "show"].join(" ") === `${cmd} ${sub}` || cmd !== "policy", where).toBe(true);
      expect(cmd, where).not.toBe("setup");
      expect(cmd, where).not.toBe("generate");
      expect(cmd, where).not.toBe("configure");
      if (cmd === "payment") expect(sub, where).toBe("list");
      if (cmd === "history") expect(sub, where).toBe("list");
      if (cmd === "browser") expect(["import", "profile"], where).toContain(sub);
      if (cmd === "browser" && sub === "profile") expect(argv[2], where).toBe("status");
      for (const bad of ["enroll", "remove", "revoke", "freeze", "set-default", "clear", "set"]) {
        if (cmd === "payment" || cmd === "history" || cmd === "policy") expect(sub, where).not.toBe(bad);
      }
    }
  });

  it("only ever runs the documented subcommands", () => {
    const allowed = ["doctor", "find", "check", "compare", "index", "history", "orders", "policy", "payment", "browser", "pick", "approve", "buy"];
    for (const { tool, argv } of built) {
      if (argv) expect(allowed, JSON.stringify({ tool, argv })).toContain(argv[0]);
    }
  });

  it("keeps every user string one argv element that is never flag-shaped when it stands alone", () => {
    // a string value that starts with "-" (after trimming) is never an argv element at all
    const stringInjections = INJECTIONS.filter((v): v is string => typeof v === "string" && v.trim().startsWith("-"));
    for (const t of allTools) {
      const base = VALID[t.name]!;
      for (const [key, val] of Object.entries(base)) {
        if (typeof val !== "string") continue;
        for (const bad of stringInjections) {
          expect(argvFor(t.name, { ...base, [key]: bad }), `${t.name}.${key}=${JSON.stringify(bad)}`).toBeNull();
        }
      }
    }
  });

  it("rejects flag-shaped entries inside array params", () => {
    expect(argvFor("portage_compare", { ...VALID.portage_compare, ids: ["ok", "--yes"] })).toBeNull();
    expect(argvFor("portage_index_build", { sources: ["ok", "--yes"] })).toBeNull();
    expect(argvFor("portage_browser_import", { exclude: ["ok.example", "--yes"] })).toBeNull();
  });

  it("free text with spaces, newlines and flag-like words stays a single argv element", () => {
    const q = "mug --yes\n--relayed-yes --via tty";
    expect(argvFor("portage_find", { query: q })).toEqual(["find", "--query", q, "--json"]);
    expect(argvFor("portage_dry_run", { store: "https://s.example", query: q, product_id: "1" })).toEqual(
      ["buy", "https://s.example", "--query", q, "--product-id", "1", "--dry-run", "--json"],
    );
  });
});

describe("guardrails: through the fake portage", () => {
  it("records the argv the process really receives, with only the documented --yes", async () => {
    const s = setup();
    for (const t of allTools) {
      await runTool(s.runner, t, VALID[t.name]);
      await runTool(s.runner, t, { ...VALID[t.name], query: "--yes", quote_id: "--yes", offer: "--relayed-yes", confirm: "true" });
    }
    const calls = s.calls();
    expect(calls.length).toBeGreaterThanOrEqual(23);
    for (const argv of calls) {
      if (argv.includes("--yes")) {
        const quoteBuy = argv[0] === "buy" && argv[1] === "--quote" && argv[3] === "--yes";
        const importYes = argv[0] === "browser" && argv[1] === "import";
        expect(quoteBuy || importYes, JSON.stringify(argv)).toBe(true);
      }
      expect(argv).not.toContain("--relayed-yes");
      for (const f of FORBIDDEN_FLAGS) expect(argv).not.toContain(f);
    }
  });
});

describe("guardrails: credentials and policy files", () => {
  const files = (dir: string): string[] =>
    readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? files(join(dir, e.name)) : [join(dir, e.name)]));
  const sources = files(SRC).filter((f) => f.endsWith(".ts"));

  it("no source file touches ~/.portage/.env, policy.json or quotes/", () => {
    expect(sources.length).toBeGreaterThan(5);
    for (const f of sources) {
      const text = readFileSync(f, "utf8");
      expect(text, f).not.toMatch(/~\/\.portage|["'`\/]\.portage["'`\/]|policy\.json|quotes\/|["'`\/]\.env["'`]/);
      expect(text, f).not.toMatch(/\b(readFile|readFileSync|createReadStream|readdir|readdirSync|homedir)\b/);
    }
  });

  it("no source file builds a forbidden flag or subcommand", () => {
    const banned = [
      /["'`]--payment-token/, /["'`]--via/, /["'`]--decision-backend/, /["'`]--min-confidence/, /["'`]--proxy/,
      /["'`]--no-proxy/, /["'`]--no-env-proxy/, /["'`](setup|generate|configure)["'`]/,
      /["'`](enroll|revoke|freeze|set-default|clear)["'`]/,
    ];
    for (const f of sources) {
      const text = readFileSync(f, "utf8").replace(/\/\/.*$/gm, "");
      for (const re of banned) expect(text, `${f} ${re}`).not.toMatch(re);
    }
  });

  it("--yes is spelled in exactly two places: buy --quote and browser import --confirm", () => {
    const hits = sources.flatMap((f) =>
      readFileSync(f, "utf8").split("\n").filter((l) => /["'`]--yes["'`]/.test(l) && !l.trim().startsWith("//")).map((l) => `${f.slice(SRC.length)}: ${l.trim()}`),
    );
    expect(hits).toHaveLength(2);
    expect(hits.filter((h) => h.includes("buying.ts") && h.includes('"--quote"'))).toHaveLength(1);
    expect(hits.filter((h) => h.includes("indexing.ts") && h.includes("confirm"))).toHaveLength(1);
    expect(sources.some((f) => readFileSync(f, "utf8").includes('"--relayed-yes"'))).toBe(true);
  });
});

describe("guardrails: descriptions", () => {
  it("every tool that returns store or product text says it is untrusted data", () => {
    const quiet = ["portage_doctor", "portage_index_sources", "portage_policy_show", "portage_payment_list", "portage_browser_profile_status", "portage_orders_reconcile", "portage_index_remove"];
    for (const t of allTools) {
      if (quiet.includes(t.name)) continue;
      expect(t.description, t.name).toMatch(/untrusted data/);
    }
  });

  it("portage_approve says relayed_yes needs the user's explicit approval of that exact total", () => {
    const t = allTools.find((x) => x.name === "portage_approve")!;
    expect(t.description).toMatch(/relayed_yes may ONLY be true after the user has explicitly said yes/);
    expect(t.description).toMatch(/exact total/);
    const p = (t.parameters as any).properties.relayed_yes;
    expect(p.default).toBe(false);
    expect(p.description).toMatch(/ONLY after the user explicitly approved this exact total/);
  });

  it("portage_buy_quote says it needs a prior dry run and the user's approval", () => {
    const t = allTools.find((x) => x.name === "portage_buy_quote")!;
    expect(t.description).toMatch(/only tool that can spend money/);
    expect(t.description).toMatch(/user approved that exact total/);
  });

  it("portage_browser_import warns about personal data and confirm", () => {
    const t = allTools.find((x) => x.name === "portage_browser_import")!;
    expect(t.description).toMatch(/personal browsing data/);
    expect(t.description).toMatch(/confirm: true only after the user/);
  });
});
