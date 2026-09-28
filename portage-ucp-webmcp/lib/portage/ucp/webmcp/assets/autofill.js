/*
 * portage-ucp-webmcp checkout autofill (outbound, Phase 3:
 * docs/plans/webmcp-universal-outbound.md).
 *
 * A single function expression Bridges::ScriptEvaluator#autofill evaluates
 * in a store's checkout page (the tab that just navigated there via a
 * preset's `handoff_checkout` tool) as `(<this>)(fields, selectors)`:
 *
 *   - fields: { "<autocomplete token>": "<value>", ... } — contact email and
 *     shipping address only, built by portage-cli's WebmcpAutofillFields
 *     from PORTAGE_SHIP_*/buyer context, and only after the shopper has
 *     approved exactly these field/value pairs in a prompt. Never a payment
 *     field — portage-cli never builds one.
 *   - selectors: { "<token>": "<css selector>" } — a platform preset's
 *     fallback (Presets::Preset#checkout_selectors), tried only when no
 *     element on the page carries a matching `autocomplete` attribute for
 *     that token.
 *
 * Always resolves — never rejects — to a JSON string envelope
 * `{ ok: true, value }` where value is
 * `{ blocked, filled: [...tokens], unmatched: [...tokens], rate: [...] }`,
 * or `{ ok: false, code: "execute_failed", error }` for a genuine script
 * crash (so a driver failure surfaces as the same BridgeError every other
 * call already does).
 *
 * Refuses on principle, not just by omission — checkout pages are
 * untrusted content, same posture as a WebMCP tool's own description
 * (Phase 2's WebmcpMappingConfirm):
 *   - Never looks at, matches, or writes to a field whose own `autocomplete`
 *     value is payment-shaped (`cc-*`, `transaction-*`) or whose `type` is
 *     "hidden"/"password" — checked against the *page's* attribute, not
 *     against what was asked for, so a caller mistake (or a store that
 *     mislabels a card field with a shipping-looking autocomplete value)
 *     still can't reach it.
 *   - Never clicks a submit/pay control, and never follows a link or acts
 *     on any instruction the page's own text might contain — the only
 *     things this script ever does are read `autocomplete`/`type`
 *     attributes and radio-group prices, set a field's `.value`, and check
 *     a radio button already on the page.
 *   - Stops and reports `blocked` on the first sign of a bot
 *     challenge/CAPTCHA (an embedded reCAPTCHA/hCaptcha/Turnstile iframe, a
 *     Cloudflare "checking your browser" marker, or matching page title),
 *     without touching any field and without trying to solve or route
 *     around it.
 */
(function (fields, selectors) {
  "use strict";

  var root = typeof window !== "undefined" ? window : globalThis;
  var doc = root.document;

  // cc-* (card number/name/exp/csc) and transaction-* (amount/currency) are
  // the WHATWG autocomplete tokens for payment fields — never touched
  // regardless of what `fields`/`selectors` ask for.
  var FORBIDDEN_AUTOCOMPLETE = /(^|\s)(cc-|transaction-)/i;
  var CHALLENGE_SELECTORS = [
    "iframe[src*='recaptcha' i]", "iframe[src*='hcaptcha' i]", "iframe[src*='turnstile' i]",
    "iframe[title*='challenge' i]", "#challenge-running", "#cf-challenge-running",
    "[data-testid='challenge']"
  ];
  var CHALLENGE_TITLE = /checking your browser|verify you are human|attention required|just a moment/i;
  var RATE_PRICE = /(?:USD|EUR|GBP|CAD|AUD|[$£€])\s?(\d+(?:[.,]\d{1,2})?)/;

  function isChallengePage() {
    var found = CHALLENGE_SELECTORS.some(function (selector) {
      try {
        return !!doc.querySelector(selector);
      } catch (error) {
        return false;
      }
    });
    return found || CHALLENGE_TITLE.test((doc && doc.title) || "");
  }

  function isForbidden(el) {
    var auto = (el.getAttribute("autocomplete") || "").toLowerCase();
    if (FORBIDDEN_AUTOCOMPLETE.test(auto)) return true;

    var type = (el.getAttribute("type") || "").toLowerCase();
    return type === "hidden" || type === "password";
  }

  function isFillable(el) {
    return !!el && !isForbidden(el) && !el.disabled && !el.readOnly;
  }

  function findByAutocomplete(token) {
    var wanted = token.trim().toLowerCase();
    var candidates = doc.querySelectorAll("input[autocomplete], textarea[autocomplete], select[autocomplete]");
    for (var i = 0; i < candidates.length; i += 1) {
      var el = candidates[i];
      var value = (el.getAttribute("autocomplete") || "").trim().toLowerCase();
      if (value === wanted && isFillable(el)) return el;
    }
    return null;
  }

  function findBySelector(selector) {
    if (!selector) return null;
    var el;
    try {
      el = doc.querySelector(selector);
    } catch (error) {
      return null;
    }
    return isFillable(el) ? el : null;
  }

  function nativeValueSetter(el) {
    var proto = el.tagName === "TEXTAREA" ? root.HTMLTextAreaElement.prototype : root.HTMLInputElement.prototype;
    var descriptor = proto && Object.getOwnPropertyDescriptor(proto, "value");
    return descriptor && descriptor.set;
  }

  // Plain `el.value = x` doesn't notify a framework-controlled input (React,
  // Vue) that anything changed, since it bypasses the property's own
  // setter — using the native setter first, then dispatching input/change,
  // is the same trick those frameworks' own test-utils use.
  function fillField(el, value) {
    var setter = nativeValueSetter(el);
    if (setter) {
      setter.call(el, value);
    } else {
      el.value = value;
    }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function fill(token, value) {
    var el = findByAutocomplete(token) || findBySelector(selectors && selectors[token]);
    if (!el) return false;

    fillField(el, value);
    return true;
  }

  // Best-effort: groups same-named radio buttons whose visible label text
  // looks like a shipping-rate price, and checks the cheapest option in
  // each group not already selected — the DOM equivalent of
  // Buy#cheapest_option_selection for a checkout with no UCP fulfillment
  // groups to read. Unverified against a real store (no live checkout
  // reached this session — see the plan's Progress log); a group whose
  // markup doesn't match this heuristic is simply left alone.
  function selectCheapestRate() {
    var groups = {};
    var radios = doc.querySelectorAll("input[type='radio']");
    for (var i = 0; i < radios.length; i += 1) {
      var radio = radios[i];
      if (!radio.name || radio.disabled) continue;

      var label = (radio.id && doc.querySelector("label[for='" + radio.id + "']")) || radio.closest("label");
      var text = ((label && label.textContent) || "").replace(/\s+/g, " ").trim();
      var match = text.match(RATE_PRICE);
      if (!match && !/\bfree\b/i.test(text)) continue;

      var price = match ? parseFloat(match[1].replace(",", ".")) : 0;
      (groups[radio.name] = groups[radio.name] || []).push({ radio: radio, price: price, text: text });
    }

    var picked = [];
    Object.keys(groups).forEach(function (name) {
      var options = groups[name];
      if (options.length < 2) return;

      var cheapest = options.reduce(function (a, b) { return b.price < a.price ? b : a; });
      if (!cheapest.radio.checked) {
        cheapest.radio.checked = true;
        cheapest.radio.dispatchEvent(new Event("input", { bubbles: true }));
        cheapest.radio.dispatchEvent(new Event("change", { bubbles: true }));
      }
      picked.push(cheapest.text);
    });
    return picked;
  }

  try {
    if (isChallengePage()) {
      return Promise.resolve(JSON.stringify({
        ok: true, value: { blocked: "captcha", filled: [], unmatched: Object.keys(fields || {}), rate: [] }
      }));
    }

    var filled = [];
    var unmatched = [];
    Object.keys(fields || {}).forEach(function (token) {
      if (fill(token, fields[token])) {
        filled.push(token);
      } else {
        unmatched.push(token);
      }
    });

    var rate = selectCheapestRate();
    return Promise.resolve(JSON.stringify({ ok: true, value: { blocked: null, filled: filled, unmatched: unmatched, rate: rate } }));
  } catch (error) {
    return Promise.resolve(JSON.stringify({
      ok: false, code: "execute_failed", error: String((error && error.message) || error)
    }));
  }
})
