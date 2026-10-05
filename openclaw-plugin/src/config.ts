export interface PortageConfig {
  portageBin: string;
  timeoutSeconds: number;
}

const DEFAULT_CONFIG: PortageConfig = { portageBin: "portage", timeoutSeconds: 120 };

/** Reads plugin config defensively; invalid values fall back to defaults. */
export function resolveConfig(raw: Record<string, unknown> | undefined): PortageConfig {
  const bin = raw?.portageBin;
  const timeout = raw?.timeoutSeconds;
  return {
    portageBin: typeof bin === "string" && bin.trim() !== "" ? bin : DEFAULT_CONFIG.portageBin,
    timeoutSeconds:
      typeof timeout === "number" && Number.isFinite(timeout) && timeout > 0
        ? timeout
        : DEFAULT_CONFIG.timeoutSeconds,
  };
}
