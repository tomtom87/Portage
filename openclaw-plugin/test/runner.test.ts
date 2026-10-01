import { existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { createRunner, parseVersion, versionAtLeast } from "../src/runner.js";
import { setup } from "./helpers.js";

describe("runner", () => {
  it("passes the argv array through and parses JSON", async () => {
    const s = setup();
    const r = await s.runner.run(["find", "--query", "a b", "--json"]);
    expect(r).toMatchObject({ ok: true, exitCode: 0 });
    expect(s.calls()).toEqual([["find", "--query", "a b", "--json"]]);
  });

  it("never uses a shell: metacharacters arrive verbatim and run nothing", async () => {
    const s = setup();
    const marker = join(s.dir, "pwned");
    const nasty = `x; touch ${marker} #`;
    const nasty2 = "$(touch " + marker + ")";
    await s.runner.run(["find", "--query", nasty, nasty2, "`id`", "--json"]);
    expect(s.calls()[0]).toEqual(["find", "--query", nasty, nasty2, "`id`", "--json"]);
    expect(existsSync(marker)).toBe(false);
  });

  it("treats non-zero exit with valid JSON as a normal result", async () => {
    const s = setup({ FAKE_PORTAGE_MODE: "exit3json" });
    const r = await s.runner.run(["approve", "q1", "--json"]);
    expect(r).toMatchObject({ ok: true, exitCode: 3 });
    if (r.ok) expect((r.data as { status: string }).status).toBe("needs_approval");
  });

  it("errors on unparseable output and includes the stderr tail", async () => {
    const s = setup({ FAKE_PORTAGE_MODE: "garbage" });
    const r = await s.runner.run(["doctor", "--json"]);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/without valid JSON.*boom/s);
  });

  it("errors on spawn failure with a helpful message", async () => {
    const runner = createRunner({ portageBin: "/nonexistent/portage", timeoutSeconds: 5 });
    const r = await runner.run(["doctor", "--json"]);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/not found/);
  });

  it("times out", async () => {
    const s = setup({ FAKE_PORTAGE_MODE: "hang" });
    const r = await s.runner.run(["doctor", "--json"], { timeoutSeconds: 0.5 });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/timed out/);
  });

  it("refuses an old CLI and runs nothing else", async () => {
    const s = setup({ FAKE_PORTAGE_VERSION: "0.11.9" });
    const r = await s.runner.run(["doctor", "--json"]);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/too old.*0\.12\.0/);
    expect(s.calls()).toEqual([]);
  });

  it("caches a passing version check", async () => {
    const s = setup({ FAKE_PORTAGE_VERSION: "0.13.1" });
    await s.runner.run(["doctor", "--json"]);
    await s.runner.run(["doctor", "--json"]);
    expect(s.versionCalls()).toBe(1);
  });

  it("compares versions numerically", () => {
    expect(versionAtLeast(parseVersion("0.12.0")!, "0.12.0")).toBe(true);
    expect(versionAtLeast(parseVersion("0.9.9")!, "0.12.0")).toBe(false);
    expect(versionAtLeast(parseVersion("1.0.0")!, "0.12.0")).toBe(true);
    expect(parseVersion("portage 0.12.0\n")).toEqual([0, 12, 0]);
  });
});
