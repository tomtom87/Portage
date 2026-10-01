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

/** CLI-minted ids and refs (`qt_...`, `of_...`, `se_...`, `LAST`): one token, never flag-shaped. */
export function ident(name: string, v: unknown): string {
  const s = str(name, v, 100);
  if (!/^[A-Za-z0-9_.:]+$/.test(s)) throw new InputError(`${name} must be a plain identifier`);
  return s;
}

/** A bare host name such as `shop.example` (no scheme, path, port or spaces). */
export function hostName(name: string, v: unknown): string {
  const s = str(name, v, 253);
  if (!/^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(s)) throw new InputError(`${name} must be a host name such as shop.example`);
  return s;
}

/** `45s`, `30m` or `1h`. */
export function duration(name: string, v: unknown): string | undefined {
  if (v === undefined) return undefined;
  if (typeof v !== "string" || !/^[1-9]\d{0,5}[smh]$/.test(v)) throw new InputError(`${name} must look like 45s, 30m or 1h`);
  return v;
}

/** Strict boolean: only `true` or `false` (or absent) is accepted, never a truthy string. */
export function flag(name: string, v: unknown): boolean {
  if (v === undefined) return false;
  if (typeof v !== "boolean") throw new InputError(`${name} must be true or false`);
  return v;
}

/** An array of at most `max` strings, each checked by `each`. */
export function list(name: string, v: unknown, each: (n: string, x: unknown) => string, max = 50): string[] | undefined {
  if (v === undefined) return undefined;
  if (!Array.isArray(v)) throw new InputError(`${name} must be an array`);
  if (v.length === 0) throw new InputError(`${name} must not be empty`);
  if (v.length > max) throw new InputError(`${name} has too many entries (max ${max})`);
  return v.map((x, i) => each(`${name}[${i}]`, x));
}
