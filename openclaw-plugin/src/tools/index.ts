import { buyingTools } from "./buying.js";
import { indexTools } from "./indexing.js";
import { readonlyTools } from "./readonly.js";
import type { ToolSpec } from "./types.js";

export const allTools: ToolSpec[] = [...readonlyTools, ...buyingTools, ...indexTools];
export type { ToolSpec } from "./types.js";
