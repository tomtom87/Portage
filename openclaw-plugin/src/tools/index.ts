import { readonlyTools } from "./readonly.js";
import type { ToolSpec } from "./types.js";

export const allTools: ToolSpec[] = [...readonlyTools];
export type { ToolSpec } from "./types.js";
