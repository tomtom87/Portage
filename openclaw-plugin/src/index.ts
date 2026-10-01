import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { resolveConfig } from "./config.js";
import { runTool } from "./execute.js";
import { createRunner } from "./runner.js";
import { allTools } from "./tools/index.js";

export default definePluginEntry({
  id: "portage",
  name: "Portage",
  description:
    "Search, compare and buy from online stores through the Portage CLI, with spending policy and per-payment approval enforced by Portage itself.",
  register(api) {
    const runner = createRunner(resolveConfig(api.pluginConfig));
    for (const spec of allTools) {
      api.registerTool(
        {
          name: spec.name,
          label: spec.name,
          description: spec.description,
          parameters: spec.parameters,
          ...(spec.outputSchema ? { outputSchema: spec.outputSchema } : {}),
          async execute(_toolCallId: string, params: unknown) {
            return runTool(runner, spec, params);
          },
        },
        { name: spec.name, optional: spec.optional === true },
      );
    }
  },
});
