import { Type, type TSchema } from "typebox";

/**
 * Permissive output schemas for `details`. Every field is optional and nullable, extra fields are
 * allowed, and error results (`{ error }`) validate too: they describe the common CLI outcomes for
 * the model, they never gate a valid report.
 */
const loose = (props: Record<string, TSchema>): TSchema =>
  Type.Object(
    Object.fromEntries(Object.entries(props).map(([k, v]) => [k, Type.Optional(Type.Union([v, Type.Null()]))])),
    { additionalProperties: true },
  );

const str = (description?: string) => Type.String(description ? { description } : {});
const bool = () => Type.Boolean();
const obj = () => Type.Object({}, { additionalProperties: true });
const objs = () => Type.Array(obj());
const anyList = () => Type.Array(Type.Unknown());

const common = {
  error: str("Set by the plugin (not the CLI) when the call failed, or by the CLI for a setup error."),
  message: str(),
  warnings: anyList(),
};

const offer = Type.Object(
  {
    offer_ref: Type.Optional(Type.Unknown()),
    match: Type.Optional(Type.Unknown()),
    store: Type.Optional(Type.Unknown()),
    product_id: Type.Optional(Type.Unknown()),
    title: Type.Optional(Type.Unknown()),
    amount: Type.Optional(Type.Unknown()),
    currency: Type.Optional(Type.Unknown()),
    checkout: Type.Optional(Type.Unknown()),
    url: Type.Optional(Type.Unknown()),
  },
  { additionalProperties: true },
);

/** `find` and `find --store`: offers (each with an `offer_ref`) and the `search_id` for pick. */
export const findOutput = loose({
  ...common,
  search_id: str("Names this search for portage_pick."),
  offers: Type.Array(offer),
  products: anyList(),
});

export const checkOutput = loose({
  ...common,
  url: str(),
  verdict: str("automated, webmcp, handoff or unsupported."),
  next_step: str("What Portage will do for this store, in words."),
  native_ucp: Type.Unknown(),
  platform: Type.Unknown(),
  recommended_gem: Type.Unknown(),
  handoff_only: Type.Unknown(),
  adapter: obj(),
  webmcp: obj(),
  live_probe: obj(),
  index_hint: str("A `portage index add` command, only for a Shopify or native UCP store."),
});

/** `compare`: `find`'s report with each offer scored (`match`: confirmed, likely or unconfirmed). */
export const compareOutput = loose({
  ...common,
  query: str(),
  search_id: str("Names this compare for portage_pick."),
  candidates: anyList(),
  stores: objs(),
  offers: Type.Array(offer),
});

const finding = Type.Object(
  {
    check: Type.Optional(Type.String()),
    message: Type.Optional(Type.String()),
    level: Type.Optional(Type.String({ description: "warning or info." })),
    details: Type.Optional(Type.Unknown()),
  },
  { additionalProperties: true },
);

/**
 * `doctor --json` prints a bare array of findings, not an object, so unlike the others this one
 * is a union: the array, or the loose object that carries the plugin's `{ error }`.
 */
export const doctorOutput = Type.Union([Type.Array(finding), loose(common)]);

/** `history list --json`: both lists are always present, the one not asked for is empty. */
export const historyOutput = loose({
  ...common,
  purchases: Type.Array(
    Type.Object(
      {
        url: Type.Optional(Type.Unknown()),
        query: Type.Optional(Type.Unknown()),
        outcome: Type.Optional(Type.Unknown()),
        source: Type.Optional(Type.Unknown()),
        checkout_id: Type.Optional(Type.Unknown()),
        checkout_status: Type.Optional(Type.Unknown()),
        checkout_url: Type.Optional(Type.Unknown()),
        total: Type.Optional(Type.Unknown()),
        currency: Type.Optional(Type.Unknown()),
        items: Type.Optional(Type.Unknown()),
        message: Type.Optional(Type.Unknown()),
        at: Type.Optional(Type.Unknown()),
      },
      { additionalProperties: true },
    ),
  ),
  searches: Type.Array(
    Type.Object(
      {
        search_id: Type.Optional(Type.Unknown()),
        query: Type.Optional(Type.Unknown()),
        url: Type.Optional(Type.Unknown()),
        offer_count: Type.Optional(Type.Unknown()),
        message: Type.Optional(Type.Unknown()),
        offers: Type.Optional(Type.Unknown()),
        at: Type.Optional(Type.Unknown()),
      },
      { additionalProperties: true },
    ),
  ),
});

/** Pick, approve, dry-run, buy and hand-off all report an `outcome`; the fields below are the common ones. */
const outcomeProps = {
  ...common,
  outcome: str("Branch on this, never on message."),
  status: str(),
  quote_id: str("qt_..., pins store, product, quantity and total."),
  search_id: str(),
  offer_ref: str(),
  needs_approval: bool(),
  quote_changed: bool(),
  checkout_mismatch: bool(),
  checkout: bool(),
  browse: bool(),
  checkout_url: str("Give this to the user."),
  total: Type.Unknown(),
  total_display: str(),
  currency: str(),
  quoted_total: Type.Unknown(),
  current_total: Type.Unknown(),
  summary: obj(),
  decisions: obj(),
  handoff: obj(),
  choices: objs(),
  approved_by: str(),
};

export const pickOutput = loose(outcomeProps);
export const dryRunOutput = loose(outcomeProps);
export const approveOutput = loose(outcomeProps);
export const buyQuoteOutput = loose(outcomeProps);
export const handoffOutput = loose(outcomeProps);
