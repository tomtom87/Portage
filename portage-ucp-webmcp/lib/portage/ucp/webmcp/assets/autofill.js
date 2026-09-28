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
 *     from the PORTAGE_SHIP_* variables and buyer context, and only after
 *     the shopper has approved exactly these field/value pairs in a prompt.
 *     Never a payment field — portage-cli never builds one.
 *     (No glob-then-slash in this comment: that pair closes it early, which
 *     is how this file once shipped unparseable — see design-log §51.)
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
  // A rate's price: any currency symbol (Unicode \p{Sc}: $ £ € ฿ ¥ ₹ …) or a
  // three-letter ISO code, before or after the amount ("£50.00", "฿1,950.00",
  // "THB 1,950.00", "12,50 €"). The amount allows thousands separators (a
  // comma, a dot, or the no-break spaces some locales use), so
  // "฿1,950.00" reads as 1950, not 1.95. Checkout currency follows the
  // shopper's geo-IP until an address is filled (design-log §50 saw THB on a
  // UK store), so no fixed list of currencies is enough.
  var AMOUNT = "(\\d{1,3}(?:[.,\\u00a0\\u202f]\\d{3})+(?:[.,]\\d{1,2})?|\\d+(?:[.,]\\d{1,2})?)";
  var CURRENCY = "(?:\\p{Sc}|(?<![A-Za-z])[A-Z]{3}(?![A-Za-z]))";
  var RATE_PRICE = new RegExp(CURRENCY + "\\s?" + AMOUNT + "|" + AMOUNT + "\\s?" + CURRENCY, "u");

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
    var ctor = { TEXTAREA: root.HTMLTextAreaElement, SELECT: root.HTMLSelectElement }[el.tagName] ||
      root.HTMLInputElement;
    var proto = ctor && ctor.prototype;
    var descriptor = proto && Object.getOwnPropertyDescriptor(proto, "value");
    return descriptor && descriptor.set;
  }

  // A <select> only takes one of its own options' values: an exact option
  // value first ("GB"), then the option's visible text, case-insensitive and
  // trimmed ("United Kingdom"). null when neither matches, so the token is
  // reported unmatched instead of leaving the select blank.
  function selectOptionValue(el, value) {
    var options = el.options || [];
    var wanted = String(value).trim().toLowerCase();
    var i;
    for (i = 0; i < options.length; i += 1) {
      if (options[i].value === String(value)) return options[i].value;
    }
    for (i = 0; i < options.length; i += 1) {
      if ((options[i].text || options[i].textContent || "").trim().toLowerCase() === wanted) return options[i].value;
    }
    return null;
  }

  // Plain `el.value = x` doesn't notify a framework-controlled input (React,
  // Vue) that anything changed, since it bypasses the property's own
  // setter — using the native setter first, then dispatching input/change,
  // is the same trick those frameworks' own test-utils use.
  function fillField(el, value) {
    if (el.tagName === "SELECT") {
      value = selectOptionValue(el, value);
      if (value === null) return false;
    }

    var setter = nativeValueSetter(el);
    if (setter) {
      setter.call(el, value);
    } else {
      el.value = value;
    }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return true;
  }

  function fill(token, value) {
    var el = findByAutocomplete(token) || findBySelector(selectors && selectors[token]);
    return !!el && fillField(el, value);
  }

  // "1,950.00" / "1.950,00" / "1 950" -> 1950; "12,50" -> 12.5. A trailing
  // separator with one or two digits after it is the decimal point; every
  // other separator groups thousands.
  function parseAmount(raw) {
    var digits = raw.replace(/[\u00a0\u202f]/g, "");
    var decimal = digits.match(/[.,](\d{1,2})$/);
    var whole = decimal ? digits.slice(0, -decimal[0].length) : digits;
    return parseFloat(whole.replace(/[.,]/g, "") + (decimal ? "." + decimal[1] : ""));
  }

  // Best-effort: groups same-named radio buttons whose visible label text
  // looks like a shipping-rate price, and checks the cheapest option in
  // each group not already selected — the DOM equivalent of
  // Buy#cheapest_option_selection for a checkout with no UCP fulfillment
  // groups to read. Only a single-rate Shopify checkout has been seen live
  // (design-log §50/§51): it renders no radio at all, so there's nothing to
  // pick. Multi-rate markup is still unverified; a group whose markup
  // doesn't match this heuristic is simply left alone.
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

      var price = match ? parseAmount(match[1] || match[2]) : 0;
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
