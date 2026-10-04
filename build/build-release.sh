#!/usr/bin/env bash
# build-release.sh — produce dist/sentinelcore-<version>.zip (+ .sha256): the
# installer, templates, docs, the detection ruleset, the static frontend and
# every Docker image as an offline tarball. SOURCE_DIR is READ-ONLY; images are
# built from a filtered COPY in build/work/src with the release Dockerfiles in
# build/overlay/images/.
#
# Usage:
#   build/build-release.sh <version> [options]
#
# Options:
#   --source <dir>              SOURCE_DIR (default: $SOURCE_DIR, else ../SentinelCore;
#                               one nested checkout such as …/Sentinelcore-main is found).
#   --rules-archive <file>      Use this ET Open tarball instead of downloading it
#                               (offline / reproducible builds).
#   --test-build                Mark the package TEST BUILD: dist/…-TESTBUILD.zip.
#   --skip-images               Packaging test only (no Docker). Requires --test-build.
#                               The installer refuses such a package.
#   --allow-placeholder-relay   Allow the placeholder RELAY_URL. Requires --test-build.
#   --sign                      GPG-sign SHA256SUMS (inside) and the zip (<zip>.asc)
#                               with the builder's default gpg key (never stored here).
#   -h | --help                 This help.
#
# A real build FAILS unless: every image builds and passes its smoke tests,
# main's backend + helper unit tests pass inside the built images, the ET Open
# ruleset is composed and passes `suricata -T` in the helper image,
# frontend-dist/index.html exists, RELAY_URL is real, and the package audit passes.
#
# Build evidence (test output, schema dump, SBOM) goes to
# dist/sentinelcore-<version>-build-evidence/ (never shipped).
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_DIR="$(cd "$BUILD_DIR/.." && pwd)"
WORK="$BUILD_DIR/work"
SRC_COPY="$WORK/src"
TESTSUITE="$WORK/testsuite"
STAGE_ROOT="$WORK/stage"
OVERLAY="$BUILD_DIR/overlay"
DIST="$RELEASE_DIR/dist"
PLACEHOLDER_RELAY="relay.sentinelcore.app"
BASE_PY_TAG="python:3.11-slim-trixie"
BASE_NODE_TAG="node:20-alpine"
THIRD_PARTY=(postgres:16-alpine redis:7.4-alpine nginx:1.27-alpine)

VERSION=""
SOURCE_DIR="${SOURCE_DIR:-$RELEASE_DIR/../SentinelCore}"
SKIP_IMAGES=0
TEST_BUILD=0
ALLOW_PLACEHOLDER_RELAY=0
DO_SIGN=0
RULES_ARCHIVE=""

die() { echo "error: $*" >&2; exit 1; }
hdr() { printf '\n-- %s --\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE_DIR="${2:?}"; shift 2 ;;
        --rules-archive) RULES_ARCHIVE="${2:?}"; shift 2 ;;
        --test-build) TEST_BUILD=1; shift ;;
        --skip-images) SKIP_IMAGES=1; shift ;;
        --allow-placeholder-relay) ALLOW_PLACEHOLDER_RELAY=1; shift ;;
        --sign) DO_SIGN=1; shift ;;
        -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) if [ -z "$VERSION" ]; then VERSION="$1"; else die "unexpected arg: $1"; fi; shift ;;
    esac
done

[ -n "$VERSION" ] || die "version required (e.g. build/build-release.sh 1.0.1)"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$' \
    || die "version '$VERSION' is not X.Y.Z[-suffix]"
[ "$SKIP_IMAGES" = 0 ] || [ "$TEST_BUILD" = 1 ] || die "--skip-images is only allowed together with --test-build"
[ "$ALLOW_PLACEHOLDER_RELAY" = 0 ] || [ "$TEST_BUILD" = 1 ] || die "--allow-placeholder-relay is only allowed together with --test-build"
if [ -n "$RULES_ARCHIVE" ]; then
    [ -s "$RULES_ARCHIVE" ] || die "--rules-archive file not found: $RULES_ARCHIVE"
    RULES_ARCHIVE="$(cd "$(dirname "$RULES_ARCHIVE")" && pwd)/$(basename "$RULES_ARCHIVE")"
fi

