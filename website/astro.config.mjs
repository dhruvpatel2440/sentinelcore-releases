import { defineConfig } from "astro/config";

// Static site. SITE_URL / DOWNLOAD_URL are build-time env (see README).
export default defineConfig({
  site: process.env.SITE_URL || "https://sentinelcore.app",
  build: { assets: "_assets" },
  compressHTML: true,
});
