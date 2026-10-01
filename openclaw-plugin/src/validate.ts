export class InputError extends Error {}

const MAX_STR = 1000;

/** Free text or identifier passed as an option value or positional: non-empty, never flag-shaped. */
export function str(name: string, v: unknown, max = MAX_STR): string {
  if (typeof v !== "string") throw new InputError(`${name} must be a string`);
  const s = v.trim();
  if (s === "") throw new InputError(`${name} must not be empty`);
  if (s.length > max) throw new InputError(`${name} is too long (max ${max} characters)`);
  if (s.startsWith("-")) throw new InputError(`${name} must not start with "-"`);
  if (s.includes("\0")) throw new InputError(`${name} contains an invalid character`);
  return s;
}

export function optStr(name: string, v: unknown, max?: number): string | undefined {
  return v === undefined ? undefined : str(name, v, max);
}

export function httpUrl(name: string, v: unknown): string {
  const s = str(name, v, 2000);
  let u: URL;
  try {
    u = new URL(s);
  } catch {
    throw new InputError(`${name} must be an absolute http(s) URL`);
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") throw new InputError(`${name} must be an http(s) URL`);
  return s;
}

export function posInt(name: string, v: unknown): number | undefined {
  if (v === undefined) return undefined;
  if (typeof v !== "number" || !Number.isInteger(v) || v <= 0) throw new InputError(`${name} must be a positive integer`);
  return v;
}

export function posNum(name: string, v: unknown): number | undefined {
  if (v === undefined) return undefined;
  if (typeof v !== "number" || !Number.isFinite(v) || v <= 0) throw new InputError(`${name} must be a positive number`);
  return v;
}

export function oneOf<T extends string>(name: string, v: unknown, allowed: readonly T[]): T | undefined {
  if (v === undefined) return undefined;
  if (typeof v !== "string" || !(allowed as readonly string[]).includes(v)) {
    throw new InputError(`${name} must be one of: ${allowed.join(", ")}`);
  }
  return v as T;
}

/** Pushes `flag value` when value is defined. */
export function opt(args: string[], flag: string, value: string | number | undefined): void {
  if (value !== undefined) args.push(flag, String(value));
}
