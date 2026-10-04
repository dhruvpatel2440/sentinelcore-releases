#!/usr/bin/env bash
# build-release.sh — produce dist/sentinelcore-<version>.zip (+ .sha256)
# containing ONLY what customers need. SOURCE_DIR is read-only; images are
# built from a filtered COPY.
#
# Usage:
#   build/build-release.sh <version> [options]
#
# Options:
#   --source <dir>              SOURCE_DIR (default: $SOURCE_DIR env, else
#                               ../SentinelCore; a single nested checkout such
#                               as ../SentinelCore/Sentinelcore-main is found).
#   --allow-placeholder-relay   Allow RELAY_URL in build/product.conf to still
#                               be the placeholder. Produces a TEST BUILD.
#   --skip-images               Packaging test only: no images, no frontend.
#                               Produces a TEST BUILD (NOT installable).
#   --sign                      GPG-sign the final zip (<zip>.asc).
#   -h | --help                 This help.
#
# A real release (no test flags) FAILS unless: every image referenced by the
# release compose is built/pulled and saved into
# images/sentinelcore-images-<version>.tar.gz, frontend-dist/index.html
# exists, and RELAY_URL is a real (non-placeholder) URL.
# Test builds are written as dist/sentinelcore-<version>-TEST.zip and their
# README is marked "TEST BUILD".
#
# Deterministic & idempotent: build/work/ is wiped at start. Everything under
# dist/ and build/work/ is gitignored.
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_DIR="$(cd "$BUILD_DIR/.." && pwd)"
WORK="$BUILD_DIR/work"
SRC_COPY="$WORK/src"
STAGE_ROOT="$WORK/stage"
OVERLAY="$BUILD_DIR/overlay"
DIST="$RELEASE_DIR/dist"
PLACEHOLDER_RELAY="relay.sentinelcore.app"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
VERSION=""
SOURCE_DIR="${SOURCE_DIR:-$RELEASE_DIR/../SentinelCore}"
SKIP_IMAGES=0
ALLOW_PLACEHOLDER_RELAY=0
DO_SIGN=0

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE_DIR="${2:?}"; shift 2 ;;
        --skip-images) SKIP_IMAGES=1; shift ;;
        --allow-placeholder-relay) ALLOW_PLACEHOLDER_RELAY=1; shift ;;
        --sign) DO_SIGN=1; shift ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) if [ -z "$VERSION" ]; then VERSION="$1"; else die "unexpected arg: $1"; fi; shift ;;
    esac
done

[ -n "$VERSION" ] || die "version required (e.g. build/build-release.sh 1.0.1)"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$' \
    || die "version '$VERSION' is not X.Y.Z[-suffix]"

SOURCE_DIR="$(cd "$SOURCE_DIR" 2>/dev/null && pwd || true)"
[ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ] || die "SOURCE_DIR not found (use --source)"
if [ ! -f "$SOURCE_DIR/docker-compose.yml" ]; then
    # Accept exactly one nested checkout (e.g. an unzipped "<repo>-main/").
    mapfile -t nested < <(find "$SOURCE_DIR" -mindepth 2 -maxdepth 2 -name docker-compose.yml -printf '%h\n' 2>/dev/null)
    [ "${#nested[@]}" -eq 1 ] || die "SOURCE_DIR does not look like SentinelCore: $SOURCE_DIR"
    SOURCE_DIR="${nested[0]}"
fi

# ---------------------------------------------------------------------------
# Product config (parsed, never sourced)
# ---------------------------------------------------------------------------
conf_get() { sed -n "s/^$1=//p" "$BUILD_DIR/product.conf" | tail -1 | tr -d '\r'; }
[ -f "$BUILD_DIR/product.conf" ] || die "build/product.conf missing"
RELAY_URL="$(conf_get RELAY_URL)"
case "$RELAY_URL" in https://*) ;; *) die "RELAY_URL in product.conf must be https://… (got '$RELAY_URL')" ;; esac

