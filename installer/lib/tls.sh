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

# ---- web UI certificate (nginx) --------------------------------------------
# TLS_MODE=self-signed: a one-off "SentinelCore Web CA" signs a server cert
# whose SAN covers this host's names and IPv4 addresses; the CA key is
# destroyed right after signing. Users import $INSTALL_DIR/tls-web-ca.crt to
# trust the UI (docs/HTTPS.md). TLS_MODE=custom: the operator's cert + key are
# validated and copied. http-local: nothing to do.
#   $INSTALL_DIR/tls-web/      0700 root   server.crt (0644)  server.key (0600)
#   $INSTALL_DIR/tls-web-ca.crt 0644       public CA cert (self-signed mode)

WEB_CERT_DAYS="${WEB_CERT_DAYS:-825}"

web_cert_sans() {
    # web_cert_sans -> "DNS:localhost,IP:127.0.0.1,DNS:<host>,IP:<ipv4>..."
    local out="DNS:localhost,IP:127.0.0.1" n ip
    for n in "$(hostname -s 2>/dev/null || true)" "$(hostname -f 2>/dev/null || true)"; do
        printf '%s' "$n" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]{0,252}[A-Za-z0-9])?$' || continue
        case ",$out," in *",DNS:$n,"*) ;; *) out="$out,DNS:$n" ;; esac
    done
    while IFS= read -r ip; do
        valid_ipv4 "$ip" || continue
        case ",$out," in *",IP:$ip,"*) ;; *) out="$out,IP:$ip" ;; esac
    done < <(host_ipv4s)
    if valid_ipv4 "${BIND_ADDRESS:-}" && [ "$BIND_ADDRESS" != 0.0.0.0 ]; then
        case ",$out," in *",IP:$BIND_ADDRESS,"*) ;; *) out="$out,IP:$BIND_ADDRESS" ;; esac
    fi
    printf '%s' "$out"
}

web_cert_still_good() {
    # Repair/upgrade keep a cert that is valid for at least 30 more days.
    [ -f "$INSTALL_DIR/tls-web/server.crt" ] && [ -f "$INSTALL_DIR/tls-web/server.key" ] || return 1
    as_root openssl x509 -in "$INSTALL_DIR/tls-web/server.crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1
}

gen_web_selfsigned() {
    local dir="$INSTALL_DIR/tls-web" sans
    sans="$(web_cert_sans)"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] openssl in a private mktemp dir: Web CA key+cert, server key+CSR, sign ($WEB_CERT_DAYS days)"
        info "[dry-run]   SAN = $sans"
        info "[dry-run] install $dir/server.{crt,key} (dir 700, key 600); $INSTALL_DIR/tls-web-ca.crt (0644); shred the CA key"
        return 0
    fi
    local work
    work="$(as_root mktemp -d /tmp/sentinelcore-webca.XXXXXX)" || { err "mktemp failed"; return 1; }
    as_root chmod 700 "$work"
    # shellcheck disable=SC2016
    if ! as_root env W="$work" SANS="$sans" DAYS="$WEB_CERT_DAYS" CN="$(hostname -s 2>/dev/null || echo sentinelcore)" sh -ec '
        umask 077
        openssl genrsa -out "$W/ca.key" 3072 2>/dev/null
        openssl req -x509 -new -key "$W/ca.key" -sha256 -days 3650 \
            -subj "/O=SentinelCore/CN=SentinelCore Web CA ($CN)" \
            -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$W/ca.crt"
        openssl genrsa -out "$W/server.key" 2048 2>/dev/null
        openssl req -new -key "$W/server.key" -subj "/O=SentinelCore/CN=$CN" -out "$W/server.csr"
        printf "subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" "$SANS" > "$W/server.ext"
        openssl x509 -req -in "$W/server.csr" -CA "$W/ca.crt" -CAkey "$W/ca.key" \
            -set_serial "0x$(openssl rand -hex 16)" -days "$DAYS" -sha256 \
            -extfile "$W/server.ext" -out "$W/server.crt" 2>/dev/null
        openssl verify -CAfile "$W/ca.crt" "$W/server.crt" >/dev/null
    '; then
        as_root sh -c "shred -u '$work'/*.key 2>/dev/null; rm -rf '$work'"
        err "web certificate generation failed"; return 1
    fi
    as_root shred -u "$work/ca.key" 2>/dev/null || as_root rm -f "$work/ca.key"
    as_root install -d -m 0700 "$dir"
    as_root install -m 0644 "$work/server.crt" "$dir/server.crt"
    as_root install -m 0600 "$work/server.key" "$dir/server.key"
    as_root install -m 0644 "$work/ca.crt" "$INSTALL_DIR/tls-web-ca.crt"
    as_root shred -u "$work/server.key" 2>/dev/null || true
    as_root rm -rf "$work"
    if as_root find "$INSTALL_DIR" -name 'ca.key' | grep -q .; then err "a CA private key is still present under $INSTALL_DIR"; return 1; fi
    good "HTTPS certificate issued ($WEB_CERT_DAYS days; SAN $sans); Web CA key destroyed"
}

