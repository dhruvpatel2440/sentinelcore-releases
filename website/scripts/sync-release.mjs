// Generates src/data/release.json from the build output in ../dist.
// Reads dist/sentinelcore-<version>.zip.sha256 (produced by build/build-release.sh)
// and the zip size. Safe to run with no dist/ present — it keeps the existing
// release.json (or writes sensible placeholders), so the site always builds.
import { readFileSync, writeFileSync, existsSync, statSync, readdirSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");
const DIST = resolve(ROOT, "..", "dist");
const OUT = join(ROOT, "src", "data", "release.json");

const DOWNLOAD_URL = process.env.DOWNLOAD_URL || "https://downloads.sentinelcore.app";

function human(bytes) {
  if (!bytes) return "unknown";
  const u = ["B", "KB", "MB", "GB"];
  let i = 0, n = bytes;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(n < 10 && i > 0 ? 1 : 0)} ${u[i]}`;
}

function discover() {
  if (!existsSync(DIST)) return null;
  // Never publish TEST builds (build-release.sh names them *-TEST.zip).
  const sums = readdirSync(DIST).filter((f) => /^sentinelcore-.*\.zip\.sha256$/.test(f) && !/-TEST\.zip\.sha256$/.test(f));
  if (sums.length === 0) return null;
  // Pick the most recently modified checksum file.
  sums.sort((a, b) => statSync(join(DIST, b)).mtimeMs - statSync(join(DIST, a)).mtimeMs);
  const sumFile = sums[0];
  const line = readFileSync(join(DIST, sumFile), "utf8").trim();
  const [sha, nameRaw] = line.split(/\s+/);
  const name = (nameRaw || sumFile.replace(/\.sha256$/, "")).replace(/^\*/, "");
  const version = (name.match(/sentinelcore-(.+)\.zip$/) || [])[1] || "unknown";
  const zipPath = join(DIST, name);
  const size = existsSync(zipPath) ? human(statSync(zipPath).size) : "unknown";
  const date = existsSync(zipPath)
    ? new Date(statSync(zipPath).mtimeMs).toISOString().slice(0, 10)
    : new Date().toISOString().slice(0, 10);
  return { version, sha256: sha, filename: name, size, date };
}

const found = discover();
const existing = existsSync(OUT) ? JSON.parse(readFileSync(OUT, "utf8")) : {};

const data = {
  version: found?.version || existing.version || "0.0.0",
  sha256: found?.sha256 || existing.sha256 || "0000000000000000000000000000000000000000000000000000000000000000",
  filename: found?.filename || existing.filename || "sentinelcore-0.0.0.zip",
  size: found?.size || existing.size || "unknown",
  date: found?.date || existing.date || new Date().toISOString().slice(0, 10),
  downloadUrl: `${DOWNLOAD_URL.replace(/\/$/, "")}/${found?.filename || existing.filename || "sentinelcore-0.0.0.zip"}`,
  source: found ? "dist" : "placeholder",
};

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, JSON.stringify(data, null, 2) + "\n");
console.log(`[sync-release] ${data.source}: ${data.filename} (${data.size}) sha256=${data.sha256.slice(0, 12)}…`);