FLAVOR=release
TEST_REASONS=()
if [ "$SKIP_IMAGES" = 1 ]; then FLAVOR="test"; TEST_REASONS+=("built with --skip-images: no images, NOT installable"); fi
if printf '%s' "$RELAY_URL" | grep -q "$PLACEHOLDER_RELAY"; then
    [ "$ALLOW_PLACEHOLDER_RELAY" = 1 ] || die "RELAY_URL is still the placeholder ($RELAY_URL). Deploy relay/ and set it in build/product.conf, or pass --allow-placeholder-relay for a TEST BUILD."
    FLAVOR="test"; TEST_REASONS+=("RELAY_URL is the placeholder $RELAY_URL: email will not work")
fi

PKG="sentinelcore-$VERSION"
STAGE="$STAGE_ROOT/$PKG"
ZIP_BASENAME="$PKG"; [ "$FLAVOR" = test ] && ZIP_BASENAME="$PKG-TEST"

echo "== SentinelCore release build =="
echo "version    : $VERSION"
echo "flavor     : $FLAVOR"
echo "source     : $SOURCE_DIR (read-only)"
echo "release dir: $RELEASE_DIR"
echo "relay url  : $RELAY_URL"
echo "images     : $([ "$SKIP_IMAGES" = 1 ] && echo SKIPPED || echo 'bundled tarball')"
echo

# ---------------------------------------------------------------------------
# 1) Prerequisites
# ---------------------------------------------------------------------------
echo "-- step 1: prerequisites --"
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need zip; need sha256sum; need find; need tar; need gzip
HAVE_RSYNC=0; command -v rsync >/dev/null 2>&1 && HAVE_RSYNC=1
if [ "$SKIP_IMAGES" = 0 ]; then
    need docker
    docker info >/dev/null 2>&1 || die "docker daemon not reachable (needed to build images)"
fi
if [ "$DO_SIGN" = 1 ]; then need gpg; fi
echo "ok (rsync: $([ "$HAVE_RSYNC" = 1 ] && echo yes || echo 'no — using tar fallback'))"

# ---------------------------------------------------------------------------
# 2) Clean + filtered copy of SOURCE into build/work/src
# ---------------------------------------------------------------------------
echo "-- step 2: copy source (allowlist + denylist) --"
rm -rf "$WORK"
mkdir -p "$SRC_COPY" "$STAGE"

mapfile -t ALLOW < <(grep -vE '^\s*(#|$)' "$BUILD_DIR/allowlist.txt" | tr -d '\r')
COPY_ENTRIES=()
for e in "${ALLOW[@]}"; do
    if [ -e "$SOURCE_DIR/$e" ]; then COPY_ENTRIES+=("$e"); else echo "  warn: allowlisted path absent in source: $e"; fi
done
[ "${#COPY_ENTRIES[@]}" -gt 0 ] || die "nothing to copy — allowlist matched no source paths"

RAW_DENY=()
while IFS= read -r line; do
    line="${line%%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    RAW_DENY+=("$line")
done < "$BUILD_DIR/denylist.txt"

if [ "$HAVE_RSYNC" = 1 ]; then
    RS_EXCL=()
    for p in "${RAW_DENY[@]}"; do RS_EXCL+=(--exclude="$p"); done
    for e in "${COPY_ENTRIES[@]}"; do rsync -a "${RS_EXCL[@]}" "$SOURCE_DIR/$e" "$SRC_COPY"/; done
else
    TAR_EXCL=()
    for p in "${RAW_DENY[@]}"; do
        TAR_EXCL+=(--exclude="$p")
        case "$p" in */*|\**) ;; *) TAR_EXCL+=(--exclude="*/$p") ;; esac
    done
    ( cd "$SOURCE_DIR" && tar "${TAR_EXCL[@]}" -cf - "${COPY_ENTRIES[@]}" ) | ( cd "$SRC_COPY" && tar -xf - )
