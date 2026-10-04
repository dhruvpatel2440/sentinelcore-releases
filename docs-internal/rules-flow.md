# Rules flow — main vs release (Phase 13.1)

Read-only analysis of main; the release does NOT change this flow, it only supplies
the first ruleset the same way main's own "Update rules" does.

## Main

```
Admin UI  Sensor → Rules → Update
  └─ POST /api/sensor/rules/update   (admin)                     backend/app/api/routes/sensor.py:405
       └─ background run_rules_update(actor_id)                  sensor.py:430
            ├─ for each enabled rule_source:                     (seeded: "Emerging Threats Open",
            │     ruleset.fetch_feed(url)  HTTPS, 128 MB cap      .../suricata-7.0.3/emerging.rules.tar.gz,
            │     ruleset.extract_rules()  zip-slip guarded        alembic 0003_m4_sensor.py:98-108)
            ├─ overrides = rule_overrides rows (disable/enable/threshold by SID)
            ├─ ruleset.compose(extracted, overrides) → one file "sentinelcore.rules"
            └─ ruleset.deploy(content)                           backend/app/services/ruleset.py:296
                 ├─ stage(): write /var/lib/sentinelcore/staging/sentinelcore.rules, sha256
                 ├─ helper op suricata_write_rules {filename, content_sha256}   (timeout 1200 s)
                 │     helper/helper/ops/suricata.py:308
                 │     validate filename → verify sha256 → backup live file → move into
                 │     /var/lib/suricata/rules → `suricata -T` (≤ 900 s) → on failure restore backup
                 └─ helper op suricata_reload_rules (suricatasc ruleset-reload-nonblocking | SIGUSR2);
                    "not_running" is tolerated (rules written, sensor stopped)
```

- `suricata.yaml`: `default-rule-path: /var/lib/suricata/rules`, `rule-files: [sentinelcore.rules]`.
- The helper image ships an EMPTY `sentinelcore.rules` so `-T`/start work before the first update.
- `suricata-update` is installed in the helper image but main never calls it (the backend pipeline replaces it).
- Sensor start is manual in main: `POST /api/sensor/start` → helper `suricata_start`
  (`suricata -c … --af-packet -i $CAPTURE_INTERFACE -D --pidfile …`).
- Consequence for a fresh main install: **no rules and no running sensor until an admin acts**, and the
  update needs internet.

## Release

| Step | Where | How |
|---|---|---|
| Build: fetch ET Open | `build/build-release.sh` step 6 | The URL is read from main's own M4 migration (same source main seeds). `--rules-archive` for offline/reproducible builds. Archive sha256 recorded. |
| Build: compose | step 6 | Runs **main's code** inside the built backend image: `ruleset.extract_rules()` + `ruleset.compose(extracted, [])` (no overrides — a fresh install has none). Output `rules/sentinelcore.rules`. |
| Build: validate | step 6 | `suricata -T` in the built helper image with the release `suricata.yaml`. Build fails if it does not pass or if < 1000 rules. |
| Build: ship | steps 6, 11 | `rules/sentinelcore.rules`, `.sha256`, `NOTICE.txt` (source, date, archive sha256, rule count, Suricata version), `LICENSE.ET-Open.txt` (from the archive). Covered by `SHA256SUMS`. |
| Install: load | `installer/lib/rules.sh` `load_bundled_rules` | checksum → `ruleset.deploy(<bundle>)` inside the backend container (**main's exact function**: stage → helper `suricata_write_rules` with `suricata -T` and rollback → reload). Failure ⇒ install stops with the log tail; the previous (empty) ruleset stays. Repair/upgrade keep an existing non-empty live ruleset (admin updates are never overwritten). |
| Install: start sensor | `start_sensor` | helper `suricata_start` via main's `helper_client` (same op as `POST /api/sensor/start`), then waits for `eve.json` (`suricata_status.eve_log_age_seconds`). |
| Install: optional online update | `maybe_update_rules_online` | Asks (default **no**; `UPDATE_RULES=yes` in a config file). Runs `app.api.routes.sensor.run_rules_update(None)` — main's background pipeline itself. Offline ⇒ skipped, bundled rules stay. |
| Boot | systemd `ExecStartPost=-/opt/sentinelcore/bin/sensor-start.sh --wait` | Waits for helper + backend health, then `suricata_start` (idempotent). **Intentional difference**: main needs a manual start after every reboot. |
| Later updates | UI / API | Unchanged from main: Sensor → Rules → Update, overrides, reload. |

### Audit trail difference
Main's `run_rules_update` writes `rule_sources` status rows and an audit entry because an admin triggered it.
The installer's initial `ruleset.deploy()` is not a user action, so it writes no audit/DB rows; it is recorded in
the redacted install log instead. The optional online update at install time DOES go through
`run_rules_update`, so its `rule_sources` rows are written exactly like main (actor = none).

### Rotation
`eve.json`: main ships `docker/suricata/logrotate.conf` (copytruncate, 512 MB × 5) but never runs logrotate. The
release helper image installs that same file and runs `logrotate` every 15 min (`helper-start.sh`). M5's tailer
handles copytruncate (`backend/app/pipeline/tailer.py:9-16`). Docker json-file logs: 10 MB × 5 per container.

## Verification (needs Docker + a VM; see tests/vm/detection-check.sh)
- Fresh VM: alert from a second VM → event visible in UI within 2 min.
- Corrupted bundle → `load_bundled_rules` fails, helper keeps the previous ruleset (main's rollback).
- Offline VM: install completes, detection works, intel feeds show a clean error state.
