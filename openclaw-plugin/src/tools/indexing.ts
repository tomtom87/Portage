import { Type } from "typebox";
import { flag, hostName, httpUrl, ident, list, oneOf, opt, posInt, InputError } from "../validate.js";
import { LONG_TIMEOUT_SECONDS, UNTRUSTED, type ToolSpec } from "./types.js";

const SOURCES_DESC = "Index source names (from portage_index_sources). Default: all.";
const BROWSERS = ["chrome", "edge", "brave", "arc", "firefox", "safari"] as const;

/** `--sources a,b`; names are plain tokens so a value can never smuggle a flag or a path. */
function sourcesArg(a: string[], v: unknown): void {
  const names = list("sources", v, (n, x) => {
    const s = ident(n, x);
    if (!/^[A-Za-z0-9_]+$/.test(s)) throw new InputError(`${n} must be a plain source name`);
    return s;
  });
  if (names) a.push("--sources", names.join(","));
}

const rebuildParams = Type.Object({
  sources: Type.Optional(Type.Array(Type.String(), { description: SOURCES_DESC })),
  dry_run: Type.Optional(Type.Boolean({ description: "Show what would change without saving." })),
});

function rebuildArgs(sub: "build" | "refresh") {
  return (p: Record<string, unknown>): string[] => {
    const a = ["index", sub];
    sourcesArg(a, p.sources);
    if (flag("dry_run", p.dry_run)) a.push("--dry-run");
    return [...a, "--json"];
  };
}

export const indexTools: ToolSpec[] = [
  {
    name: "portage_index_add",
    optional: true,
    description: `Add one store to the user's local store index (optionally crawling it for products). Changes the local index only. ${UNTRUSTED}`,
    parameters: Type.Object({
      url: Type.String({ description: "Store URL (http or https)." }),
      crawl: Type.Optional(Type.Boolean({ description: "Also crawl the store's products." })),
    }),
    buildArgs(p) {
      const a = ["index", "add", httpUrl("url", p.url)];
      if (flag("crawl", p.crawl)) a.push("--crawl");
      return [...a, "--json"];
    },
  },
  {
    name: "portage_index_remove",
    optional: true,
    description: "Remove one store from the user's local store index. Changes the local index only.",
    parameters: Type.Object({ host: Type.String({ description: "Store host, e.g. shop.example." }) }),
    buildArgs: (p) => ["index", "remove", hostName("host", p.host), "--json"],
  },
  {
    name: "portage_index_build",
    optional: true,
    description: `Build the local store and product index from the chosen sources. Slow the first time (minutes): warn the user before running it. Use dry_run first to preview. ${UNTRUSTED}`,
    parameters: rebuildParams,
    buildArgs: rebuildArgs("build"),
    timeoutSeconds: LONG_TIMEOUT_SECONDS,
  },
  {
    name: "portage_index_refresh",
    optional: true,
    description: `Re-verify old index entries and add new ones from the chosen sources. Can be slow: warn the user before running it. Use dry_run first to preview. ${UNTRUSTED}`,
    parameters: rebuildParams,
    buildArgs: rebuildArgs("refresh"),
    timeoutSeconds: LONG_TIMEOUT_SECONDS,
  },
  {
    name: "portage_browser_import",
    optional: true,
    description: `Find shop domains in the user's own browser bookmarks and history to seed the store index. Reads personal browsing data: run it only when the user asks for it, and say what it does first. By default it is a preview (dry run) that saves nothing and returns kept[] (domains and guessed categories only: show those, never the user's full history). Set confirm: true only after the user has seen the preview and approved saving it; exclude drops domains they turned down. Never work around a permission_denied or full_disk_access_required error: pass its message to the user. ${UNTRUSTED}`,
    parameters: Type.Object({
      browser: Type.Optional(Type.Union(BROWSERS.map((b) => Type.Literal(b)), { description: "Default: Portage picks." })),
      history_days: Type.Optional(Type.Integer({ minimum: 1, description: "Days of history to read (default 90)." })),
      include_product_pages: Type.Optional(Type.Boolean()),
      max_probes: Type.Optional(Type.Integer({ minimum: 1, description: "Most unknown domains to probe (default 200)." })),
      exclude: Type.Optional(Type.Array(Type.String(), { description: "Hosts to leave out." })),
      confirm: Type.Optional(
        Type.Boolean({ default: false, description: "True ONLY after the user approved saving the previewed import." }),
      ),
    }),
    buildArgs(p) {
      const a = ["browser", "import"];
      opt(a, "--browser", oneOf("browser", p.browser, BROWSERS));
      opt(a, "--history-days", posInt("history_days", p.history_days));
      if (flag("include_product_pages", p.include_product_pages)) a.push("--include-product-pages");
      opt(a, "--max-probes", posInt("max_probes", p.max_probes));
      const exclude = list("exclude", p.exclude, hostName);
      if (exclude) a.push("--exclude", exclude.join(","));
      // The single `--yes` outside `buy --quote`: saves a previewed import; never touches a payment.
      a.push(flag("confirm", p.confirm) ? "--yes" : "--dry-run");
      return [...a, "--json"];
    },
  },
];