fi

for p in "${RAW_DENY[@]}"; do
    case "$p" in
        */*) find "$SRC_COPY" -path "*/$p" -prune -exec rm -rf {} + 2>/dev/null || true ;;
        *)   find "$SRC_COPY" -name "$p"   -prune -exec rm -rf {} + 2>/dev/null || true ;;
    esac
done
echo "  copied: ${COPY_ENTRIES[*]}"

cp "$BUILD_DIR/dockerignore" "$SRC_COPY/.dockerignore"

if find "$SRC_COPY" \( -name '.env' -o -name '.env.*' -o -name '*.env' -o -name '.git' \) | grep -q .; then
    die "secret/VCS artifact present in src copy — aborting"
fi

# ---------------------------------------------------------------------------
# 3) Assemble staging (installer, templates, docs, VERSION, README)
# ---------------------------------------------------------------------------
echo "-- step 3: assemble staging --"
mkdir -p "$STAGE/templates" "$STAGE/docs" "$STAGE/images"

[ -f "$RELEASE_DIR/installer/install.sh" ] || die "installer/install.sh missing"
cp "$RELEASE_DIR/installer/install.sh" "$STAGE/install.sh"
cp "$RELEASE_DIR/installer/uninstall.sh" "$STAGE/uninstall.sh"
cp "$RELEASE_DIR/installer/enable-email.sh" "$STAGE/enable-email.sh"
cp -a "$RELEASE_DIR/installer/lib" "$STAGE/lib"
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh" "$STAGE/enable-email.sh"

# Product-level values baked at build time (replaces the dev-tree product.sh).
cat > "$STAGE/lib/product.sh" <<EOF
# shellcheck shell=bash
# product.sh — GENERATED by build-release.sh from build/product.conf. Do not edit.
# shellcheck disable=SC2034
RELEASE_FLAVOR="$FLAVOR"
RELAY_URL="\${RELAY_URL:-$RELAY_URL}"
EOF

# Templates. The compose keeps __VERSION__: the installer substitutes it from
# VERSION at install time (single source of truth, no hardcoded tag).
cp "$OVERLAY/templates/.env.template" "$STAGE/templates/.env.template"
cp "$OVERLAY/templates/docker-compose.release.yml" "$STAGE/templates/docker-compose.release.yml"
cp "$OVERLAY/templates/nginx.release.conf" "$STAGE/templates/nginx.release.conf"
grep -q '__VERSION__' "$STAGE/templates/docker-compose.release.yml" || die "compose template lost its __VERSION__ placeholder"
if grep -Eq 'image: sentinelcore/[a-z-]+:[0-9]' "$STAGE/templates/docker-compose.release.yml"; then
    die "compose template hardcodes a sentinelcore image version; use __VERSION__"
fi

# suricata.yaml.template: derived from the COPY. HOME_NET and the af-packet
# capture interface become placeholders rendered by the installer.
SURI_SRC="$SRC_COPY/docker/suricata/suricata.yaml"
[ -f "$SURI_SRC" ] || die "docker/suricata/suricata.yaml not found in copy"
src_iface="$(awk '/^af-packet:/{f=1;next} f && /^[^ #]/{f=0} f && /- interface:/{print $3; exit}' "$SURI_SRC")"
[ -n "$src_iface" ] && [ "$src_iface" != default ] || die "could not find the af-packet capture interface in suricata.yaml"
sed -E \
    -e 's#(HOME_NET: ).*#\1"[__HOME_NET__]"#' \
    -e "s#^(  - interface: )${src_iface}[[:space:]]*\$#\\1__CAPTURE_INTERFACE__#" \
    "$SURI_SRC" > "$STAGE/templates/suricata.yaml.template"