SOURCE_DIR="$(cd "$SOURCE_DIR" 2>/dev/null && pwd || true)"
[ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ] || die "SOURCE_DIR not found (use --source)"
if [ ! -f "$SOURCE_DIR/docker-compose.yml" ]; then
    mapfile -t nested < <(find "$SOURCE_DIR" -mindepth 2 -maxdepth 2 -name docker-compose.yml -printf '%h\n' 2>/dev/null)
    [ "${#nested[@]}" -eq 1 ] || die "SOURCE_DIR does not look like SentinelCore: $SOURCE_DIR"
    SOURCE_DIR="${nested[0]}"
fi

# Product config (parsed, never sourced).
conf_get() { sed -n "s/^$1=//p" "$BUILD_DIR/product.conf" | tail -1 | tr -d '\r'; }
[ -f "$BUILD_DIR/product.conf" ] || die "build/product.conf missing"
RELAY_URL="$(conf_get RELAY_URL)"
case "$RELAY_URL" in https://*) ;; *) die "RELAY_URL in product.conf must be https://… (got '$RELAY_URL')" ;; esac

FLAVOR=release
TEST_REASONS=()
[ "$TEST_BUILD" = 1 ] && { FLAVOR="test"; TEST_REASONS+=("built with --test-build"); }
[ "$SKIP_IMAGES" = 1 ] && TEST_REASONS+=("built with --skip-images: no images, NOT installable")
if printf '%s' "$RELAY_URL" | grep -q "$PLACEHOLDER_RELAY"; then
    [ "$ALLOW_PLACEHOLDER_RELAY" = 1 ] || die "RELAY_URL is still the placeholder ($RELAY_URL). Deploy relay/ and set it in build/product.conf (or --test-build --allow-placeholder-relay)."
    TEST_REASONS+=("RELAY_URL is the placeholder $RELAY_URL: email will not work")
fi

PKG="sentinelcore-$VERSION"
STAGE="$STAGE_ROOT/$PKG"
ZIP_BASENAME="$PKG"; [ "$FLAVOR" = test ] && ZIP_BASENAME="$PKG-TESTBUILD"
EVIDENCE="$DIST/$PKG-build-evidence"

echo "== SentinelCore release build =="
echo "version    : $VERSION"
echo "flavor     : $FLAVOR"
echo "source     : $SOURCE_DIR (read-only)"
echo "relay url  : $RELAY_URL"
echo "images     : $([ "$SKIP_IMAGES" = 1 ] && echo SKIPPED || echo 'built + bundled')"

# ---------------------------------------------------------------------------
hdr "step 1: prerequisites"
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need zip; need sha256sum; need find; need tar; need gzip; need curl
if [ "$SKIP_IMAGES" = 0 ]; then
    need docker
    docker info >/dev/null 2>&1 || die "docker daemon not reachable (needed to build images)"
    docker buildx version >/dev/null 2>&1 || echo "  note: buildx not found; using the classic builder"
fi
[ "$DO_SIGN" = 1 ] && need gpg
echo "ok"

# ---------------------------------------------------------------------------
hdr "step 2: filtered copy of SOURCE into build/work (source untouched)"
rm -rf "$WORK"
mkdir -p "$SRC_COPY" "$STAGE" "$TESTSUITE"
rm -rf "$EVIDENCE"; mkdir -p "$EVIDENCE"

mapfile -t ALLOW < <(grep -vE '^\s*(#|$)' "$BUILD_DIR/allowlist.txt" | tr -d '\r')
COPY_ENTRIES=()
for e in "${ALLOW[@]}"; do
    if [ -e "$SOURCE_DIR/$e" ]; then COPY_ENTRIES+=("$e"); else echo "  warn: allowlisted path absent in source: $e"; fi
done
[ "${#COPY_ENTRIES[@]}" -gt 0 ] || die "allowlist matched no source paths"

RAW_DENY=()
while IFS= read -r line; do
    line="${line%%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    RAW_DENY+=("$line")
done < "$BUILD_DIR/denylist.txt"

TAR_EXCL=()
for p in "${RAW_DENY[@]}"; do
    TAR_EXCL+=(--exclude="$p")
    case "$p" in */*|\**) ;; *) TAR_EXCL+=(--exclude="*/$p") ;; esac
done
( cd "$SOURCE_DIR" && tar "${TAR_EXCL[@]}" -cf - "${COPY_ENTRIES[@]}" ) | ( cd "$SRC_COPY" && tar -xf - )
for p in "${RAW_DENY[@]}"; do
    case "$p" in
        */*) find "$SRC_COPY" -path "*/$p" -prune -exec rm -rf {} + 2>/dev/null || true ;;
        *)   find "$SRC_COPY" -name "$p"   -prune -exec rm -rf {} + 2>/dev/null || true ;;
    esac
