// Builds the Worker into dist/ so the Mac can deploy it without node: `minirun worker deploy`
// uploads dist/index.js through the Cloudflare API, configured by dist/manifest.json.
// wrangler.jsonc stays the one place the Worker's settings live; this copies what the upload needs.
//
//   npm run bundle
//
// dist/ is committed. CI runs this and fails if the result differs from what's checked in.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { experimental_readRawConfig } from "wrangler";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(root, "dist");
const out = mkdtempSync(join(tmpdir(), "minirun-bundle-"));

try {
  execFileSync("npx", ["wrangler", "deploy", "--dry-run", "--outdir", out], { cwd: root, stdio: ["ignore", "ignore", "inherit"] });
  const code = readFileSync(join(out, "index.js"));
  const { rawConfig: config } = experimental_readRawConfig({ config: join(root, "wrangler.jsonc") });

  const manifest = {
    name: config.name,
    mainModule: "index.js",
    bundleHash: createHash("sha256").update(code).digest("hex"),
    compatibilityDate: config.compatibility_date,
    compatibilityFlags: config.compatibility_flags ?? [],
    observability: config.observability ?? null,
    durableObjects: (config.durable_objects?.bindings ?? []).map(({ name, class_name }) => ({ binding: name, className: class_name })),
    kvNamespaces: (config.kv_namespaces ?? []).map(({ binding }) => binding),
    // Durable Object migrations, oldest first, exactly as wrangler.jsonc lists them.
    migrations: config.migrations ?? [],
  };

  mkdirSync(dist, { recursive: true });
  writeFileSync(join(dist, "index.js"), code);
  writeFileSync(join(dist, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  console.log(`dist/index.js ${(code.length / 1024).toFixed(0)} KiB, ${manifest.bundleHash.slice(0, 12)}`);
} finally {
  rmSync(out, { recursive: true, force: true });
}
