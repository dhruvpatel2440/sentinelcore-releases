#!/usr/bin/env bash
# audit-package.sh — fail the build if the release (a staging DIR or a .zip)
# contains anything a customer must never receive: secret/VCS/dev files, known
# token patterns, high-entropy strings, or absolute developer paths/usernames.
# Also inspects Docker images for secrets/source leftovers when docker is present.
#
# Usage: tests/audit-package.sh <staging-dir | release.zip>
# Exit:  0 = clean, 1 = findings (printed), 2 = usage error.
#
# Dependency-light: bash + grep + find + unzip. Uses gitleaks/trufflehog when
# installed, else a regex fallback.
set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ] || { [ ! -d "$TARGET" ] && [ ! -f "$TARGET" ]; }; then
    echo "usage: $0 <staging-dir | release.zip>" >&2
    exit 2
fi

CLEANUP=""
trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT

# If a zip, extract to a temp dir and audit that.
STAGING="$TARGET"
case "$TARGET" in
    *.zip)
        command -v unzip >/dev/null 2>&1 || { echo "need unzip to audit a zip" >&2; exit 2; }
        CLEANUP="$(mktemp -d)"; STAGING="$CLEANUP"
        unzip -qq "$TARGET" -d "$STAGING"
        ;;
esac
[ -d "$STAGING" ] || { echo "not a directory after extraction: $STAGING" >&2; exit 2; }

findings=0
note() { printf '  [FAIL] %s\n' "$*"; findings=$((findings + 1)); }
ok()   { printf '  [ok]   %s\n' "$*"; }

echo "== SentinelCore package audit =="
echo "target : $TARGET"
echo

