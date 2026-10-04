# Admin bootstrap — how the first admin is created (A4)

Source read (read-only): `backend/entrypoint.sh`, `backend/scripts/seed_admin.py`,
`backend/app/api/routes/auth.py`, `backend/app/schemas/auth.py`.

## How the app seeds the admin

- **`backend/entrypoint.sh`** runs on **every** start of the `backend`
  container (`RUN_MIGRATIONS=true`; the worker sets it to `false`):
  1. wait for the database
  2. `alembic upgrade head`
  3. `python -m scripts.seed_admin`
  4. `exec "$@"` (uvicorn)
- **`scripts/seed_admin.py`** reads:
  - `SEED_ADMIN_USERNAME` (default `admin`)
  - `SEED_ADMIN_EMAIL`
  - `SEED_ADMIN_PASSWORD`
- Behaviour:
  - user already exists → prints `Admin user '<name>' already exists — nothing to do.` and exits 0.
    **It never updates an existing password.**
  - `SEED_ADMIN_PASSWORD` unset → generates a random 24-char password and
    prints it once (`GENERATED PASSWORD: …`) to the container log.
  - `SEED_ADMIN_PASSWORD` shorter than 12 → exits 1.
- Login: `POST /api/auth/login`, JSON `{"username": …, "password": …}`
  (`LoginRequest`, password 1–256 chars). Lockout after `LOGIN_MAX_ATTEMPTS=5`
  failures per username+IP for `LOGIN_LOCKOUT_SECONDS=300`.

## Why 1.0.0 ignored the chosen password

1. `compose up` started `backend` with **no** `SEED_ADMIN_PASSWORD` in `.env`.
2. The entrypoint seeded `admin` with a **random** password.
3. The installer then ran `docker compose run … seed_admin` with the chosen
   password → `already exists — nothing to do`.
4. The chosen password never applied. `verify_login` only warned.
5. The password was also put on the command line
   (`-e SEED_ADMIN_PASSWORD='…'`): visible in `ps`, and broken by any `'`.

## 1.0.1 order (installer `fresh_flow`)

| Step | Command (simplified) | Why |
|---|---|---|
| 1 | `docker compose up -d db redis` + wait **healthy** | DB ready, backend NOT started yet |
| 2 | `SEED_ADMIN_PASSWORD=<pw> docker compose run --rm --no-deps -e SEED_ADMIN_PASSWORD -e SEED_ADMIN_USERNAME backend python -m scripts.seed_admin` | Entrypoint migrates, then seeds with **our** password. This is the first time the admin is created |
| 3 | `docker compose up -d` | Normal start; the entrypoint's seed finds the admin and does nothing |
| 4 | wait for **all** services healthy | |
| 5 | `verify_login` → `POST http://<bind>:<port>/api/auth/login` | Hard failure (see below) |

## How the password travels

- `-e NAME` **without a value** makes compose copy `NAME` from its own
  process environment into the one-shot container.
- The installer sets the variable only on that one `docker compose` process
  (`VAR=… docker compose …`). Under `sudo`: `--preserve-env=SEED_ADMIN_PASSWORD,SEED_ADMIN_USERNAME`.
- Result:
  - `ps` shows only `-e SEED_ADMIN_PASSWORD` (the name), never the value.
  - No shell re-parsing → `'` `"` `$` `\` spaces `|` `&` `;` arrive byte-for-byte.
  - Nothing is written to disk; nothing goes into `.env`.
- Login check: JSON is built in bash (`json_escape`) and sent on **stdin**
  (`curl --data-binary @-`), not argv.
- Proven by `tests/installer.bats`:
  - `seed: tricky passwords reach the container env byte-for-byte, never argv`
  - `verify_login: JSON body on stdin decodes to the exact password; argv clean`

## Edge cases handled

- **Left-over DB volume** (earlier install not purged): seed prints
  `already exists` → installer runs a one-shot that sets the hash with the
  app's own `app.core.security.hash_password` (`set_admin_password`). No source change.
- **App generated its own password** (env did not arrive): seed output
  contains `GENERATED PASSWORD` → install fails loudly.
- **No password supplied (non-interactive)**: installer generates one locally
  (`openssl rand`, guaranteed upper/lower/digit), seeds with it, prints it
  **once** on the final screen (never logged — `final_screen` bypasses `log()`).
- **Login 401 after seeding**: installer re-applies the chosen password once
  and retries; still failing → interactive menu (Retry / Re-enter & re-apply /
  Abort), non-interactive → exit 1 (and the fresh install is rolled back).
- **Repair / Upgrade**: admin untouched (password unknown to the installer).

## Not changed

- No file in SOURCE_DIR was modified; no source patch in `build/overlay`.