done
echo "  copied: ${COPY_ENTRIES[*]}"

# Main's unit tests are NOT in the image contexts; a separate copy is mounted
# into the built images to run them (step 5).
for d in backend helper; do
    mkdir -p "$TESTSUITE/$d"
    ( cd "$SOURCE_DIR/$d" && tar --exclude='__pycache__' --exclude='*.pyc' -cf - tests pytest.ini ) | ( cd "$TESTSUITE/$d" && tar -xf - )
done

# Per-context .dockerignore (a .dockerignore only applies at the context root).
for d in backend helper frontend; do cp "$BUILD_DIR/dockerignore" "$SRC_COPY/$d/.dockerignore"; done

# Helper image extras: main's own logrotate.conf + the start wrapper.
mkdir -p "$SRC_COPY/helper/.release"
cp "$SRC_COPY/docker/suricata/logrotate.conf" "$SRC_COPY/helper/.release/logrotate.conf"
cp "$OVERLAY/images/helper-start.sh" "$SRC_COPY/helper/.release/helper-start.sh"

if find "$SRC_COPY" \( -name '.env' -o -name '.env.*' -o -name '*.env' -o -name '.git' \) | grep -q .; then
    die "secret/VCS artifact present in src copy — aborting"
fi

# ---------------------------------------------------------------------------
hdr "step 3: assemble staging (installer, templates, docs)"
mkdir -p "$STAGE/templates" "$STAGE/docs" "$STAGE/images" "$STAGE/rules"

for f in install.sh uninstall.sh enable-email.sh disable-email.sh; do
    [ -f "$RELEASE_DIR/installer/$f" ] || die "installer/$f missing"
    install -m 0755 "$RELEASE_DIR/installer/$f" "$STAGE/$f"
