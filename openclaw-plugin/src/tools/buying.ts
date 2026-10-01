import { Type } from "typebox";
import { flag, httpUrl, ident, duration, opt, oneOf, posInt, str, InputError } from "../validate.js";
import { LONG_TIMEOUT_SECONDS, UNTRUSTED, type ToolSpec } from "./types.js";

const REF_DESC = "Offer ref from a find report (`offers[].offer_ref`, e.g. of_1a2b3c).";
const STORE_DESC = "Store URL (http or https). Use with query and product_id when the user named a store.";

/** Shared shape of the two ways to name what to buy: a picked offer, or a store plus query plus product id. */
const targetProps = {
  offer: Type.Optional(Type.String({ description: REF_DESC })),
  store: Type.Optional(Type.String({ description: STORE_DESC })),
  query: Type.Optional(Type.String({ description: "What was searched for. With store." })),
  product_id: Type.Optional(Type.String({ description: "Product id at that store. With store." })),
  qty: Type.Optional(Type.Integer({ minimum: 1, description: "Quantity (default 1)." })),
};

/** `--offer REF` or `URL --query Q --product-id ID`, plus `--qty`. Exactly one of the two modes. */
function buyTarget(p: Record<string, unknown>): string[] {
  const byOffer = p.offer !== undefined;
  const byStore = p.store !== undefined || p.query !== undefined || p.product_id !== undefined;
  if (byOffer && byStore) throw new InputError("give either offer, or store with query and product_id, not both");
  if (!byOffer && !byStore) throw new InputError("give either offer, or store with query and product_id");
  const a = ["buy"];
  if (byOffer) {
    a.push("--offer", ident("offer", p.offer));
  } else {
    if (p.store === undefined || p.query === undefined || p.product_id === undefined) {
      throw new InputError("store, query and product_id are all needed together");
    }
    a.push(httpUrl("store", p.store), "--query", str("query", p.query), "--product-id", str("product_id", p.product_id));
  }
  opt(a, "--qty", posInt("qty", p.qty));
  return a;
}

/** Seconds the runner should allow a `--wait` hand-off: the CLI's own ceiling plus a minute. */
function waitTimeoutSeconds(p: Record<string, unknown>): number | undefined {
  if (p.wait !== true) return undefined;
  const d = duration("wait_timeout", p.wait_timeout);
  if (d === undefined) return LONG_TIMEOUT_SECONDS + 60;
  return Number(d.slice(0, -1)) * { s: 1, m: 60, h: 3600 }[d.slice(-1) as "s" | "m" | "h"] + 60;
}

