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
  var nextId = 0;

  // A second load (Turbo/SPA navigation re-running the script tag) would
  // otherwise collide on every tool name; drop the previous registration.
  if (root.portageWebMcp && typeof root.portageWebMcp.unregister === "function") root.portageWebMcp.unregister();
  root.portageWebMcp = state;

  // Current spec: `document.modelContext`. Earlier drafts, and the browser
  // builds that shipped them, used `navigator.modelContext`.
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
    try {
      var handle = context.registerTool(descriptor(tool), registerOptions());
      Promise.resolve(handle).then(function (resolved) {
        if (resolved && typeof resolved.unregister === "function") handles.push(resolved);
        state.registered.push(tool.name);
      }, function (error) {
        state.errors.push({ tool: tool.name, message: String((error && error.message) || error) });
      });
    } catch (error) {
      state.errors.push({ tool: tool.name, message: String((error && error.message) || error) });
    }
  }

  // Spec surface unregisters on the AbortSignal passed at registration;
  // earlier drafts returned a handle with `unregister()` or offered
  // `unregisterTool(name)`. All three are tried — each is a no-op where the
  // browser doesn't implement it.
  function unregister() {
    if (controller) controller.abort();
    handles.forEach(function (handle) { try { handle.unregister(); } catch (_e) { /* already gone */ } });
    if (typeof context.unregisterTool === "function") {
      config.tools.forEach(function (tool) { try { context.unregisterTool(tool.name); } catch (_e) { /* already gone */ } });
    }
    state.registered = [];
  }

  config.tools.forEach(register);
})(__PORTAGE_WEBMCP_CONFIG__);