done
cp -a "$RELEASE_DIR/installer/lib" "$STAGE/lib"
cp -a "$RELEASE_DIR/installer/bin" "$STAGE/bin"
chmod 0755 "$STAGE"/bin/*.sh

cat > "$STAGE/lib/product.sh" <<EOF
# shellcheck shell=bash
# product.sh — GENERATED by build-release.sh from build/product.conf. Do not edit.
# shellcheck disable=SC2034
RELEASE_FLAVOR="$FLAVOR"
RELAY_URL="\${RELAY_URL:-$RELAY_URL}"
EOF

cp -a "$OVERLAY/templates/." "$STAGE/templates/"
grep -q '__VERSION__' "$STAGE/templates/docker-compose.release.yml" || die "compose template lost its __VERSION__ placeholder"
if grep -Eq 'image: sentinelcore/[a-z-]+:[0-9]' "$STAGE"/templates/docker-compose*.yml; then
    die "compose template hardcodes a sentinelcore image version; use __VERSION__"
fi

# suricata.yaml.template from the COPY: HOME_NET + af-packet interface become
# placeholders rendered by the installer (same value as .env CAPTURE_INTERFACE).
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
if grep -q -- "$src_iface" "$STAGE/templates/suricata.yaml.template"; then die "dev interface '$src_iface' still present in suricata template"; fi

cp "$OVERLAY/docs/"*.md "$STAGE/docs/"
sed "s/__VERSION__/$VERSION/g" "$OVERLAY/README.release.md" > "$STAGE/README.md"
if [ "$FLAVOR" = test ]; then
    {
        printf '\n> **TEST BUILD — NOT FOR CUSTOMERS.** The installer refuses it unless\n'
        printf '> SENTINELCORE_ALLOW_TEST_BUILD=1 is set (and always refuses a build without images).\n'
        for r in "${TEST_REASONS[@]}"; do printf '> - %s\n' "$r"; done
    } > "$WORK/banner.md"
    { sed -n '1p' "$STAGE/README.md"; cat "$WORK/banner.md"; sed '1d' "$STAGE/README.md"; } > "$WORK/README.tmp"
    mv "$WORK/README.tmp" "$STAGE/README.md"
fi
printf '%s\n' "$VERSION" > "$STAGE/VERSION"

# ---------------------------------------------------------------------------
hdr "step 4: build images from the COPY (release Dockerfiles)"
SC_IMAGES=("sentinelcore/backend:$VERSION" "sentinelcore/helper:$VERSION" "sentinelcore/relay-shim:$VERSION")
ALL_IMAGES=("${SC_IMAGES[@]}" "${THIRD_PARTY[@]}")

# Every image the compose files reference must be one we bundle (and vice versa).
mapfile -t COMPOSE_IMAGES < <(sed -n -E 's/^[[:space:]]*image:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' \
    "$STAGE"/templates/docker-compose*.yml | sed "s/__VERSION__/$VERSION/g" | sort -u)
for img in "${COMPOSE_IMAGES[@]}"; do
    printf '%s\n' "${ALL_IMAGES[@]}" | grep -qxF "$img" || die "compose references $img, which the build does not bundle"
done

digest_of() { docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$1" 2>/dev/null; }

if [ "$SKIP_IMAGES" = 1 ]; then
    cat > "$STAGE/images/NO_IMAGES.txt" <<EOF
TEST BUILD: built with --skip-images (packaging test).
It is NOT installable. Rebuild without --skip-images on a host with Docker.
EOF
    echo "  skipped (TEST BUILD)"
else
    echo "  pulling base images to pin them by digest..."
    docker pull -q "$BASE_PY_TAG" >/dev/null
    docker pull -q "$BASE_NODE_TAG" >/dev/null
    BASE_PY="$(digest_of "$BASE_PY_TAG")"; BASE_NODE="$(digest_of "$BASE_NODE_TAG")"
    [ -n "$BASE_PY" ] && [ -n "$BASE_NODE" ] || die "could not resolve base image digests"
    echo "  python base: $BASE_PY"
    echo "  node base  : $BASE_NODE"

    echo "  building sentinelcore/backend:$VERSION ..."
    docker build --build-arg "BASE_IMAGE=$BASE_PY" -f "$OVERLAY/images/backend.Dockerfile" \
        -t "sentinelcore/backend:$VERSION" "$SRC_COPY/backend" > "$EVIDENCE/build-backend.log" 2>&1 \
        || { tail -40 "$EVIDENCE/build-backend.log"; die "backend image build failed"; }
    echo "  building sentinelcore/helper:$VERSION ..."
    docker build --build-arg "BASE_IMAGE=$BASE_PY" -f "$OVERLAY/images/helper.Dockerfile" \
        -t "sentinelcore/helper:$VERSION" "$SRC_COPY/helper" > "$EVIDENCE/build-helper.log" 2>&1 \
        || { tail -40 "$EVIDENCE/build-helper.log"; die "helper image build failed"; }
    echo "  building sentinelcore/relay-shim:$VERSION ..."
    docker build --build-arg "BASE_IMAGE=$BASE_PY" -f "$RELEASE_DIR/relay/shim/Dockerfile" \
        -t "sentinelcore/relay-shim:$VERSION" "$RELEASE_DIR/relay" > "$EVIDENCE/build-shim.log" 2>&1 \
        || { tail -40 "$EVIDENCE/build-shim.log"; die "relay-shim image build failed"; }
    echo "  building static frontend ..."
    docker build --build-arg "NODE_IMAGE=$BASE_NODE" -f "$OVERLAY/images/frontend.Dockerfile" --target dist \
        -t "sentinelcore-build/frontend-dist:$VERSION" "$SRC_COPY/frontend" > "$EVIDENCE/build-frontend.log" 2>&1 \
        || { tail -40 "$EVIDENCE/build-frontend.log"; die "frontend build failed"; }
    cid="$(docker create "sentinelcore-build/frontend-dist:$VERSION")"
    mkdir -p "$STAGE/templates/frontend-dist"
    docker cp "$cid:/dist/." "$STAGE/templates/frontend-dist/"
    docker rm "$cid" >/dev/null
    [ -s "$STAGE/templates/frontend-dist/index.html" ] || die "frontend-dist/index.html missing after build"
    find "$STAGE/templates/frontend-dist" -name '*.map' -delete

    for img in "${THIRD_PARTY[@]}"; do echo "  pulling $img ..."; docker pull -q "$img" >/dev/null; done
fi

# ---------------------------------------------------------------------------
hdr "step 5: image tests (smoke + main's unit tests inside the built images)"
DUMMY_DB="postgresql+asyncpg://x:x@127.0.0.1:1/x"
if [ "$SKIP_IMAGES" = 0 ]; then
    B="sentinelcore/backend:$VERSION"; H="sentinelcore/helper:$VERSION"
    # shellcheck disable=SC2016
    docker run --rm --network none -e DATABASE_URL="$DUMMY_DB" --entrypoint sh "$B" -ec '
        python -c "import weasyprint, pydyf; print(\"weasyprint\", weasyprint.__version__, \"pydyf\", pydyf.__version__)"
        tshark -v | head -1
        capinfos -v | head -1
        uid="$(id -u)"; [ "$uid" != 0 ] || { echo "backend runs as root" >&2; exit 1; }; echo "uid=$uid groups=$(id -G)"
        python -c "import app.main; print(\"app import ok\")"
        alembic heads
        for d in pcap reports staging; do stat -c "%n %U:%G %a" /var/lib/sentinelcore/$d; done
        test -f /usr/share/zoneinfo/Europe/Berlin && echo "tzdata ok"
        python -c "import pathlib,sys; sys.exit(0 if not pathlib.Path(\"/app/tests\").exists() else 1)" && echo "no tests dir in image"
    ' > "$EVIDENCE/smoke-backend.txt" 2>&1 || { cat "$EVIDENCE/smoke-backend.txt"; die "backend smoke test failed"; }
    sed 's/^/  backend: /' "$EVIDENCE/smoke-backend.txt"

    # shellcheck disable=SC2016
    docker run --rm --network none --entrypoint sh "$H" -ec '
        nmap --version | head -1
        suricata --build-info | head -1
        iptables --version
        ip -V
        logrotate --version 2>&1 | head -1
        test -f /etc/logrotate.d/suricata && echo "logrotate config installed"
        getent group sentinelcore
        python -c "import scapy; print(\"scapy\", scapy.VERSION)"
    ' > "$EVIDENCE/smoke-helper.txt" 2>&1 || { cat "$EVIDENCE/smoke-helper.txt"; die "helper smoke test failed"; }
    sed 's/^/  helper : /' "$EVIDENCE/smoke-helper.txt"
    grep -q 'nf_tables' "$EVIDENCE/smoke-helper.txt" && echo "  helper : iptables backend nf_tables" || echo "  helper : NOTE iptables backend is legacy (recorded)"

    echo "  helper unit tests (main's helper/tests, as in main's CI) ..."
    docker run --rm --network none -v "$TESTSUITE/helper/tests:/opt/helper/tests:ro" \
        -v "$TESTSUITE/helper/pytest.ini:/opt/helper/pytest.ini:ro" --entrypoint python "$H" \
        -m pytest tests -q -p no:cacheprovider > "$EVIDENCE/unit-helper.txt" 2>&1 \
        || { tail -30 "$EVIDENCE/unit-helper.txt"; die "helper unit tests failed"; }
    tail -1 "$EVIDENCE/unit-helper.txt" | sed 's/^/  helper : /'

    echo "  backend unit tests with throwaway postgres+redis (mirrors main's CI) ..."
    NET="sc-build-$$"; PGC="sc-build-pg-$$"; RDC="sc-build-redis-$$"
    TEST_PG_PW="$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    cleanup_testnet() { docker rm -f "$PGC" "$RDC" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
    trap cleanup_testnet EXIT
    docker network create --internal "$NET" >/dev/null
    docker run -d --name "$PGC" --network "$NET" -e POSTGRES_USER=sentinelcore -e POSTGRES_PASSWORD="$TEST_PG_PW" \
        -e POSTGRES_DB=sentinelcore postgres:16-alpine >/dev/null
    docker run -d --name "$RDC" --network "$NET" redis:7.4-alpine >/dev/null
    for _ in $(seq 1 60); do docker exec "$PGC" pg_isready -U sentinelcore -d sentinelcore >/dev/null 2>&1 && break; sleep 2; done
    docker exec "$PGC" pg_isready -U sentinelcore -d sentinelcore >/dev/null 2>&1 || die "test postgres did not start"
    TEST_DB="postgresql+asyncpg://sentinelcore:$TEST_PG_PW@$PGC:5432/sentinelcore"
    docker run --rm --network "$NET" -e DATABASE_URL="$TEST_DB" -e REDIS_URL="redis://$RDC:6379/0" \
        -e SECRET_KEY=build-only-not-a-real-secret-0123456789abcdef \
        -v "$TESTSUITE/backend/tests:/app/tests:ro" -v "$TESTSUITE/backend/pytest.ini:/app/pytest.ini:ro" \
        --entrypoint sh "$B" -ec 'alembic upgrade head && python -m pytest tests -q -p no:cacheprovider' \
        > "$EVIDENCE/unit-backend.txt" 2>&1 || { tail -40 "$EVIDENCE/unit-backend.txt"; die "backend unit tests failed"; }
    tail -1 "$EVIDENCE/unit-backend.txt" | sed 's/^/  backend: /'
    # Schema evidence for the static parity diff (tests/parity/static-diff.sh).
    docker exec "$PGC" pg_dump -U sentinelcore -d sentinelcore --schema-only --no-owner > "$EVIDENCE/schema-release.sql"
    cleanup_testnet; trap - EXIT
else
    echo "  skipped (no images)"
fi

# ---------------------------------------------------------------------------
hdr "step 6: detection ruleset (ET Open, composed by main's own code, verified by suricata -T)"
RULES_URL="$(sed -n "s#.*'\(https://rules.emergingthreats.net/[^']*\)'.*#\1#p" "$SRC_COPY/backend/alembic/versions/"*_m4_sensor.py | head -1)"
[ -n "$RULES_URL" ] || die "could not find main's default ET Open URL in the M4 migration"
mkdir -p "$WORK/rules-in"
if [ -n "$RULES_ARCHIVE" ]; then
    cp "$RULES_ARCHIVE" "$WORK/rules-in/emerging.rules.tar.gz"; RULES_FROM="$RULES_ARCHIVE (local)"
elif [ "$SKIP_IMAGES" = 1 ]; then
    RULES_FROM=""
else
    echo "  downloading $RULES_URL ..."
    curl -fsSL --max-time 300 --proto '=https' -o "$WORK/rules-in/emerging.rules.tar.gz" "$RULES_URL" \
        || die "could not download the ET Open ruleset (use --rules-archive for offline builds)"
    RULES_FROM="$RULES_URL"
fi
if [ -n "$RULES_FROM" ] && [ "$SKIP_IMAGES" = 0 ]; then
    ARCHIVE_SHA="$(sha256sum "$WORK/rules-in/emerging.rules.tar.gz" | awk '{print $1}')"
    # Compose exactly as main's run_rules_update does (extract → compose, no overrides).
    docker run --rm --network none --user "$(id -u):$(id -g)" -e DATABASE_URL="$DUMMY_DB" \
        -v "$WORK/rules-in:/in:ro" -v "$STAGE/rules:/out" --entrypoint python "sentinelcore/backend:$VERSION" -c '
import pathlib
from app.services import ruleset
ex = ruleset.extract_rules(pathlib.Path("/in/emerging.rules.tar.gz").read_bytes())
content, stats = ruleset.compose(ex, [])
pathlib.Path("/out/sentinelcore.rules").write_bytes(content)
print("files", len(ex.files), "skipped", len(ex.skipped), "stats", stats)
' > "$EVIDENCE/rules-compose.txt" 2>&1 || { cat "$EVIDENCE/rules-compose.txt"; die "rule composition failed"; }
    tar -xzOf "$WORK/rules-in/emerging.rules.tar.gz" rules/LICENSE > "$STAGE/rules/LICENSE.ET-Open.txt" 2>/dev/null \
        || rm -f "$STAGE/rules/LICENSE.ET-Open.txt"
    RULE_COUNT="$(grep -cvE '^[[:space:]]*(#|$)' "$STAGE/rules/sentinelcore.rules" || true)"
    [ "${RULE_COUNT:-0}" -gt 1000 ] || die "composed ruleset is suspiciously small ($RULE_COUNT rules)"

    # Validate in the helper image with the release suricata.yaml (rendered for lo).
    sed -e 's|__HOME_NET__|192.0.2.0/24|g' -e 's|__CAPTURE_INTERFACE__|lo|g' \
        "$STAGE/templates/suricata.yaml.template" > "$WORK/suricata-test.yaml"
    docker run --rm --network none -v "$WORK/suricata-test.yaml:/etc/suricata/suricata.yaml:ro" \
        -v "$STAGE/rules/sentinelcore.rules:/var/lib/suricata/rules/sentinelcore.rules:ro" \
        --entrypoint suricata "sentinelcore/helper:$VERSION" -T -c /etc/suricata/suricata.yaml \
        > "$EVIDENCE/rules-suricata-T.txt" 2>&1 || { tail -30 "$EVIDENCE/rules-suricata-T.txt"; die "bundled ruleset fails suricata -T"; }
    SURI_VER="$(docker run --rm --network none --entrypoint suricata "sentinelcore/helper:$VERSION" -V | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]/) {print $i; exit}}')"
    cat > "$STAGE/rules/NOTICE.txt" <<EOF
SentinelCore bundled detection ruleset
======================================
Source        : Emerging Threats Open (Proofpoint) — the same default source
                main SentinelCore seeds in its database.
URL           : $RULES_URL
Retrieved     : $(date -u +%Y-%m-%d) (build of SentinelCore $VERSION)
Archive sha256: $ARCHIVE_SHA
Rules         : $RULE_COUNT active rules in sentinelcore.rules
Validated with: suricata $SURI_VER (suricata -T, in the bundled helper image)
Composed by   : main's backend code (app.services.ruleset.extract_rules + compose,
                no overrides) — identical to an online "Update rules" run.
Licence       : ET Open rules are distributed under their own licence terms
                (see LICENSE.ET-Open.txt when present, and
                https://rules.emergingthreats.net/OPEN_download_instructions.html).
Updates       : Admins update online later from the UI (Sensor → Rules → Update)
                or POST /api/sensor/rules/update, exactly as in main.
EOF
    ( cd "$STAGE/rules" && sha256sum sentinelcore.rules > sentinelcore.rules.sha256 )
    echo "  ruleset: $RULE_COUNT rules, validated with suricata $SURI_VER"
else
    echo "  skipped (TEST BUILD without images)"
fi

# ---------------------------------------------------------------------------
hdr "step 7: save images (offline tarball + image-id manifest)"
if [ "$SKIP_IMAGES" = 0 ]; then
    for img in "${ALL_IMAGES[@]}"; do docker image inspect "$img" >/dev/null 2>&1 || die "image missing: $img"; done
    TARBALL="$STAGE/images/sentinelcore-images-$VERSION.tar.gz"
    docker save "${ALL_IMAGES[@]}" | gzip -9 > "$TARBALL"
    tar -xzOf "$TARBALL" manifest.json > "$WORK/manifest.json" || die "image tarball has no manifest.json"
    for img in "${ALL_IMAGES[@]}"; do grep -q "\"$img\"" "$WORK/manifest.json" || die "image missing from tarball: $img"; done
    # The installer verifies every loaded image against these ids.
    for img in "${ALL_IMAGES[@]}"; do printf '%s %s\n' "$img" "$(docker image inspect -f '{{.Id}}' "$img")"; done > "$STAGE/images/IMAGES.txt"
    echo "  wrote images/$(basename "$TARBALL") ($(du -h "$TARBALL" | cut -f1))"
fi

# ---------------------------------------------------------------------------
hdr "step 8: SBOM-lite (docs/SBOM.txt)"
{
    echo "SentinelCore $VERSION — software bill of materials (lite)"
    echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)  flavor: $FLAVOR"
    echo
    if [ "$SKIP_IMAGES" = 1 ]; then
        echo "(TEST BUILD without images — no image inventory)"
    else
        echo "## base images"
        echo "python : $BASE_PY"
        echo "node   : $BASE_NODE"
        echo
        echo "## images (tag / id / size)"
        for img in "${ALL_IMAGES[@]}"; do
            printf '%-36s %s %s\n' "$img" "$(docker image inspect -f '{{.Id}}' "$img")" "$(docker image inspect -f '{{.Size}}' "$img" | awk '{printf "%.0fMB", $1/1048576}')"
            d="$(digest_of "$img")"; [ -n "$d" ] && printf '%-36s upstream %s\n' "" "$d"
        done
        echo
        echo "## tool versions"
        sed 's/^/backend: /' "$EVIDENCE/smoke-backend.txt"
        sed 's/^/helper : /' "$EVIDENCE/smoke-helper.txt"
        echo
        echo "## python packages — backend (pip freeze)"
        docker run --rm --network none --entrypoint pip "sentinelcore/backend:$VERSION" freeze
        echo
        echo "## python packages — helper (pip freeze)"
        docker run --rm --network none --entrypoint pip "sentinelcore/helper:$VERSION" freeze
        echo
        echo "## python packages — relay-shim (pip freeze)"
        docker run --rm --network none --entrypoint pip "sentinelcore/relay-shim:$VERSION" freeze
        echo
        echo "## debian packages — helper (dpkg)"
        docker run --rm --network none --entrypoint dpkg-query "sentinelcore/helper:$VERSION" -W -f '${Package} ${Version}\n' \
            | grep -E '^(suricata|suricata-update|nmap|iptables|iproute2|logrotate|libpcap0.8)[ :]'
        echo
        echo "## debian packages — backend (dpkg)"
        docker run --rm --network none --entrypoint dpkg-query "sentinelcore/backend:$VERSION" -W -f '${Package} ${Version}\n' \
            | grep -E '^(tshark|wireshark-common|libpango-1.0-0|libcairo2|tzdata)[ :]'
        echo
        echo "## ruleset"
        sed -n '1,12p' "$STAGE/rules/NOTICE.txt" 2>/dev/null || echo "(none)"
    fi
} > "$STAGE/docs/SBOM.txt"
cp "$STAGE/docs/SBOM.txt" "$EVIDENCE/SBOM.txt"
echo "  wrote docs/SBOM.txt"

# ---------------------------------------------------------------------------
hdr "step 9: release gates"
if [ "$FLAVOR" = release ] || [ "$SKIP_IMAGES" = 0 ]; then
    [ -s "$STAGE/images/sentinelcore-images-$VERSION.tar.gz" ] || die "image tarball missing"
    [ -s "$STAGE/images/IMAGES.txt" ] || die "images/IMAGES.txt missing"
    [ -s "$STAGE/templates/frontend-dist/index.html" ] || die "frontend-dist missing"
    [ -s "$STAGE/rules/sentinelcore.rules" ] || die "rules bundle missing"
    [ ! -e "$STAGE/images/NO_IMAGES.txt" ] || die "NO_IMAGES.txt in an image build"
fi
echo "ok"

# ---------------------------------------------------------------------------
hdr "step 10: package audit"
bash "$RELEASE_DIR/tests/audit-package.sh" "$STAGE" || die "audit failed — build aborted"

# ---------------------------------------------------------------------------
hdr "step 11: checksums, signature, zip"
( cd "$STAGE" && find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.asc -print0 \
    | sort -z | xargs -0 sha256sum | sed 's#  \./#  #' > SHA256SUMS )
if [ "$SKIP_IMAGES" = 0 ]; then
    for want in "images/sentinelcore-images-" "images/IMAGES.txt" "templates/frontend-dist/index.html" "rules/sentinelcore.rules"; do
        grep -q "  $want" "$STAGE/SHA256SUMS" || die "SHA256SUMS does not cover $want"
    done
fi
if [ "$DO_SIGN" = 1 ]; then
    gpg --armor --detach-sign --output "$STAGE/SHA256SUMS.asc" "$STAGE/SHA256SUMS"
    gpg --armor --export > "$STAGE/SIGNING-KEY.asc"
fi

mkdir -p "$DIST"
ZIP="$DIST/$ZIP_BASENAME.zip"
rm -f "$ZIP" "$ZIP.sha256" "$ZIP.asc"
( cd "$STAGE_ROOT" && zip -rqX "$ZIP" "$PKG" )
( cd "$DIST" && sha256sum "$ZIP_BASENAME.zip" > "$ZIP_BASENAME.zip.sha256" )
[ "$DO_SIGN" = 1 ] && gpg --armor --detach-sign --output "$ZIP.asc" "$ZIP"

bash "$RELEASE_DIR/tests/audit-package.sh" "$ZIP" > "$EVIDENCE/audit-zip.txt" 2>&1 \
    || { cat "$EVIDENCE/audit-zip.txt"; die "audit of final zip failed"; }

# ---------------------------------------------------------------------------
echo
echo "== manifest =="
echo "package   : $PKG ($FLAVOR)"
echo "files     : $(cd "$STAGE" && find . -type f | wc -l | tr -d ' ')"
echo "zip       : $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "zip sha256: $(awk '{print $1}' "$ZIP.sha256")"
[ -f "$STAGE/images/IMAGES.txt" ] && sed 's/^/image     : /' "$STAGE/images/IMAGES.txt"
echo "evidence  : $EVIDENCE"
echo
( cd "$STAGE_ROOT" && find "$PKG" -path "$PKG/templates/frontend-dist/*" -prune -o -print | sort | sed 's#[^/]*/#  #g' )
echo
echo "DONE."
