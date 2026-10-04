# shellcheck shell=bash
# product.sh — product-level release configuration (DEV TREE COPY).
# build-release.sh REPLACES this file in every package with values rendered
# from build/product.conf (RELEASE_FLAVOR=release|test, the real RELAY_URL).
# shellcheck disable=SC2034
RELEASE_FLAVOR="dev"
RELAY_URL="${RELAY_URL:-https://relay.sentinelcore.app}"
