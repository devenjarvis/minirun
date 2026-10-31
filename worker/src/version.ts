/** The minirun release this Worker comes from. It must match MiniRun.version in Sources/MiniRunKit/Version.swift. */
export const VERSION = "0.2.0";

/** Compares dotted versions like "0.2.0" by number: negative if a is older than b. */
export function compareVersions(a: string, b: string): number {
  const pa = a.split(".").map((n) => parseInt(n, 10) || 0);
  const pb = b.split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}
