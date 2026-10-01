import { Value } from "typebox/value";
import { describe, expect, it } from "vitest";
import { allTools } from "../src/tools/index.js";

/** Canned CLI-shaped reports (and the plugin's own error shape) every output schema must accept. */
const SAMPLES: unknown[] = [
  { ok: true, argv: ["find"] },
  { error: "invalid input: query must be a string" },
  {},
  { search_id: "se_0123456789ab", offers: [{ offer_ref: "of_1a2b3c", store: "shop.example", product_id: "1", title: "Mug", amount: 1200, currency: "USD", checkout: "ucp", url: "https://shop.example/p/1", product: { media: [] } }] },
  { offers: [], warnings: ["x"] },
  { verdict: "automated", next_step: null, native_ucp: true, adapter: { gem: null, installed: false, missing_env: [] }, webmcp: { status: "skipped", tools: [] } },
  { outcome: "dry_run", quote_id: "qt_0123456789ab", total: 2400, currency: "USD", checkout_mismatch: false, warnings: [], decisions: { escalation: null } },
  { outcome: "needs_approval", quote_id: "qt_0123456789ab", summary: { title: "Mug", store: "shop.example", qty: 2, total: 2400, total_display: "24.00", currency: "USD", url: "https://shop.example/p/1", approved_by: null } },
  { outcome: "needs_pick", search_id: "se_0123456789ab", choices: [{ ref: "of_1a2b3c", label: "Mug", url: "https://shop.example" }, { ref: "compare", label: "Compare", url: null }] },
  { outcome: "quote_changed", quoted_total: 2400, current_total: 2600, checkout_url: null },
  { outcome: "purchased", checkout: true, browse: false, handoff: { url: "u", opened: true, handoff_target: "default" } },
  { status: "needs_approval", needs_approval: true },
  { checks: [{ name: "shipping", ok: true }], ok: false },
];

describe("output schemas", () => {
  const withSchema = allTools.filter((t) => t.outputSchema);

  it("covers find, find_store, check, compare, doctor, pick, dry_run, approve, buy_quote and handoff", () => {
    expect(withSchema.map((t) => t.name).sort()).toEqual(
      ["portage_approve", "portage_buy_quote", "portage_check", "portage_compare", "portage_doctor", "portage_dry_run",
        "portage_find", "portage_find_store", "portage_handoff", "portage_pick"].sort(),
    );
  });

  for (const t of withSchema) {
    it(`${t.name} accepts every sample report and the error shape`, () => {
      for (const sample of SAMPLES) expect(Value.Check(t.outputSchema!, sample), JSON.stringify(sample)).toBe(true);
    });
    it(`${t.name} is a top-level object that allows extra fields`, () => {
      expect((t.outputSchema as any).type).toBe("object");
      expect((t.outputSchema as any).additionalProperties).toBe(true);
    });
  }
});
