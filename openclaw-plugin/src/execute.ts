import type { Runner } from "./runner.js";
import { InputError } from "./validate.js";
import type { ToolSpec } from "./tools/types.js";

export interface ToolResult {
  content: { type: "text"; text: string }[];
  details: unknown;
}

function errorResult(message: string): ToolResult {
  return { content: [{ type: "text", text: `Error: ${message}` }], details: { error: message } };
}

/** Validates, runs the CLI, and shapes the result. Never throws. */
export async function runTool(runner: Runner, spec: ToolSpec, params: unknown): Promise<ToolResult> {
  let args: string[];
  let timeoutSeconds: number | undefined;
  try {
    const input = (params ?? {}) as Record<string, unknown>;
    args = spec.buildArgs(input);
    timeoutSeconds = spec.timeoutFor?.(input) ?? spec.timeoutSeconds;
  } catch (e) {
    return errorResult(e instanceof InputError || e instanceof Error ? `invalid input: ${e.message}` : "invalid input");
  }
  const r = await runner.run(args, { timeoutSeconds });
  if (!r.ok) return errorResult(r.message);
  return { content: [{ type: "text", text: JSON.stringify(r.data) }], details: r.data };
}