# --------------------------------------------------------------------------
# 0) Release completeness (installable package, real relay, not a test build)
# --------------------------------------------------------------------------
echo "-- release completeness --"
PKGROOT="$STAGING"
if [ ! -f "$PKGROOT/install.sh" ]; then
    for d in "$STAGING"/*/; do [ -f "$d/install.sh" ] && PKGROOT="${d%/}"; done
fi
flavor="$(sed -n 's/^RELEASE_FLAVOR="\(.*\)"$/\1/p' "$PKGROOT/lib/product.sh" 2>/dev/null | head -1)"
relay="$(sed -n 's/^RELAY_URL="\${RELAY_URL:-\(.*\)}"$/\1/p' "$PKGROOT/lib/product.sh" 2>/dev/null | head -1)"
pkg_version="$(head -1 "$PKGROOT/VERSION" 2>/dev/null | tr -d '\r')"
case "$flavor" in
    release)
        ok "flavor: release (version ${pkg_version:-?})"
        if [ -e "$PKGROOT/images/NO_IMAGES.txt" ]; then note "images/NO_IMAGES.txt present in a real release"; else ok "no NO_IMAGES.txt"; fi
        if [ -s "$PKGROOT/images/sentinelcore-images-$pkg_version.tar.gz" ]; then ok "image tarball present"; else note "images/sentinelcore-images-$pkg_version.tar.gz missing"; fi
        if [ -s "$PKGROOT/templates/frontend-dist/index.html" ]; then ok "frontend-dist present"; else note "templates/frontend-dist/index.html missing"; fi
        case "$relay" in
            ''|*relay.sentinelcore.app*) note "RELAY_URL is the placeholder/empty ('$relay') in a real release" ;;
            https://*) ok "relay url: $relay" ;;
            *) note "RELAY_URL is not https ('$relay')" ;;
        esac
        if grep -q 'TEST BUILD' "$PKGROOT/README.md" 2>/dev/null; then note "README marked TEST BUILD in a real release"; fi
        if [ -f "$PKGROOT/SHA256SUMS" ]; then
            grep -q '  images/sentinelcore-images-' "$PKGROOT/SHA256SUMS" || note "SHA256SUMS does not cover the image tarball"
            grep -q '  templates/frontend-dist/' "$PKGROOT/SHA256SUMS" || note "SHA256SUMS does not cover frontend-dist"
        fi
        ;;
    test)
        ok "flavor: TEST BUILD (completeness gates relaxed)"
        if grep -q 'TEST BUILD' "$PKGROOT/README.md" 2>/dev/null; then ok "README marked TEST BUILD"; else note "test build README is not marked TEST BUILD"; fi
        ;;
    *)
        note "lib/product.sh missing or has no RELEASE_FLAVOR (not built by build-release.sh?)"
        ;;
esac
echo

# --------------------------------------------------------------------------
# 1) Forbidden files by name/path
# --------------------------------------------------------------------------
echo "-- forbidden files --"
forbidden_names=(
    '.env' '.env.*' '*.env' '.env.example'
    'id_rsa' 'id_rsa.*' 'id_ed25519' 'id_ed25519.*'
    '*.pem' '*.key' '*.p12' '*.pfx' '*.keystore' '*.jks'
    '.netrc' '.npmrc' '.pypirc'
    '*.log' '*.sqlite' '*.sqlite3' '*.db' '*.db-wal' '*.db-shm'
    'CLAUDE.md' 'TEST_REPORT.md' 'TEST_REPORT.docx'
    '*.pcap'
)
name_hits=0
for pat in "${forbidden_names[@]}"; do
    while IFS= read -r hit; do
        base="$(basename "$hit")"
        [ "$base" = ".env.template" ] && continue   # the one allowed .env* artifact
        note "forbidden file: ${hit#"$STAGING"/}"; name_hits=$((name_hits+1))
    done < <(find "$STAGING" -name "$pat" 2>/dev/null || true)
done
# Forbidden directories anywhere.
for d in .git .github node_modules __pycache__ .venv tests .pytest_cache; do
    while IFS= read -r hit; do
        note "forbidden dir: ${hit#"$STAGING"/}"; name_hits=$((name_hits+1))
    done < <(find "$STAGING" -type d -name "$d" 2>/dev/null || true)
done
[ "$name_hits" -eq 0 ] && ok "no forbidden files or directories"

# --------------------------------------------------------------------------
# 2) Known token patterns + lab values + private paths (text files)
# --------------------------------------------------------------------------
echo
echo "-- secrets / tokens / lab values / dev paths --"
bad_literals=(
    'change-me' 'dev-only-placeholder'
    'charusat.edu.in' 'dhruvpatel2440@gmail.com' '24cs040'
    '192.168.56.' 'sentinel.lab'
)
# provider + key regexes (ERE)
declare -a regexes=(
    'xkeysib-[A-Za-z0-9]{16,}'                 # Brevo
    'AKIA[0-9A-Z]{16}'                         # AWS access key id
    'sk_live_[0-9A-Za-z]{16,}'                 # Stripe secret
    'pk_live_[0-9A-Za-z]{16,}'                 # Stripe pub-live
    'SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}' # SendGrid
    're_[0-9A-Za-z]{16,}'                      # Resend
    'xox[baprs]-[0-9A-Za-z-]{10,}'             # Slack
    'gh[pousr]_[0-9A-Za-z]{30,}'              # GitHub token
    'github_pat_[0-9A-Za-z_]{30,}'            # GitHub fine-grained PAT
    'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' # JWT
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'      # private key header
    '/home/[a-z_][a-z0-9_-]*/'                # linux dev home path
    'C:\\\\Users\\\\[^\\\\]+'                  # windows dev path
    'OneDrive'                                 # dev machine path hint
    'Dhruv'                                    # developer username
)
content_hits=0
scan_file() {
    local f="$1" rel
    rel="${f#"$STAGING"/}"
    LC_ALL=C grep -qI . "$f" 2>/dev/null || return 0   # skip binaries
    local p
    for p in "${bad_literals[@]}"; do
        grep -F -q -- "$p" "$f" 2>/dev/null && { note "literal '$p' in $rel"; content_hits=$((content_hits+1)); }
    done
    local rx
    for rx in "${regexes[@]}"; do
        grep -E -q -- "$rx" "$f" 2>/dev/null && { note "pattern /$rx/ in $rel"; content_hits=$((content_hits+1)); }
    done
    return 0
}
while IFS= read -r f; do
    case "$f" in */images/*) continue ;; esac
    scan_file "$f" || true
done < <(find "$STAGING" -type f 2>/dev/null)
[ "$content_hits" -eq 0 ] && ok "no token patterns / lab values / dev paths"

# --------------------------------------------------------------------------
# 3) Dedicated secret scanners if available
# --------------------------------------------------------------------------
echo
echo "-- dedicated scanner --"
if command -v gitleaks >/dev/null 2>&1; then
    if gitleaks detect --no-git --source "$STAGING" --redact >/dev/null 2>&1; then
        ok "gitleaks: clean"
    else
        note "gitleaks reported findings (run: gitleaks detect --no-git --source <dir>)"
    fi
elif command -v trufflehog >/dev/null 2>&1; then
    if [ -z "$(trufflehog filesystem "$STAGING" --no-update --fail 2>/dev/null)" ]; then
        ok "trufflehog: clean"
    else
        note "trufflehog reported findings"
    fi
else
    ok "gitleaks/trufflehog not installed — used regex fallback above"
fi

# --------------------------------------------------------------------------
# 4) High-entropy heuristic (text files)
# --------------------------------------------------------------------------
echo
echo "-- high-entropy heuristic --"
entropy_hits=0
while IFS= read -r f; do
    case "$f" in
        */images/*) continue ;;
        */templates/frontend-dist/*) continue ;;   # minified bundles; token regexes above still apply
        *SHA256SUMS|*.sha256) continue ;;
    esac
    LC_ALL=C grep -qI . "$f" 2>/dev/null || continue
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in *__*) continue ;; esac
        printf '%s' "$line" | grep -q '[0-9]' || continue
        printf '%s' "$line" | grep -q '[A-Za-z]' || continue
        entropy_hits=$((entropy_hits + 1))
        note "high-entropy in ${f#"$STAGING"/}: $(printf '%.24s...' "$line")"
    done < <(grep -E -o '[A-Za-z0-9+/_-]{40,}' "$f" 2>/dev/null | sort -u || true)
done < <(find "$STAGING" -type f 2>/dev/null)
[ "$entropy_hits" -eq 0 ] && ok "no unexplained high-entropy strings"

# --------------------------------------------------------------------------
# 5) Docker image inspection (when docker + images are present)
# --------------------------------------------------------------------------
echo
echo "-- docker image inspection --"
if ! command -v docker >/dev/null 2>&1; then
    ok "docker not available — image scan SKIPPED (run on the build host)"
else
    imgs="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^sentinelcore/' || true)"
    if [ -z "$imgs" ]; then
        ok "no sentinelcore/* images loaded — image scan SKIPPED"
    else
        img_hits=0
        while IFS= read -r img; do
            # history should not contain secret-looking ENV/ARG values
            if docker history --no-trunc "$img" 2>/dev/null | grep -Eiq 'xkeysib-|AKIA[0-9A-Z]{16}|PRIVATE KEY|password=|secret='; then
                note "image $img: secret-like value in build history"; img_hits=$((img_hits+1))
            fi
            # filesystem scan for .env / keys baked into the image
            cid="$(docker create "$img" 2>/dev/null || true)"
            if [ -n "$cid" ]; then
                if docker export "$cid" 2>/dev/null | tar -t 2>/dev/null | grep -Eq '(^|/)\.(env|git)(/|$)|\.pem$|\.key$|id_rsa'; then
                    note "image $img: secret/VCS artifact in filesystem"; img_hits=$((img_hits+1))
                fi
                docker rm "$cid" >/dev/null 2>&1 || true
            fi
        done <<< "$imgs"
        [ "$img_hits" -eq 0 ] && ok "images clean (history + filesystem)"
    fi
fi

echo
if [ "$findings" -eq 0 ]; then
    echo "AUDIT PASSED — package is clean."
    exit 0
fi
echo "AUDIT FAILED — $findings finding(s). Build must abort."
exit 1