grep -q '"\[__HOME_NET__\]"' "$STAGE/templates/suricata.yaml.template" || die "HOME_NET placeholder not rendered"
grep -q '^  - interface: __CAPTURE_INTERFACE__$' "$STAGE/templates/suricata.yaml.template" || die "capture interface placeholder not rendered"
grep -q '^  - interface: default' "$STAGE/templates/suricata.yaml.template" || die "af-packet default entry missing"
if grep -q -- "$src_iface" "$STAGE/templates/suricata.yaml.template"; then die "dev interface '$src_iface' still present in suricata template"; fi

# Docs + README + VERSION.
cp "$OVERLAY/docs/"*.md "$STAGE/docs/"
sed "s/__VERSION__/$VERSION/g" "$OVERLAY/README.release.md" > "$STAGE/README.md"
if [ "$FLAVOR" = test ]; then
    {
        printf '\n> **TEST BUILD — NOT FOR CUSTOMERS.**\n'
        for r in "${TEST_REASONS[@]}"; do printf '> - %s\n' "$r"; done
    } > "$WORK/banner.md"
    { sed -n '1p' "$STAGE/README.md"; cat "$WORK/banner.md"; sed '1d' "$STAGE/README.md"; } > "$WORK/README.tmp"
    mv "$WORK/README.tmp" "$STAGE/README.md"
fi
printf '%s\n' "$VERSION" > "$STAGE/VERSION"

# ---------------------------------------------------------------------------
# 4) Build production images from the COPY, bundle with pinned 3rd-party ones
# ---------------------------------------------------------------------------
echo "-- step 4: images + static frontend --"
COMPOSE_IMAGES=()
mapfile -t COMPOSE_IMAGES < <(sed -n -E 's/^[[:space:]]*image:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' \
    "$STAGE/templates/docker-compose.release.yml" | sed "s/__VERSION__/$VERSION/g" | sort -u)
[ "${#COMPOSE_IMAGES[@]}" -gt 0 ] || die "no images found in compose template"
echo "  compose references: ${COMPOSE_IMAGES[*]}"

if [ "$SKIP_IMAGES" = 1 ]; then
    cat > "$STAGE/images/NO_IMAGES.txt" <<EOF
TEST BUILD: built with --skip-images (packaging test).
It is NOT installable. Rebuild without --skip-images on a host with Docker.
EOF
    echo "  skipped (TEST BUILD)"
