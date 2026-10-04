# shellcheck shell=bash
# backup.sh — backup / restore of an installed SentinelCore, and the optional
# nightly systemd timer. Used by bin/backup.sh, bin/restore.sh and install.sh.
#
# Archive (single .tar.gz, mode 600, + .sha256):
#   MANIFEST            version, date, host, contents, per-file sha256
#   db.dump             pg_dump -Fc of the application database
#   env/.env            the deployed .env (SECRETS: DB password, SECRET_KEY, relay token)
#   certs/              tls-web/, tls-web-ca.crt, tls/ (shim leaf), ca.crt, ca-bundle.pem
#   volumes/reports.tar generated reports (M9)
#   volumes/rules.tar   live Suricata ruleset (incl. admin updates)
#   volumes/pcap.tar    uploaded captures (M11) — only with --with-pcaps

BACKUP_DIR_DEFAULT="${INSTALL_DIR:-/opt/sentinelcore}/backups"
BACKUP_UNIT="/etc/systemd/system/sentinelcore-backup.service"
BACKUP_TIMER="/etc/systemd/system/sentinelcore-backup.timer"
# Keys carried over from a backup's .env on restore (data-bound secrets).
# Install-specific keys (DB password, ports, NIC, TLS mode) stay as installed.
RESTORE_ENV_KEYS="SECRET_KEY BREVO_API_KEY RELAY_INSTALL_ID EMAIL_SENDER_ADDRESS BREVO_WEBHOOK_SECRET SEED_ADMIN_USERNAME SEED_ADMIN_EMAIL"

do_backup() {
    # do_backup <out-dir> <with-pcaps 0|1> -> prints the archive path.
    local out="$1" pcaps="$2" ver ts work name archive
    ver="$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo unknown)"
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    name="sentinelcore-backup-$ver-$ts"
    as_root install -d -m 0700 "$out"
    work="$(as_root mktemp -d /tmp/sentinelcore-backup.XXXXXX)"; as_root chmod 700 "$work"
    as_root install -d -m 0700 "$work/$name" "$work/$name/env" "$work/$name/certs" "$work/$name/volumes"
    local d="$work/$name"

    info "dumping the database (pg_dump -Fc)..."
    # shellcheck disable=SC2016
    dc exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' | as_root sh -c "umask 077; cat > '$d/db.dump'" \
        || { as_root rm -rf "$work"; err "pg_dump failed"; return 1; }
    as_root test -s "$d/db.dump" || { as_root rm -rf "$work"; err "database dump is empty"; return 1; }

    as_root install -m 0600 "$INSTALL_DIR/.env" "$d/env/.env"
    local c
    for c in tls-web tls tls-web-ca.crt ca.crt ca-bundle.pem; do
        [ -e "$INSTALL_DIR/$c" ] && as_root cp -a "$INSTALL_DIR/$c" "$d/certs/"
    done

    info "archiving reports and the live ruleset..."
    dc exec -T backend tar -C /var/lib/sentinelcore -cf - reports | as_root sh -c "umask 077; cat > '$d/volumes/reports.tar'" \
        || warn "reports could not be archived"
    dc exec -T helper tar -C /var/lib/suricata -cf - rules | as_root sh -c "umask 077; cat > '$d/volumes/rules.tar'" \
        || warn "ruleset could not be archived"
    if [ "$pcaps" = 1 ]; then
        info "archiving PCAPs (can be large)..."
        dc exec -T backend tar -C /var/lib/sentinelcore -cf - pcap | as_root sh -c "umask 077; cat > '$d/volumes/pcap.tar'" \
            || warn "PCAPs could not be archived"
    fi

    {
        printf 'sentinelcore-backup\nversion=%s\ncreated=%s\nhost=%s\nwith_pcaps=%s\n\n' "$ver" "$ts" "$(hostname -s 2>/dev/null || echo '?')" "$pcaps"
        ( cd "$d" && as_root find . -type f ! -name MANIFEST -exec sha256sum {} + | sort -k2 )
    } | as_root sh -c "umask 077; cat > '$d/MANIFEST'"

    archive="$out/$name.tar.gz"
    as_root sh -c "umask 077; tar -C '$work' -czf '$archive' '$name'" || { as_root rm -rf "$work"; err "tar failed"; return 1; }
    as_root chmod 600 "$archive"
    ( cd "$out" && as_root sh -c "sha256sum '$name.tar.gz' > '$name.tar.gz.sha256'" )
    as_root rm -rf "$work"
    printf '%s\n' "$archive"
}

prune_backups() {
    # prune_backups <dir> <keep> — keep the newest N archives.
    local dir="$1" keep="$2" f
    case "$keep" in ''|*[!0-9]*) return 0 ;; esac
    [ "$keep" -ge 1 ] || return 0
    as_root find "$dir" -maxdepth 1 -name 'sentinelcore-backup-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n +"$((keep + 1))" | cut -d' ' -f2- | while IFS= read -r f; do
            as_root rm -f "$f" "$f.sha256"; info "pruned old backup $(basename "$f")"
        done
}

