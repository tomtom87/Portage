// Stand-in for a browser tab, driven by spec/support/node_browser.rb over
// newline-delimited JSON on stdin/stdout. It gives the page scripts exactly
// what they touch in a browser — window/document/navigator/location and
// fetch — and nothing else, so registrar.js, consumer.js and polyfill.js run
// unmodified. `fetch` is relayed back to Ruby, which answers it from a Rack
// app, so a tool call really does travel page -> endpoint -> Mcp::Server.
"use strict";

const readline = require("readline");

globalThis.window = globalThis;
globalThis.document = {};
globalThis.location = { origin: process.env.PAGE_ORIGIN || "https://shop.example" };
if (typeof globalThis.navigator === "undefined") globalThis.navigator = {};

const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");
const pending = new Map();
let nextFetch = 0;

globalThis.fetch = (url, init = {}) => {
  const id = ++nextFetch;
  send({
    type: "fetch", id, url: String(url), method: init.method || "GET",
    headers: init.headers || {}, credentials: init.credentials || null, body: init.body || null
  });
  return new Promise((resolve) => pending.set(id, resolve)).then((response) => ({
    status: response.status,
    ok: response.status >= 200 && response.status < 300,
    json: () => Promise.resolve(JSON.parse(response.body)),
    text: () => Promise.resolve(response.body)
  }));
};

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  if (message.type === "fetch_response") {
    pending.get(message.id)(message);
    pending.delete(message.id);
    return;
  }
  if (message.type === "eval") {
    Promise.resolve()
      .then(() => (0, eval)(message.source))
      .then(
        (value) => send({ type: "result", id: message.id, value: value === undefined ? null : value }),
        (error) => send({ type: "error", id: message.id, message: String((error && error.stack) || error) })
      );
  }
});