custom_cert_check() {
    # custom_cert_check <cert> <key> -> 0 if parseable, unexpired, unencrypted
    # key, and the key matches the certificate.
    local crt="$1" key="$2" a b
    openssl x509 -in "$crt" -noout >/dev/null 2>&1 || { err "TLS_CERT_FILE is not a PEM certificate: $crt"; return 1; }
    openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1 || { err "certificate $crt has expired"; return 1; }
    openssl pkey -in "$key" -passin pass: -noout >/dev/null 2>&1 || { err "TLS_KEY_FILE is not an unencrypted PEM private key: $key"; return 1; }
    a="$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null)"
    b="$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null | openssl sha256 2>/dev/null)"
    [ -n "$a" ] && [ "$a" = "$b" ] || { err "private key does not match the certificate"; return 1; }
    return 0
}

install_custom_cert() {
    local dir="$INSTALL_DIR/tls-web"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] validate $TLS_CERT_FILE / $TLS_KEY_FILE (parse, not expired, key matches) and copy to $dir/ (key 600)"
        return 0
    fi
    custom_cert_check "$TLS_CERT_FILE" "$TLS_KEY_FILE" || return 1
    as_root install -d -m 0700 "$dir"
    as_root install -m 0644 "$TLS_CERT_FILE" "$dir/server.crt"
    as_root install -m 0600 "$TLS_KEY_FILE" "$dir/server.key"
    as_root rm -f "$INSTALL_DIR/tls-web-ca.crt"
    good "operator certificate installed ($(as_root openssl x509 -in "$dir/server.crt" -noout -subject 2>/dev/null))"
}

setup_web_tls() {
    step "HTTPS for the web UI (TLS_MODE=${TLS_MODE:-self-signed})"
    case "${TLS_MODE:-self-signed}" in
        http-local) good "plain HTTP on 127.0.0.1 — no certificate needed" ;;
        custom) install_custom_cert ;;
        self-signed)
            if [ -n "${MODE_EXISTING:-}" ] && web_cert_still_good; then good "keeping the existing HTTPS certificate"; return 0; fi
            gen_web_selfsigned ;;
        *) err "unknown TLS_MODE '${TLS_MODE:-}'"; return 1 ;;
    esac
}

print_trust_help() {
    [ "${TLS_MODE:-}" = self-signed ] || return 0
    cat <<EOF

  Your browser will warn about the certificate until you trust this
  install's Web CA (once per computer):
    CA file  : $INSTALL_DIR/tls-web-ca.crt   (fingerprint below)
    Ubuntu   : sudo cp $INSTALL_DIR/tls-web-ca.crt /usr/local/share/ca-certificates/sentinelcore-web.crt && sudo update-ca-certificates
    Chrome   : Settings > Privacy and security > Security > Manage certificates > Authorities > Import
    Firefox  : Settings > Privacy & Security > Certificates > View Certificates > Authorities > Import
  $(as_root openssl x509 -in "$INSTALL_DIR/tls-web-ca.crt" -noout -fingerprint -sha256 2>/dev/null || echo "(fingerprint unavailable)")
  Full guide: docs/HTTPS.md
EOF
}
