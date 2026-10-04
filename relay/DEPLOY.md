# Deploying the SentinelCore Email Relay

The relay runs on infrastructure **you** control (any small VPS or container
host). It is the only place the email-provider key exists.

## 1. Prepare the host
- A Linux host with Docker + Compose v2.
- A DNS name (e.g. `relay.sentinelcore.app`) pointing at it.
- A TLS-terminating reverse proxy (Caddy/nginx/Traefik) in front of port 8080,
  or run the container behind your platform's TLS. The relay itself speaks
  plain HTTP on 8080; **do not expose 8080 directly to the internet.**

## 2. Configure secrets (server-side only)
```bash
cp .env.example .env
# Edit .env:
#   RELAY_ADMIN_SECRET   openssl rand -hex 32
#   RELAY_PROVIDER=brevo
#   BREVO_API_KEY=<your real Brevo key>   # lives ONLY here
#   RELAY_FROM_ADDRESS=notify@yourdomain  # a verified Brevo sender
#   RELAY_PUBLIC_URL=https://relay.yourdomain
```
`.env` must never be committed. Only `.env.example` (placeholders) is in the repo.

## 3. Launch
```bash
docker compose up -d
curl -fsS https://relay.yourdomain/v1/health   # {"status":"ok","provider":"brevo"}
```
The sqlite store lives in the `relay_data` volume. For higher durability, back
up that volume or move to Postgres (swap `app/db.py`'s DSN; schema is portable).

## 4. Point installs at the relay
Set `RELAY_URL` in `installer/lib/product.sh` to your relay's public URL before
building the release (Phase 03). That one value flows to every install.

## 5. Day-2 operations

**List installs**
```bash
curl -fsS https://relay.yourdomain/v1/admin/installs \
  -H "x-admin-secret: $RELAY_ADMIN_SECRET"
```

**Revoke an install** (stops its mail immediately)
```bash
curl -fsS -X POST https://relay.yourdomain/v1/revoke \
  -H "x-admin-secret: $RELAY_ADMIN_SECRET" \
  -d '{"install_id":"sc-<machine-id>"}'
```

**Rotate the provider key**
1. Create the new key in the provider console.
2. Update `BREVO_API_KEY` in `.env`.
3. `docker compose up -d` (recreates the relay). Installs are unaffected — they
   never held the key.

**Rotate the admin secret**
Update `RELAY_ADMIN_SECRET` in `.env` and redeploy. Existing install tokens are
unaffected (they are independent of the admin secret).

**Switch provider**
Change `RELAY_PROVIDER` (and that provider's env), redeploy. No install changes.

## 6. What never leaves this host
- The provider API key (`BREVO_API_KEY`).
- `RELAY_ADMIN_SECRET`.
- Plaintext install tokens (only hashes are stored; the token is shown to the
  install once at registration and then only held on that box).
