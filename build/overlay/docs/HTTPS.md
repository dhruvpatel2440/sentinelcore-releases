# SentinelCore — HTTPS and certificate trust

SentinelCore serves its UI over HTTPS by default. This is required, not
cosmetic: the session refresh cookie is `Secure`, and browsers only keep
`Secure` cookies over HTTPS (or on `127.0.0.1`). Over plain HTTP on a LAN
address you would be logged out every 15 minutes, so the installer does not
offer that combination.

## Modes (`TLS_MODE` in `/opt/sentinelcore/.env`)

| Mode | What you get | Browser warning |
|---|---|---|
| `self-signed` (default) | A per-install "SentinelCore Web CA" signs a server certificate for this host's names and IP addresses (valid 825 days). The CA's private key is destroyed right after signing. | Until you trust the CA once (below) |
| `custom` | Your own certificate (full chain, PEM) and unencrypted key. Validated at install (parses, not expired, key matches). HSTS is enabled. | None, if your CA is trusted |
| `http-local` | Plain HTTP bound to 127.0.0.1 only — for single-machine use. | n/a |

Files: `/opt/sentinelcore/tls-web/server.crt`, `server.key` (mode 600) and, in
self-signed mode, `/opt/sentinelcore/tls-web-ca.crt` (public, safe to copy).

## Trust the self-signed CA (once per computer)

Check the fingerprint the installer printed matches:
```bash
openssl x509 -in /opt/sentinelcore/tls-web-ca.crt -noout -fingerprint -sha256
```

Copy `tls-web-ca.crt` to the computer you browse from, then:

- **Ubuntu / Debian (system-wide, also used by Chrome on Linux):**
  ```bash
  sudo cp tls-web-ca.crt /usr/local/share/ca-certificates/sentinelcore-web.crt
  sudo update-ca-certificates
  ```
- **Chrome / Edge (Linux, per-user):** Settings → Privacy and security → Security →
  Manage certificates → Authorities → Import → select the file → tick
  "Trust this certificate for identifying websites".
- **Firefox:** Settings → Privacy & Security → Certificates → View Certificates →
  Authorities → Import → tick "Trust this CA to identify websites".
- **Windows:** double-click the file → Install Certificate → Local Machine →
  "Trusted Root Certification Authorities".

The CA can only have signed this one server certificate (its key no longer
exists), so trusting it does not let anyone mint other certificates.

## Changing mode or certificate later
Edit `TLS_MODE` (and for `custom`, place your files) then re-run the installer
from the release folder and choose **Repair**, or replace
`tls-web/server.crt` + `server.key` and restart nginx:
```bash
sudo docker compose -f /opt/sentinelcore/docker-compose.yml -f /opt/sentinelcore/docker-compose.tls.yml --env-file /opt/sentinelcore/.env restart nginx
```

If the host gets a new IP address, run Repair once more after deleting
`/opt/sentinelcore/tls-web/` so the certificate is re-issued for the new address.

## What nginx enforces
TLS 1.2/1.3 with modern ciphers, HTTP → HTTPS redirect, security headers
(Content-Security-Policy, X-Frame-Options DENY, X-Content-Type-Options,
Referrer-Policy, Permissions-Policy), a login rate limit as defense in depth
(SentinelCore's own lockout stays authoritative), and a 500 MB limit only on
the PCAP upload endpoint (20 MB elsewhere).
