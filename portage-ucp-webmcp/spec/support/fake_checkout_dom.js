// A checkout page just big enough for assets/autofill.js, evaluated in a
// spec/support/node_browser.js tab before the real script runs. It gives
// autofill.js exactly what it touches in a browser — document.querySelector/
// querySelectorAll over the handful of selector shapes it and a preset's
// checkout_selectors use, getAttribute, closest("label"), the
// HTMLInputElement/HTMLTextAreaElement/HTMLSelectElement value setters, and
// dispatchEvent — and nothing else. No jsdom: no npm dependency for one spec.
//
//   FakeCheckout.install({ title, elements: [{ tag, attrs, text, options, children }] })
//   FakeCheckout.snapshot() // => [{ tag, attrs, value, checked, events }]
"use strict";

(function () {
  var all = [];

  function FakeElement(spec, parent) {
    this.tagName = spec.tag.toUpperCase();
    this.attrs = spec.attrs || {};
    this.parent = parent || null;
    this.events = [];
    this.disabled = "disabled" in this.attrs;
    this.readOnly = "readonly" in this.attrs;
    this.checked = "checked" in this.attrs;
    this.textContent = spec.text || "";
    this.options = (spec.options || []).map(function (option) {
      return { value: option.value, text: option.text, textContent: option.text };
    });
    this._value = this.attrs.value || (this.options[0] && this.options[0].value) || "";
  }
  FakeElement.prototype.getAttribute = function (name) {
    return Object.prototype.hasOwnProperty.call(this.attrs, name) ? String(this.attrs[name]) : null;
  };
  Object.defineProperty(FakeElement.prototype, "id", { get: function () { return this.attrs.id || ""; } });
  Object.defineProperty(FakeElement.prototype, "name", { get: function () { return this.attrs.name || ""; } });
  FakeElement.prototype.dispatchEvent = function (event) {
    this.events.push(event.type);
    return true;
  };
  FakeElement.prototype.closest = function (selector) {
    for (var el = this; el; el = el.parent) if (matches(el, selector)) return el;
    return null;
  };

  // Real value setters live on the element's own prototype, so autofill.js's
  // "use the native setter" path is the one exercised. A select's setter
  // only takes one of its own options' values, like a browser's, and
  // calling one element type's setter on another throws, as it does in
  // Chrome ("Illegal invocation").
  function defineValue(ctor, set) {
    Object.defineProperty(ctor.prototype, "value", {
      get: function () { return this._value; },
      set: function (v) {
        if (!(this instanceof ctor)) throw new TypeError("Illegal invocation");
        set.call(this, v);
      },
      configurable: true
    });
  }
  function assign(v) { this._value = String(v); }
  function HTMLInputElement() {}
  HTMLInputElement.prototype = Object.create(FakeElement.prototype);
  defineValue(HTMLInputElement, assign);
  function HTMLTextAreaElement() {}
  HTMLTextAreaElement.prototype = Object.create(FakeElement.prototype);
  defineValue(HTMLTextAreaElement, assign);
  function HTMLSelectElement() {}
  HTMLSelectElement.prototype = Object.create(FakeElement.prototype);
  defineValue(HTMLSelectElement, function (v) {
    var hit = this.options.some(function (option) { return option.value === String(v); });
    this._value = hit ? String(v) : "";
  });

  var PROTOS = { INPUT: HTMLInputElement, TEXTAREA: HTMLTextAreaElement, SELECT: HTMLSelectElement };

  function build(spec, parent) {
    var ctor = PROTOS[spec.tag.toUpperCase()];
    var el = Object.create(ctor ? ctor.prototype : FakeElement.prototype);
    FakeElement.call(el, spec, parent);
    all.push(el);
    (spec.children || []).forEach(function (child) {
      var built = build(child, el);
      el.textContent += " " + built.textContent;
    });
    return el;
  }

  // tag, #id and [attr], [attr='v'], [attr*='v' i] — every shape autofill.js
  // and Presets::SHOPIFY.checkout_selectors use. Anything else throws, like
  // an invalid selector does in a browser.
  var COMPOUND = /^([a-z]+)?(?:#([\w-]+))?((?:\[[^\]]+\])*)$/i;
  var ATTR = /\[\s*([\w-]+)\s*(?:(\*?=)\s*(['"])(.*?)\3\s*(i)?)?\s*\]/g;

  function parse(selector) {
    return selector.split(",").map(function (part) {
      var m = part.trim().match(COMPOUND);
      if (!m) throw new SyntaxError("unsupported selector: " + selector);
      var attrs = [];
      m[3].replace(ATTR, function (_all, name, op, _q, value, flag) {
        attrs.push({ name: name, op: op, value: value, insensitive: !!flag });
      });
      return { tag: m[1] && m[1].toUpperCase(), id: m[2], attrs: attrs };
    });
  }

  function matches(el, selector) {
    return parse(selector).some(function (c) {
      if (c.tag && c.tag !== el.tagName) return false;
      if (c.id && c.id !== el.id) return false;
      return c.attrs.every(function (a) {
        var actual = el.getAttribute(a.name);
        if (actual === null) return false;
        if (!a.op) return true;
        var have = a.insensitive ? actual.toLowerCase() : actual;
        var want = a.insensitive ? a.value.toLowerCase() : a.value;
        return a.op === "=" ? have === want : have.indexOf(want) !== -1;
      });
    });
  }

  globalThis.HTMLInputElement = HTMLInputElement;
  globalThis.HTMLTextAreaElement = HTMLTextAreaElement;
  globalThis.HTMLSelectElement = HTMLSelectElement;

  globalThis.FakeCheckout = {
    install: function (page) {
      all = [];
      (page.elements || []).forEach(function (spec) { build(spec, null); });
      globalThis.document = {
        title: page.title || "Checkout",
        querySelectorAll: function (selector) {
          parse(selector);
          return all.filter(function (el) { return matches(el, selector); });
        },
        querySelector: function (selector) { return this.querySelectorAll(selector)[0] || null; }
      };
      return true;
    },
    snapshot: function () {
      return all.map(function (el) {
        return { tag: el.tagName.toLowerCase(), attrs: el.attrs, value: el._value, checked: el.checked,
                 events: el.events };
      });
    }
  };
})();
