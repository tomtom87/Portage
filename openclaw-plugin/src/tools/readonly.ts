import { Type } from "typebox";
import { httpUrl, opt, optStr, oneOf, posInt, posNum, str } from "../validate.js";
import { checkOutput, compareOutput, doctorOutput, findOutput, historyOutput } from "./outputs.js";
import { UNTRUSTED, type ToolSpec } from "./types.js";

const URL_DESC = "Store URL (http or https).";
const empty = Type.Object({});

export const readonlyTools: ToolSpec[] = [
  {
    name: "portage_doctor",
    description:
      "Report the Portage setup: shipping address, search backends, agent profile, payment, proxy, browser. Run it first in a session, and again whenever a call fails or something looks unconfigured. Returns a read-only report; fixing gaps is up to the user (they run `portage setup` themselves).",
    parameters: empty,
    outputSchema: doctorOutput,
    buildArgs: () => ["doctor", "--json"],
  },
  {
    name: "portage_find",
    description: `Search for products across stores when the user has not named one. Params: query, optional max_price and limit. Returns offers[] (offer_ref like of_1a2b3c, store, product_id, title, amount in minor units, currency, url) and a search_id for portage_pick. Show offers with their urls; do not pick a store for the user. Read-only, buys nothing. ${UNTRUSTED}`,
    parameters: Type.Object({
      query: Type.String({ description: "What to search for." }),
      max_price: Type.Optional(Type.Number({ exclusiveMinimum: 0, description: "Maximum price." })),
      limit: Type.Optional(Type.Integer({ minimum: 1, description: "Maximum results." })),
    }),
    outputSchema: findOutput,
    buildArgs(p) {
      const a = ["find", "--query", str("query", p.query)];
      opt(a, "--max-price", posNum("max_price", p.max_price));
      opt(a, "--limit", posInt("limit", p.limit));
      return [...a, "--json"];
    },
  },
  {
    name: "portage_find_store",
    description: `Search one named store's live catalogue (params: store URL, query, optional max_price). Use it when the user names a store, or to re-check a live price or stock after an index hit; it never creates a cart. Returns offers[] like portage_find. Read-only. ${UNTRUSTED}`,
    parameters: Type.Object({
      store: Type.String({ description: URL_DESC }),
      query: Type.String({ description: "What to search for." }),
      max_price: Type.Optional(Type.Number({ exclusiveMinimum: 0, description: "Maximum price." })),
    }),
    outputSchema: findOutput,
    buildArgs(p) {
      const a = ["find", "--store", httpUrl("store", p.store), "--query", str("query", p.query)];
      opt(a, "--max-price", posNum("max_price", p.max_price));
      return [...a, "--json"];
    },
  },
  {
    name: "portage_check",
    description: `Check whether Portage can buy from a store (param: url). Returns verdict (automated, webmcp, handoff or unsupported) and next_step; tell the user plainly which it is. Makes plain GET requests only, never a cart. Read-only. ${UNTRUSTED}`,
    parameters: Type.Object({ url: Type.String({ description: URL_DESC }) }),
    outputSchema: checkOutput,
    buildArgs: (p) => ["check", httpUrl("url", p.url), "--json"],
  },
  {
    name: "portage_compare",
    description: `Compare one product at a store across other stores (params: url, product_id; optional extra ids, results, max_price). Returns comparable offers. Use it when the user wants the best price for a specific product. Read-only. ${UNTRUSTED}`,
    parameters: Type.Object({
      url: Type.String({ description: URL_DESC }),
      product_id: Type.String({ description: "Product id at that store." }),
      ids: Type.Optional(Type.Array(Type.String(), { description: "Extra product ids to compare." })),
      results: Type.Optional(Type.Integer({ minimum: 1, description: "Number of comparison results." })),
      max_price: Type.Optional(Type.Number({ exclusiveMinimum: 0 })),
    }),
    outputSchema: compareOutput,
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
    description: `Search the user's local store and product index (params: query; optional category, store host, limit). Hits come from the index, not live: never quote an index price as current or claim stock; re-check with portage_find_store first. Read-only. ${UNTRUSTED}`,
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
    description: `Show the local index summary, or with view list its stores or products (products can be paged with page and per_page). Read-only. ${UNTRUSTED}`,
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
    description: "List the sources Portage can build the store index from and what each fetches. Use before portage_index_build or portage_index_refresh. Read-only.",
    parameters: empty,
    buildArgs: () => ["index", "sources", "--json"],
  },
  {
    name: "portage_history",
    description: `List past Portage purchases and searches (params: optional kind purchases or searches, limit). Check it before buying so nothing is bought twice, and after an error to see whether a purchase went through. Read-only. ${UNTRUSTED}`,
    parameters: Type.Object({
      kind: Type.Optional(Type.Union([Type.Literal("purchases"), Type.Literal("searches")])),
      limit: Type.Optional(Type.Integer({ minimum: 1 })),
    }),
    outputSchema: historyOutput,
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
      "Check hand-offs the user finished in their browser and report their order status (optional param: checkout id). Use it to track an order after a hand-off. Reads order state; does not buy anything.",
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
      "Show the user's spending policy: caps, merchant allowlist and require_approval (any, person or off). Read it to know how approval will work. Read-only; only the user can change the policy, in a terminal.",
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
