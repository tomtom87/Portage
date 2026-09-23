/*
 * portage-ucp-webmcp polyfill.
 *
 * Installs a minimal, spec-shaped ModelContext (`registerTool` with an
 * AbortSignal, `getTools`, `executeTool`, plus the older `unregisterTool`)
 * on `document.modelContext` and `navigator.modelContext` — only when the
 * browser has neither. Two uses:
 *
 *   - Agent side: inject it as an init script (Playwright `add_init_script`,
 *     Ferrum `evaluate_on_new_document`, CDP
 *     `Page.addScriptToEvaluateOnNewDocument`) so a page that registers
 *     WebMCP tools still has them discoverable in a browser build without
 *     native WebMCP.
 *   - Merchant side: prepend it to the registrar (`include_polyfill: true`)
 *     for agents that drive such a browser.
 *
 * It is not a security boundary and does nothing a page's own script
 * couldn't; when a native implementation exists it is left untouched.
 */
(function () {
  "use strict";

  var root = typeof window !== "undefined" ? window : globalThis;
  var doc = root.document;
  var nav = root.navigator;
  if ((doc && doc.modelContext) || (nav && nav.modelContext)) return;

  var NAME = /^[A-Za-z0-9_.-]{1,128}$/;
  var tools = new Map();
  var listeners = {};

  function emit(type, detail) {
    (listeners[type] || []).slice().forEach(function (listener) {
      try { listener({ type: type, toolName: detail }); } catch (_e) { /* listener's own problem */ }
    });
  }

  function origin() {
    return (root.location && root.location.origin) || null;
  }

  function remove(name) {
    if (tools.delete(name)) emit("toolchange", name);
  }

  var modelContext = {
    registerTool: function (tool, options) {
      if (!tool || !NAME.test(String(tool.name))) return Promise.reject(new TypeError("invalid tool name"));
      if (!tool.description) return Promise.reject(new TypeError("tool description is required"));
      if (typeof tool.execute !== "function") return Promise.reject(new TypeError("tool execute must be a function"));
      if (tools.has(tool.name)) return Promise.reject(new Error("tool already registered: " + tool.name));

      var signal = options && options.signal;
      if (signal && signal.aborted) return Promise.resolve();
      tools.set(tool.name, tool);
      if (signal) signal.addEventListener("abort", function () { remove(tool.name); });
      emit("toolchange", tool.name);
      return Promise.resolve();
    },

    unregisterTool: function (name) { remove(name); },

    getTools: function () {
      return Promise.resolve(Array.from(tools.values()).map(function (tool) {
        return {
          name: tool.name,
          title: tool.title,
          description: tool.description,
          inputSchema: tool.inputSchema || {},
          annotations: tool.annotations || {},
          origin: origin()
        };
      }));
    },

    // Resolves to a string, like the spec's `Promise<DOMString>`.
    executeTool: function (registered, input, options) {
      var name = typeof registered === "string" ? registered : registered && registered.name;
      var tool = tools.get(name);
      if (!tool) return Promise.reject(new Error("tool not registered: " + name));

      var signal = (options && options.signal) ||
        (typeof AbortController === "function" ? new AbortController().signal : undefined);
      emit("toolactivated", name);
      return Promise.resolve(tool.execute(input || {}, { signal: signal })).then(function (value) {
        return typeof value === "string" ? value : JSON.stringify(value === undefined ? null : value);
      });
    },

    addEventListener: function (type, listener) {
      (listeners[type] = listeners[type] || []).push(listener);
    },

    removeEventListener: function (type, listener) {
      listeners[type] = (listeners[type] || []).filter(function (l) { return l !== listener; });
    }
  };

  function install(target) {
    if (!target) return;
    try {
      Object.defineProperty(target, "modelContext", { value: modelContext, configurable: true });
    } catch (_e) { /* frozen host object; the other target still gets it */ }
  }

  install(doc);
  install(nav);
  root.__portageWebMcpPolyfill = true;
})();