else
    echo "  building backend image..."
    docker build -t "sentinelcore/backend:$VERSION" "$SRC_COPY/backend"
    echo "  building helper image..."
    docker build -t "sentinelcore/helper:$VERSION" "$SRC_COPY/helper"
    echo "  building relay-shim image (relay/shim/Dockerfile)..."
    docker build -f "$RELEASE_DIR/relay/shim/Dockerfile" -t "sentinelcore/relay-shim:$VERSION" "$RELEASE_DIR/relay"

    echo "  building static frontend (multi-stage) + extracting dist..."
    docker build -f "$OVERLAY/frontend-static.Dockerfile" --target dist \
        -t "sentinelcore-build/frontend-dist:$VERSION" "$SRC_COPY/frontend"
    cid="$(docker create "sentinelcore-build/frontend-dist:$VERSION")"
    mkdir -p "$STAGE/templates/frontend-dist"
    docker cp "$cid:/dist/." "$STAGE/templates/frontend-dist/"
    docker rm "$cid" >/dev/null
    [ -s "$STAGE/templates/frontend-dist/index.html" ] || die "frontend-dist/index.html missing after build"
    find "$STAGE/templates/frontend-dist" -name '*.map' -delete

    for img in "${COMPOSE_IMAGES[@]}"; do
        case "$img" in
            sentinelcore/*) ;;   # built above
            *) echo "  pulling pinned image $img..."; docker pull "$img" >/dev/null ;;
        esac
    done
    for img in "${COMPOSE_IMAGES[@]}"; do
        docker image inspect "$img" >/dev/null 2>&1 || die "image referenced by compose is missing: $img"
    done

    TARBALL="$STAGE/images/sentinelcore-images-$VERSION.tar.gz"
    echo "  saving ${#COMPOSE_IMAGES[@]} images to tarball..."
    docker save "${COMPOSE_IMAGES[@]}" | gzip -9 > "$TARBALL"
    # Prove the tarball really contains every compose image.
    tar -xzOf "$TARBALL" manifest.json > "$WORK/manifest.json" || die "image tarball has no manifest.json"
    for img in "${COMPOSE_IMAGES[@]}"; do
        grep -q "\"$img\"" "$WORK/manifest.json" || die "image missing from tarball: $img"
    done
    echo "  wrote images/$(basename "$TARBALL") ($(du -h "$TARBALL" | cut -f1))"
fi

# Real releases: hard gates (the audit re-checks them).
if [ "$FLAVOR" = release ]; then
    [ -s "$STAGE/images/sentinelcore-images-$VERSION.tar.gz" ] || die "image tarball missing"
    [ -s "$STAGE/templates/frontend-dist/index.html" ] || die "frontend-dist missing"
    [ ! -e "$STAGE/images/NO_IMAGES.txt" ] || die "NO_IMAGES.txt in a real release"
fi

# ---------------------------------------------------------------------------
# 5) Audit the staging dir — abort on any finding
# ---------------------------------------------------------------------------
echo "-- step 5: package audit --"
[ -f "$RELEASE_DIR/tests/audit-package.sh" ] || die "tests/audit-package.sh not found"
bash "$RELEASE_DIR/tests/audit-package.sh" "$STAGE" || die "audit failed — build aborted"

# ---------------------------------------------------------------------------
# 6) SHA256SUMS (covers EVERY file incl. images + frontend-dist), zip, sign
# ---------------------------------------------------------------------------
echo "-- step 6: checksums + zip --"
( cd "$STAGE" && find . -type f ! -name SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum | sed 's#  \./#  #' > SHA256SUMS )
if [ "$FLAVOR" = release ]; then
    grep -q '  images/sentinelcore-images-' "$STAGE/SHA256SUMS" || die "SHA256SUMS does not cover the image tarball"
    grep -q '  templates/frontend-dist/index.html' "$STAGE/SHA256SUMS" || die "SHA256SUMS does not cover frontend-dist"
fi

mkdir -p "$DIST"
ZIP="$DIST/$ZIP_BASENAME.zip"
rm -f "$ZIP" "$ZIP.sha256" "$ZIP.asc"
( cd "$STAGE_ROOT" && zip -rqX "$ZIP" "$PKG" )
( cd "$DIST" && sha256sum "$ZIP_BASENAME.zip" > "$ZIP_BASENAME.zip.sha256" )
if [ "$DO_SIGN" = 1 ]; then echo "  signing..."; gpg --armor --detach-sign --output "$ZIP.asc" "$ZIP"; fi

# Re-audit the final artifact exactly as customers receive it.
bash "$RELEASE_DIR/tests/audit-package.sh" "$ZIP" >/dev/null || die "audit of final zip failed"

# ---------------------------------------------------------------------------
# 7) Manifest
# ---------------------------------------------------------------------------
echo
echo "== manifest =="
file_count="$(cd "$STAGE" && find . -type f | wc -l | tr -d ' ')"
echo "package   : $PKG ($FLAVOR)"
echo "files     : $file_count"
echo "zip       : $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "zip sha256: $(awk '{print $1}' "$ZIP.sha256")"
echo "images    :"
if [ "$SKIP_IMAGES" = 1 ]; then echo "  (none — TEST BUILD)"; else printf '  %s\n' "${COMPOSE_IMAGES[@]}"; fi
echo
echo "staging tree (frontend-dist collapsed):"
( cd "$STAGE_ROOT" && find "$PKG" -path "$PKG/templates/frontend-dist/*" -prune -o -print | sort | sed 's#[^/]*/#  #g' )
echo
echo "DONE."
