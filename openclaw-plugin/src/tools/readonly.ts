import { Type } from "typebox";
import { httpUrl, opt, optStr, oneOf, posInt, posNum, str } from "../validate.js";
import { UNTRUSTED, type ToolSpec } from "./types.js";

const URL_DESC = "Store URL (http or https).";
const empty = Type.Object({});

export const readonlyTools: ToolSpec[] = [
  {
    name: "portage_doctor",
    description:
      "Check the Portage setup (adapters, payment, policy, browser). Run first when something fails. Read-only.",
    parameters: empty,
    buildArgs: () => ["doctor", "--json"],
  },
  {
    name: "portage_find",
    description: `Search across the indexed stores for products. Read-only. ${UNTRUSTED}`,
    parameters: Type.Object({
      query: Type.String({ description: "What to search for." }),
      max_price: Type.Optional(Type.Number({ exclusiveMinimum: 0, description: "Maximum price." })),
      limit: Type.Optional(Type.Integer({ minimum: 1, description: "Maximum results." })),
    }),
    buildArgs(p) {
      const a = ["find", "--query", str("query", p.query)];
      opt(a, "--max-price", posNum("max_price", p.max_price));
      opt(a, "--limit", posInt("limit", p.limit));
      return [...a, "--json"];
    },
  },
  {
    name: "portage_find_store",
    description: `Search one store's live catalogue for products (read-only, no purchase). Use to re-check price or stock at a specific store. ${UNTRUSTED}`,
    parameters: Type.Object({
      store: Type.String({ description: URL_DESC }),
      query: Type.String({ description: "What to search for." }),
      max_price: Type.Optional(Type.Number({ exclusiveMinimum: 0, description: "Maximum price." })),
    }),
    buildArgs(p) {
      const a = ["find", "--store", httpUrl("store", p.store), "--query", str("query", p.query)];
      opt(a, "--max-price", posNum("max_price", p.max_price));
      return [...a, "--json"];
    },
  },
  {
    name: "portage_check",
    description: `Check whether a store supports Portage and which checkout path it offers. Read-only. ${UNTRUSTED}`,
    parameters: Type.Object({ url: Type.String({ description: URL_DESC }) }),
    buildArgs: (p) => ["check", httpUrl("url", p.url), "--json"],
  },
  {
    name: "portage_compare",
    description: `Compare a product at a store against other results. Read-only. ${UNTRUSTED}`,
    parameters: Type.Object({
      url: Type.String({ description: URL_DESC }),
      product_id: Type.String({ description: "Product id at that store." }),
      ids: Type.Optional(Type.Array(Type.String(), { description: "Extra product ids to compare." })),
      results: Type.Optional(Type.Integer({ minimum: 1, description: "Number of comparison results." })),
      max_price: Type.Optional(Type.Number({ exclusiveMinimum: 0 })),
    }),
    buildArgs(p) {
      const a = ["compare", httpUrl("url", p.url), "--product-id", str("product_id", p.product_id)];
      if (p.ids !== undefined) {
        if (!Array.isArray(p.ids)) throw new Error("ids must be an array");
        p.ids.forEach((id, i) => a.push("--id", str(`ids[${i}]`, id)));
      }
      opt(a, "--results", posInt("results", p.results));
      opt(a, "--max-price", posNum("max_price", p.max_price));
      return [...a, "--json"];
    },
  },
  {
    name: "portage_index_search",
    description: `Search the local store/product index. Read-only. ${UNTRUSTED}`,
    parameters: Type.Object({
      query: Type.String(),
      category: Type.Optional(Type.String({ description: "Category id." })),
      store: Type.Optional(Type.String({ description: "Store host, e.g. example.com." })),
      limit: Type.Optional(Type.Integer({ minimum: 1 })),
    }),
    buildArgs(p) {
      const a = ["index", "search", str("query", p.query)];
      opt(a, "--category", optStr("category", p.category));
      opt(a, "--store", optStr("store", p.store));
      opt(a, "--limit", posInt("limit", p.limit));
      return [...a, "--json"];
    },
  },
  {
    name: "portage_index_show",
    description: `Show the local index summary, or list its stores or products (paged). Read-only. ${UNTRUSTED}`,
    parameters: Type.Object({
      view: Type.Optional(
        Type.Union([Type.Literal("stores"), Type.Literal("products")], { description: "Omit for a summary." }),
      ),
      page: Type.Optional(Type.Integer({ minimum: 1, description: "products view only." })),
      per_page: Type.Optional(Type.Integer({ minimum: 1, description: "products view only." })),
    }),
    buildArgs(p) {
      const view = oneOf("view", p.view, ["stores", "products"] as const);
      const page = posInt("page", p.page);
      const perPage = posInt("per_page", p.per_page);
      if ((page !== undefined || perPage !== undefined) && view !== "products") {
        throw new Error('page and per_page need view "products"');
      }
      const a = ["index", "show"];
      if (view) a.push(`--${view}`);
      opt(a, "--page", page);
      opt(a, "--per-page", perPage);
      return [...a, "--json"];
    },
  },
  {
    name: "portage_index_sources",
    description: "List the index sources Portage can build from. Read-only.",
    parameters: empty,
    buildArgs: () => ["index", "sources", "--json"],
  },
  {
    name: "portage_history",
    description: `List past Portage purchases and searches. Read-only. ${UNTRUSTED}`,
    parameters: Type.Object({
      kind: Type.Optional(Type.Union([Type.Literal("purchases"), Type.Literal("searches")])),
      limit: Type.Optional(Type.Integer({ minimum: 1 })),
    }),
    buildArgs(p) {
      const kind = oneOf("kind", p.kind, ["purchases", "searches"] as const);
      const a = ["history", "list"];
      if (kind) a.push(`--${kind}`);
      opt(a, "--limit", posInt("limit", p.limit));
      return [...a, "--json"];
    },
  },
  {
    name: "portage_orders_reconcile",
    description:
      "Reconcile pending checkouts with the merchant and report their final order status. Reads order state; does not buy anything.",
    parameters: Type.Object({
      checkout: Type.Optional(Type.String({ description: "Reconcile only this checkout id." })),
    }),
    buildArgs(p) {
      const a = ["orders", "reconcile"];
      opt(a, "--checkout", optStr("checkout", p.checkout));
      return [...a, "--json"];
    },
  },
  {
    name: "portage_policy_show",
    description:
      "Show the user's spending policy (caps, allowlist, approval requirement). Read-only; the policy can only be changed by the user in a terminal.",
    parameters: empty,
    buildArgs: () => ["policy", "show", "--json"],
  },
  {
    name: "portage_payment_list",
    description:
      "List enrolled payment methods (labels and ids only, never credentials). Read-only; enrolment is done by the user in a terminal.",
    parameters: empty,
    buildArgs: () => ["payment", "list", "--json"],
  },
  {
    name: "portage_browser_profile_status",
    description: "Report the status of Portage's dedicated browser profile used for hand-off. Read-only.",
    parameters: empty,
    buildArgs: () => ["browser", "profile", "status", "--json"],
  },
];
