/*
 * portage-ucp-webmcp page registrar (inbound).
 *
 * Registers a Portage-powered store's tools on the page's WebMCP surface so a
 * browser-native agent can call them. Each tool's `execute` is a thin
 * JSON-RPC `tools/call` POST back to the store's own WebMcp::Rack::CallEndpoint,
 * which hands it to the same Portage::Ucp::Mcp::Server every other transport
 * uses. Nothing commerce-related happens in the browser.
 *
 * Rendered by Portage::Ucp::WebMcp::Registrar, which substitutes the config
 * object for the placeholder on the last line. Plain ES2017, no build step.
 */
(function (config) {
  "use strict";

  var root = typeof window !== "undefined" ? window : globalThis;
  var doc = root.document;
  var nav = root.navigator;
  var state = { registered: [], errors: [], reason: null, unregister: unregister };
  var controller = typeof AbortController === "function" ? new AbortController() : null;
  var handles = [];
  var pending = [];
  var nextId = 0;

  // Bounded wait, in ms, for the previous generation's own registerTool
  // calls (still in flight when a Turbo/SPA reload re-runs this script tag)
  // to settle and unregister before this generation registers the same
  // names. registerTool is async, so a second load can otherwise start
  // registering before the first generation's unregister has actually
  // dropped anything, colliding on every name. Same shape as Transport's
  // reregister_wait: one deadline, never reset, a stuck previous generation
  // costs at most this much (see CHANGELOG's 0e8d49c and the README's
  // "Timeouts").
  var REREGISTER_WAIT_MS = (config && config.reregisterWaitMs) || 2000;

  function timeoutAfter(ms) {
    return new Promise(function (resolve) { setTimeout(resolve, ms); });
  }

  // Drop the previous generation's registrations before this one starts.
  // `unregister()` itself waits out that generation's own pending
  // registerTool calls (see below), so this is only racing a previous
  // generation that never settles at all.
  var previous = root.portageWebMcp;
  var previousDone = previous && typeof previous.unregister === "function"
    ? Promise.race([previous.unregister(), timeoutAfter(REREGISTER_WAIT_MS)])
    : Promise.resolve();
  root.portageWebMcp = state;

  // Current spec: `document.modelContext`. Earlier drafts, and the browser
  // builds that shipped them, used `navigator.modelContext`. Neither
  // `document` nor `navigator` is guaranteed to exist on every host this
  // script can be evaluated in (a worker, a test harness), so both reads are
  // optional-chained by hand rather than assumed.
  var context = (doc && doc.modelContext) || (nav && nav.modelContext);
  if (!context || typeof context.registerTool !== "function") {
    state.reason = "no_model_context";
    return;
  }

  function uuid() {
    if (root.crypto && typeof root.crypto.randomUUID === "function") return root.crypto.randomUUID();
    return Date.now().toString(16) + "-" + Math.random().toString(16).slice(2);
  }

  // `_meta` is the one reserved input key: it travels as the JSON-RPC
  // request's own `_meta` (where Mcp::Server reads `ucp-agent.profile` and
  // `traceparent` from), never as a tool argument.
  function split(tool, input) {
    var args = {};
    var meta = null;
    Object.keys(input || {}).forEach(function (key) {
      if (key === "_meta") meta = input[key];
      else args[key] = input[key];
    });
    if (tool.mutating && !args.idempotency_key) args.idempotency_key = uuid();
    return { args: args, meta: meta };
  }

  function call(tool, input, options) {
    var parts = split(tool, input);
    var params = { name: tool.action, arguments: parts.args };
    if (parts.meta) params._meta = parts.meta;

    var headers = { "content-type": "application/json", accept: "application/json" };
    Object.keys(config.headers || {}).forEach(function (key) { headers[key] = config.headers[key]; });

    return root.fetch(config.endpoint, {
      method: "POST",
      credentials: config.credentials || "same-origin",
      headers: headers,
      body: JSON.stringify({ jsonrpc: "2.0", id: ++nextId, method: "tools/call", params: params }),
      signal: options && options.signal
    }).then(function (response) {
      // A proxy or error page in front of the endpoint answers HTML, not
      // JSON-RPC. Name the endpoint and status rather than letting the
      // agent see a bare "Unexpected token '<'".
      return Promise.resolve().then(function () { return response.json(); }).catch(function () {
        throw new Error("tools/call to " + config.endpoint + " returned a non-JSON response (" +
                        response.status + ")");
      }).then(function (body) {
        if (body && body.error) {
          var detail = body.error.data ? ": " + body.error.data : "";
          throw new Error((body.error.message || "tools/call failed (" + response.status + ")") + detail);
        }
        return body.result;
      });
    });
  }

  function descriptor(tool) {
    return {
      name: tool.name,
      title: tool.title,
      description: tool.description,
      inputSchema: tool.inputSchema,
      annotations: tool.annotations,
      execute: function (input, options) { return call(tool, input, options); }
    };
  }

  function registerOptions() {
    var options = {};
    if (controller) options.signal = controller.signal;
    if (config.exposedTo) options.exposedTo = config.exposedTo;
    return options;
  }

  function register(tool) {
    var settled;
    try {
      var handle = context.registerTool(descriptor(tool), registerOptions());
      settled = Promise.resolve(handle).then(function (resolved) {
        if (resolved && typeof resolved.unregister === "function") handles.push(resolved);
        state.registered.push(tool.name);
      }, function (error) {
        state.errors.push({ tool: tool.name, message: String((error && error.message) || error) });
      });
    } catch (error) {
      state.errors.push({ tool: tool.name, message: String((error && error.message) || error) });
      settled = Promise.resolve();
    }
    pending.push(settled);
  }

  // Spec surface unregisters on the AbortSignal passed at registration;
  // earlier drafts returned a handle with `unregister()` or offered
  // `unregisterTool(name)`. All three are tried — each is a no-op where the
  // browser doesn't implement it.
  //
  // Waits out this generation's own pending registerTool calls first (each
  // wrapped so one rejecting can't stall the others), so a caller — or the
  // next generation's script, racing this promise above — never unregisters
  // a name that hasn't finished registering yet, which would otherwise leave
  // it orphaned on `context` with nothing in `handles` to drop it.
  function unregister() {
    if (controller) controller.abort();
    var settled = Promise.all(pending.map(function (p) { return p.catch(function () {}); }));
    return settled.then(function () {
      handles.forEach(function (handle) { try { handle.unregister(); } catch (_e) { /* already gone */ } });
      if (context && typeof context.unregisterTool === "function") {
        config.tools.forEach(function (tool) { try { context.unregisterTool(tool.name); } catch (_e) { /* already gone */ } });
      }
      state.registered = [];
    });
  }

  previousDone.then(function () {
    config.tools.forEach(register);
  });
})(__PORTAGE_WEBMCP_CONFIG__);