do_restore() {
    # do_restore <archive> — stop app containers, restore DB + volumes + certs
    # + data-bound .env keys, start, wait healthy, start the sensor.
    local archive="$1" work name d
    [ -f "$archive" ] || { err "archive not found: $archive"; return 1; }
    if [ -f "$archive.sha256" ]; then
        ( cd "$(dirname "$archive")" && sha256sum -c --quiet "$(basename "$archive").sha256" ) || { err "archive checksum mismatch"; return 1; }
        good "archive checksum verified"
    else
        warn "no $archive.sha256 next to the archive — integrity not verified"
    fi
    work="$(as_root mktemp -d /tmp/sentinelcore-restore.XXXXXX)"; as_root chmod 700 "$work"
    as_root tar -C "$work" -xzf "$archive" || { as_root rm -rf "$work"; err "cannot extract $archive"; return 1; }
    name="$(as_root ls "$work" | head -1)"; d="$work/$name"
    as_root test -f "$d/MANIFEST" && as_root test -s "$d/db.dump" || { as_root rm -rf "$work"; err "not a SentinelCore backup (no MANIFEST/db.dump)"; return 1; }
    ( cd "$d" && as_root sh -c "sed -n '/^[0-9a-f]\{64\} /p' MANIFEST | sha256sum -c --quiet" ) || { as_root rm -rf "$work"; err "backup contents do not match MANIFEST"; return 1; }
    info "backup: $(as_root sed -n 's/^version=//p' "$d/MANIFEST") from $(as_root sed -n 's/^created=//p' "$d/MANIFEST") ($(as_root sed -n 's/^host=//p' "$d/MANIFEST"))"

    step "Stop application containers"
    xrun dc stop nginx backend worker || true
    xrun dc up -d db redis helper
    wait_healthy db redis helper || { as_root rm -rf "$work"; return 1; }

    step "Restore database"
    # Fresh database, then restore: no leftovers from the current data.
    # shellcheck disable=SC2016
    dc exec -T db sh -c 'dropdb -U "$POSTGRES_USER" --if-exists --force "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"' \
        || { as_root rm -rf "$work"; err "could not recreate the database"; return 1; }
    # shellcheck disable=SC2016
    as_root cat "$d/db.dump" | dc exec -T db sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --exit-on-error' \
        || { as_root rm -rf "$work"; err "pg_restore failed"; return 1; }
    good "database restored"

    step "Restore files"
    local k v
    for k in $RESTORE_ENV_KEYS; do
        v="$(env_get "$d/env/.env" "$k")"
        [ -n "$v" ] && set_env_value "$INSTALL_DIR/.env" "$k" "$v"
    done
    good ".env: restored data-bound keys ($RESTORE_ENV_KEYS); kept this install's DB password, ports, NIC and TLS settings"
    if [ "${RESTORE_CERTS:-1}" = 1 ] && as_root test -d "$d/certs"; then
        for k in tls-web tls tls-web-ca.crt ca.crt ca-bundle.pem; do
            as_root test -e "$d/certs/$k" || continue
            as_root rm -rf "${INSTALL_DIR:?}/$k"; as_root cp -a "$d/certs/$k" "$INSTALL_DIR/$k"
        done
        good "certificates restored"
    fi

    xrun dc up -d backend
    wait_healthy backend || { as_root rm -rf "$work"; return 1; }
    if as_root test -s "$d/volumes/reports.tar"; then
        as_root cat "$d/volumes/reports.tar" | dc exec -T backend tar -C /var/lib/sentinelcore -xf - && good "reports restored"
    fi
    if as_root test -s "$d/volumes/pcap.tar"; then
        as_root cat "$d/volumes/pcap.tar" | dc exec -T backend tar -C /var/lib/sentinelcore -xf - && good "PCAPs restored"
    fi
    if as_root test -s "$d/volumes/rules.tar"; then
        as_root cat "$d/volumes/rules.tar" | dc exec -T helper tar -C /var/lib/suricata -xf - && good "live ruleset restored"
    fi
    as_root rm -rf "$work"

    step "Start all services"
    xrun dc up -d --remove-orphans
    wait_healthy || return 1
    start_sensor || warn "start the sensor from the UI (Sensor → Start)"
    good "restore complete — log in with the accounts and passwords from the backup"
}

backup_timer_units() {
    cat <<EOF
# --- $BACKUP_UNIT
[Unit]
Description=SentinelCore nightly backup
Requires=docker.service
After=docker.service sentinelcore.service

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/bin/backup.sh --quiet --keep 7
EOF
    cat <<EOF
# --- $BACKUP_TIMER
[Unit]
Description=SentinelCore nightly backup (02:30, randomized 30 min)

[Timer]
OnCalendar=*-*-* 02:30:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

install_backup_timer() {
    step "Nightly backups (systemd timer)"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        info "[dry-run] write $BACKUP_UNIT + $BACKUP_TIMER and 'systemctl enable --now sentinelcore-backup.timer'"
        backup_timer_units | sed 's/^/    /'
        return 0
    fi
    backup_timer_units | awk -v u="$BACKUP_UNIT" -v t="$BACKUP_TIMER" '
        /^# --- /{ f = ($3 == u) ? u : t; next } { print > f }'
    as_root chmod 0644 "$BACKUP_UNIT" "$BACKUP_TIMER"
    xrun as_root systemctl daemon-reload
    xrun as_root systemctl enable --now sentinelcore-backup.timer
    good "nightly backup enabled: $BACKUP_DIR_DEFAULT (7 kept, PCAPs excluded)"
}

remove_backup_timer() {
    [ -f "$BACKUP_TIMER" ] || [ -f "$BACKUP_UNIT" ] || return 0
    xrun as_root systemctl disable --now sentinelcore-backup.timer || true
    xrun as_root rm -f "$BACKUP_TIMER" "$BACKUP_UNIT"
    xrun as_root systemctl daemon-reload || true
}

maybe_backup_timer() {
    local want="${NIGHTLY_BACKUP:-}"
    if [ -z "$want" ]; then
        if ask_yesno "Enable nightly backups to $BACKUP_DIR_DEFAULT (keeps 7, excludes PCAPs)?" n; then want=yes; else want=no; fi
    fi
    if [ "$want" = yes ]; then install_backup_timer; else info "nightly backups off — run sudo $INSTALL_DIR/bin/backup.sh any time"; fi
}
