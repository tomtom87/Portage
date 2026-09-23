/*
 * portage-ucp-webmcp consumer (outbound).
 *
 * A single function expression Bridges::ScriptEvaluator evaluates in the
 * page (via whatever driver the caller has) as `(<this>)(op, name, input)`.
 * Always resolves — never rejects — to a JSON string envelope
 * `{ ok: true, value }` or `{ ok: false, code, error }`, so every driver sees
 * one shape regardless of how it surfaces a rejected promise. `code` is
 * "no_surface" (no WebMCP on the page), "not_registered" (no such tool) or
 * "execute_failed" (the tool itself threw or rejected).
 *
 * Surfaces probed, in order:
 *   1. `document.modelContext` / `navigator.modelContext` with `getTools()` +
 *      `executeTool(tool, input)` — the current spec.
 *   2. `navigator.modelContextTesting` with `listTools()` +
 *      `executeTool(name, jsonString)` — the testing API early browser builds
 *      shipped behind a flag.
 *   3. A `modelContext` with `listTools()` + `callTool({ name, arguments })`
 *      — the shape some userland polyfills expose.
 */
(function (op, name, input) {
  "use strict";

  var root = typeof window !== "undefined" ? window : globalThis;
  var doc = root.document;
  var nav = root.navigator || {};
  var context = (doc && doc.modelContext) || nav.modelContext;
  var testing = nav.modelContextTesting;

  function failure(code, message) {
    var error = new Error(message);
    error.code = code;
    return error;
  }

  function surface() {
    if (context && typeof context.getTools === "function" && typeof context.executeTool === "function") {
      return Promise.resolve(context.getTools()).then(function (tools) {
        return { kind: "spec", tools: tools || [] };
      });
    }
    if (testing && typeof testing.listTools === "function") {
      return Promise.resolve(testing.listTools()).then(function (tools) {
        return { kind: "testing", tools: tools || [] };
      });
    }
    if (context && typeof context.listTools === "function" && typeof context.callTool === "function") {
      return Promise.resolve(context.listTools()).then(function (listed) {
        return { kind: "polyfill", tools: (listed && listed.tools) || listed || [] };
      });
    }
    return Promise.reject(failure("no_surface",
      "no WebMCP tool surface on this page (document.modelContext, navigator.modelContext, " +
      "navigator.modelContextTesting)"));
  }

  function schema(value) {
    if (typeof value !== "string") return value || {};
    try { return JSON.parse(value); } catch (_e) { return {}; }
  }

  function plain(tool) {
    return {
      name: tool.name,
      title: tool.title || null,
      description: tool.description || "",
      inputSchema: schema(tool.inputSchema),
      annotations: tool.annotations || {},
      origin: tool.origin || null
    };
  }

  function execute(found) {
    var tool = found.tools.filter(function (t) { return t.name === name; })[0];
    if (!tool) throw failure("not_registered", "WebMCP tool not registered on this page: " + name);

    var run;
    try {
      if (found.kind === "spec") run = context.executeTool(tool, input || {});
      else if (found.kind === "testing") run = testing.executeTool(name, JSON.stringify(input || {}));
      else run = context.callTool({ name: name, arguments: input || {} });
    } catch (error) {
      run = Promise.reject(error);
    }
    return Promise.resolve(run).then(null, function (error) {
      throw failure("execute_failed", String((error && error.message) || error));
    });
  }

  var work = surface().then(function (found) {
    return op === "list" ? found.tools.map(plain) : execute(found);
  });

  return work.then(
    function (value) { return JSON.stringify({ ok: true, value: value === undefined ? null : value }); },
    function (error) {
      return JSON.stringify({
        ok: false,
        code: (error && error.code) || "execute_failed",
        error: String((error && error.message) || error)
      });
    }
  );
})
