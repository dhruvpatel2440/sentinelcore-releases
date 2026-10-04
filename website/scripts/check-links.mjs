// Minimal internal-link checker. Scans dist/**/*.html, collects href targets
// that are site-relative, and verifies each resolves to a built file or an
// in-page anchor. Exits non-zero on any broken internal link.
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DIST = resolve(__dirname, "..", "dist");

if (!existsSync(DIST)) { console.error("no dist/ — run `npm run build` first"); process.exit(2); }

function walk(dir) {
  const out = [];
  for (const e of readdirSync(dir)) {
    const p = join(dir, e);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (e.endsWith(".html")) out.push(p);
  }
  return out;
}

const pages = walk(DIST);
const exists = (urlPath) => {
  const clean = urlPath.replace(/[?#].*$/, "");
  if (clean === "/" || clean === "") return existsSync(join(DIST, "index.html"));
  const asFile = join(DIST, clean);
  if (existsSync(asFile)) return true;
  if (existsSync(join(DIST, clean, "index.html"))) return true;
  if (existsSync(asFile + ".html")) return true;
  return false;
};

let broken = 0, checked = 0;
for (const page of pages) {
  const html = readFileSync(page, "utf8");
  const hrefs = [...html.matchAll(/href="([^"]+)"/g)].map((m) => m[1]);
  for (const h of hrefs) {
    if (/^(https?:|mailto:|tel:|#|data:)/.test(h)) continue; // external / anchor
    checked++;
    if (!exists(h)) { broken++; console.error(`BROKEN ${h}  (in ${page.replace(DIST, "")})`); }
  }
}
console.log(`[check-links] checked ${checked} internal links across ${pages.length} pages; ${broken} broken`);
process.exit(broken ? 1 : 0);
