# SentinelCore website

Static marketing + docs site (Astro, no backend). Deployable to Netlify, Vercel,
Cloudflare Pages, or any static host.

## Develop
```bash
cd website
npm install
npm run dev        # http://localhost:4321
```

## Build
```bash
npm run build      # runs sync-release, then astro build -> dist/
npm run preview    # serve the built site locally
npm run check-links  # verify internal links in dist/
```

## Design
The visual system (neobrutalism + glassmorphism) is derived from the product's
own design tokens and lives in `src/styles/tokens.css`. If a Foundations/
Components design sheet is placed in the repo's `design/` folder, re-derive the
tokens from it and update `tokens.css` only.

## Release data / download button
The **Download** button points at `DOWNLOAD_URL` (build-time env) and shows the
version, size and SHA-256 pulled from the release build output:

```bash
DOWNLOAD_URL=https://downloads.sentinelcore.app \
SITE_URL=https://sentinelcore.app \
npm run build
```

`scripts/sync-release.mjs` reads `../dist/sentinelcore-<version>.zip.sha256`
(produced by `build/build-release.sh`) and writes `src/data/release.json`. With
no `dist/` present it keeps the last values (or placeholders) so the site always
builds. No secrets are ever embedded, and nothing links to the private source repo.

## Deploy
- **Netlify / Cloudflare Pages:** build command `npm run build`, publish dir
  `dist`. `public/_headers` applies the CSP and security headers.
- **Vercel:** framework preset “Astro”, output `dist`.
- Set `SITE_URL` and `DOWNLOAD_URL` as build env vars.

## Extras
- SEO meta + OpenGraph on every page, `public/sitemap.xml`, `public/robots.txt`,
  a 404 page, and `public/_headers` (CSP, X-Content-Type-Options, Referrer-Policy,
  X-Frame-Options, Permissions-Policy, HSTS).
- No analytics or trackers.
