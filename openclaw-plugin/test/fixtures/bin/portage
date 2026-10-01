#!/usr/bin/env node
// Test double for the portage CLI. Appends argv to $FAKE_PORTAGE_LOG (one JSON line per call)
// and behaves according to $FAKE_PORTAGE_MODE.
import { appendFileSync } from "node:fs";
const argv = process.argv.slice(2);
if (process.env.FAKE_PORTAGE_LOG) appendFileSync(process.env.FAKE_PORTAGE_LOG, JSON.stringify(argv) + "\n");
const mode = process.env.FAKE_PORTAGE_MODE ?? "ok";
if (argv[0] === "--version") {
  console.log(process.env.FAKE_PORTAGE_VERSION ?? "0.12.0");
  process.exit(0);
}
switch (mode) {
  case "garbage":
    console.log("not json at all");
    console.error("boom: something went wrong");
    process.exit(2);
  case "exit3json":
    console.log(JSON.stringify({ status: "needs_approval", argv }));
    process.exit(3);
  case "hang":
    setTimeout(() => {}, 60000);
    break;
  default:
    console.log(JSON.stringify({ ok: true, argv }));
}
