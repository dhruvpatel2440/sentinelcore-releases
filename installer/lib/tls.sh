# shellcheck shell=bash
# tls.sh — install-local CA + the api.brevo.com leaf certificate presented by
# the relay shim. This is what lets the UNMODIFIED backend's verify=True
# egress to https://api.brevo.com trust the in-stack shim (see
# docs-internal/email-client-findings.md).
#
# Key hygiene (A7): the CA private key exists only in a private mktemp dir
# for the few seconds needed to sign the leaf, then is shredded. What remains:
#   $INSTALL_DIR/tls/            0700, owned by the shim uid (1000)
#       api.brevo.com.crt        0644  leaf cert
#       api.brevo.com.key        0600  leaf key
#   $INSTALL_DIR/ca.crt          0644  public CA cert (nothing can be signed with it)
#   $INSTALL_DIR/ca-bundle.pem   0644  system roots + ca.crt (backend SSL_CERT_FILE)

SHIM_UID="${SHIM_UID:-1000}"
SYSTEM_CA_BUNDLE="${SYSTEM_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"

gen_install_ca() {
    step "Install-local mail CA + shim certificate"
    if [ "${EMAIL_MODE:-off}" != brevo ]; then
        good "email disabled — skipping CA/cert generation"
        return 0
    fi
    local dir="$INSTALL_DIR/tls"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] openssl in a private mktemp dir: CA key+cert, leaf key+CSR for CN/SAN=api.brevo.com, sign"
        info "[dry-run] install leaf -> $dir/api.brevo.com.{crt,key} (dir 700, key 600, owner uid $SHIM_UID)"
        info "[dry-run] ca.crt -> $INSTALL_DIR/ca.crt + appended to $INSTALL_DIR/ca-bundle.pem; shred CA key"
        return 0
    fi

    local work
    work="$(as_root mktemp -d /tmp/sentinelcore-ca.XXXXXX)" || { err "mktemp failed"; return 1; }
    as_root chmod 700 "$work"
    # shellcheck disable=SC2016
    if ! as_root env W="$work" sh -ec '
        umask 077
        openssl genrsa -out "$W/ca.key" 3072 2>/dev/null
        openssl req -x509 -new -key "$W/ca.key" -sha256 -days 3650 \
            -subj "/CN=SentinelCore Install CA" \
            -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$W/ca.crt"
        openssl genrsa -out "$W/leaf.key" 2048 2>/dev/null
        openssl req -new -key "$W/leaf.key" -subj "/CN=api.brevo.com" -out "$W/leaf.csr"
        printf "subjectAltName=DNS:api.brevo.com\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" > "$W/leaf.ext"
        openssl x509 -req -in "$W/leaf.csr" -CA "$W/ca.crt" -CAkey "$W/ca.key" \
            -set_serial "0x$(openssl rand -hex 16)" -days 825 -sha256 \
            -extfile "$W/leaf.ext" -out "$W/leaf.crt" 2>/dev/null
        openssl verify -CAfile "$W/ca.crt" "$W/leaf.crt" >/dev/null
    '; then
        as_root sh -c "shred -u '$work'/*.key 2>/dev/null; rm -rf '$work'"
        err "certificate generation failed"; return 1
    fi

    # The CA key is no longer needed by anything: destroy it first.
    as_root shred -u "$work/ca.key" 2>/dev/null || as_root rm -f "$work/ca.key"

    as_root install -d -m 0700 -o "$SHIM_UID" -g "$SHIM_UID" "$dir"
    as_root install -m 0644 -o "$SHIM_UID" -g "$SHIM_UID" "$work/leaf.crt" "$dir/api.brevo.com.crt"
    as_root install -m 0600 -o "$SHIM_UID" -g "$SHIM_UID" "$work/leaf.key" "$dir/api.brevo.com.key"
    as_root install -m 0644 "$work/ca.crt" "$INSTALL_DIR/ca.crt"
    as_root shred -u "$work/leaf.key" 2>/dev/null || true
    as_root rm -rf "$work"

    # Bundle = system roots + our CA (the real internet still validates).
    as_root sh -c "cat '$SYSTEM_CA_BUNDLE' '$INSTALL_DIR/ca.crt' > '$INSTALL_DIR/ca-bundle.pem.tmp' \
        && chmod 0644 '$INSTALL_DIR/ca-bundle.pem.tmp' && mv -f '$INSTALL_DIR/ca-bundle.pem.tmp' '$INSTALL_DIR/ca-bundle.pem'"

    if as_root find "$INSTALL_DIR" -name 'ca.key' | grep -q .; then err "CA private key still present under $INSTALL_DIR"; return 1; fi
    good "leaf cert for api.brevo.com issued; CA private key destroyed (only ca.crt kept)"
}