export const buyingTools: ToolSpec[] = [
  {
    name: "portage_pick",
    optional: true,
    description: `Let the user choose which store to buy from, after portage_find. With no arguments it returns the choices (outcome needs_pick) for you to show the user. Only pass choose with the ref the user themselves picked; never pick a store for them and never guess a ref. compare re-searches one offer across stores; view opens the product page in the user's browser and is never an answer. ${UNTRUSTED}`,
    parameters: Type.Object({
      search: Type.Optional(Type.String({ description: "Search id from the find report (default: the latest search)." })),
      choose: Type.Optional(Type.String({ description: "The ref the user picked." })),
      compare: Type.Optional(Type.String({ description: "Compare this offer ref across stores." })),
      view: Type.Optional(Type.String({ description: "Open this offer ref's product page in the user's browser." })),
    }),
    buildArgs(p) {
      const modes = (["choose", "compare", "view"] as const).filter((k) => p[k] !== undefined);
      if (modes.length > 1) throw new InputError("give at most one of choose, compare, view");
      const a = ["pick"];
      if (p.search !== undefined) a.push("--search", ident("search", p.search));
      if (modes[0]) a.push(`--${modes[0]}`, ident(modes[0], p[modes[0]]));
      return [...a, "--json"];
    },
  },
  {
    name: "portage_dry_run",
    optional: true,
    description: `Price a purchase without buying: real total, shipping and taxes, and a quote_id to approve. Name the item by a picked offer, or by store with query and product_id. Nothing is bought or charged. Show the user the total. ${UNTRUSTED}`,
    parameters: Type.Object(targetProps),
    buildArgs: (p) => [...buyTarget(p), "--dry-run", "--json"],
  },
  {
    name: "portage_approve",
    optional: true,
    description: `Check or record the user's approval of a quote. Without relayed_yes it returns outcome needs_approval with a summary to show the user (or approved if they already approved it at a terminal). relayed_yes may ONLY be true after the user has explicitly said yes, in this chat, to that exact total for that exact quote; never set it on your own judgement, never to skip asking, and ask again for each new quote. view opens the product page in the user's browser and is never an approval. ${UNTRUSTED}`,
    parameters: Type.Object({
      quote_id: Type.String({ description: "Quote id from portage_dry_run (qt_...)." }),
      relayed_yes: Type.Optional(
        Type.Boolean({
          default: false,
          description:
            "True ONLY after the user explicitly approved this exact total in chat. Default false.",
        }),
      ),
      view: Type.Optional(Type.Boolean({ description: "Open the quote's product page for the user instead of approving." })),
    }),
    buildArgs(p) {
      const relayed = flag("relayed_yes", p.relayed_yes);
      const view = flag("view", p.view);
      if (relayed && view) throw new InputError("relayed_yes and view cannot be combined");
      const a = ["approve", ident("quote_id", p.quote_id)];
      if (relayed) a.push("--relayed-yes");
      if (view) a.push("--view");
      return [...a, "--json"];
    },
  },
  {
    name: "portage_buy_quote",
    optional: true,
    description: `Buy exactly what an approved quote priced. The only tool that can spend money. Run it only after portage_dry_run produced the quote and the user approved that exact total (portage_approve). Portage itself refuses unless the quote is approved under the user's policy, and stops with quote_changed, checkout_mismatch, policy_blocked or low_confidence rather than overspend; show those to the user and never retry blindly. Only outcome purchased means bought; check portage_history before retrying after an error. ${UNTRUSTED}`,
    parameters: Type.Object({
      quote_id: Type.String({ description: "Approved quote id (qt_...)." }),
    }),
    buildArgs: (p) => ["buy", "--quote", ident("quote_id", p.quote_id), "--yes", "--json"],
  },
  {
    name: "portage_handoff",
    optional: true,
    description: `Build the cart and hand the checkout to the user, who reviews and pays in their own browser; nothing is charged by this tool. Name the item by a picked offer, or by store with query and product_id. target: default opens the checkout in the user's browser, print only reports the checkout_url, profile uses Portage's dedicated browser profile (the user must have opened it). Omit target to use their configured default. wait blocks until the user finishes or wait_timeout (like 30m, default 30m) passes. Always tell the user to open checkout_url to review and pay. ${UNTRUSTED}`,
    parameters: Type.Object({
      ...targetProps,
      target: Type.Optional(
        Type.Union([Type.Literal("default"), Type.Literal("print"), Type.Literal("profile")], {
          description: "Where to open the checkout.",
        }),
      ),
      wait: Type.Optional(Type.Boolean({ description: "Block until the hand-off completes or times out." })),
      wait_timeout: Type.Optional(Type.String({ description: "With wait: 45s, 30m or 1h (default 30m)." })),
    }),
    buildArgs(p) {
      const a = buyTarget(p);
      const target = oneOf("target", p.target, ["default", "print", "profile"] as const);
      if (target) a.push("--handoff-target", target);
      const wait = flag("wait", p.wait);
      const waitTimeout = duration("wait_timeout", p.wait_timeout);
      if (waitTimeout !== undefined && !wait) throw new InputError("wait_timeout needs wait: true");
      if (wait) a.push("--wait");
      opt(a, "--wait-timeout", waitTimeout);
      return [...a, "--json"];
    },
    timeoutFor: waitTimeoutSeconds,
  },
];
