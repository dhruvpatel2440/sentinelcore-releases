# Static parity report

source: `Sentinelcore-main` (read-only)

summary: ALLOWED 38, DEFAULT 61, DISCREPANCY (main) 1, NOT RUN 2, PASS 147

| Area | Item | Status | Detail |
|---|---|---|---|
| compose | volume postgres_data | PASS |  |
| compose | volume redis_data | PASS |  |
| compose | volume helper_socket | PASS |  |
| compose | volume rule_staging | PASS |  |
| compose | volume suricata_rules | PASS |  |
| compose | volume suricata_logs | PASS |  |
| compose | volume suricata_run | PASS |  |
| compose | volume report_storage | PASS |  |
| compose | volume pcap_storage | PASS |  |
| compose | backend.cap_drop | PASS | ['ALL'] |
| compose | backend.security_opt | PASS | ['no-new-privileges:true'] |
| compose | backend.expose | PASS | ['8000'] |
| compose | backend.networks | PASS | ['sentinelcore-network'] |
| compose | backend.env_file | PASS | .env |
| compose | backend.image | ALLOWED | pinned image from the bundled tarball (tag = package VERSION) instead of `build:` (sentinelcore/backend:X.Y.Z) |
| compose | backend.env DATABASE_URL | PASS |  |
| compose | backend.env HELPER_SOCKET_PATH | PASS |  |
| compose | backend.env REDIS_URL | PASS |  |
| compose | backend.env SSL_CERT_FILE | ALLOWED | email overlay only (httpx honours SSL_CERT_FILE) |
| compose | backend.volume /app | ALLOWED | no code bind mount: code is baked into the image |
| compose | backend.volume /etc/sentinelcore/ca-bundle.pem | ALLOWED | email overlay only: CA bundle so httpx trusts the relay shim |
| compose | backend.volume /run/sentinelcore | PASS | helper_socket |
| compose | backend.volume /var/lib/sentinelcore/pcap | PASS | pcap_storage |
| compose | backend.volume /var/lib/sentinelcore/reports | PASS | report_storage |
| compose | backend.volume /var/lib/sentinelcore/staging | PASS | rule_staging |
| compose | backend.volume /var/log/suricata | PASS | suricata_logs |
| compose | backend.command | ALLOWED | main's CMD minus --reload (production) |
| compose | backend.depends_on | PASS | {'db': {'condition': 'service_healthy'}, 'redis': {'condition': 'service_healthy'}} |
| compose | backend.restart | ALLOWED | release sets restart: unless-stopped on every long-running service |
| compose | backend.healthcheck | ALLOWED | release adds healthchecks; the installer waits until every service is healthy |
| compose | backend.logging | ALLOWED | release adds docker log rotation (10 MB x 5) to prevent disk fill |
| compose | backend.pull_policy | ALLOWED | sentinelcore/* images come only from the bundled tarball |
| compose | db.networks | PASS | ['sentinelcore-network'] |
| compose | db.env_file | PASS | .env |
| compose | db.image | PASS | postgres:16-alpine |
| compose | db.env POSTGRES_DB | PASS |  |
| compose | db.env POSTGRES_PASSWORD | PASS |  |
| compose | db.env POSTGRES_USER | PASS |  |
| compose | db.volume /var/lib/postgresql/data | PASS | postgres_data |
| compose | db.ports | PASS | ['127.0.0.1:5433:5432'] |
| compose | db.restart | ALLOWED | release sets restart: unless-stopped on every long-running service |
| compose | db.healthcheck | PASS | {'test': ['CMD-SHELL', 'pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}'], 'interval': '5s', 'timeout': '5s', 'retries': 10} |
| compose | db.logging | ALLOWED | release adds docker log rotation (10 MB x 5) to prevent disk fill |
| compose | service frontend | ALLOWED | static frontend: built once (npm ci && vite build) and served by nginx; no Vite dev server in production |
| compose | helper.cap_add | PASS | ['CHOWN', 'NET_ADMIN', 'NET_RAW', 'SYS_NICE'] |
| compose | helper.cap_drop | PASS | ['ALL'] |
| compose | helper.network_mode | PASS | host |
| compose | helper.env_file | PASS | .env |
| compose | helper.image | ALLOWED | pinned image from the bundled tarball (tag = package VERSION) instead of `build:` (sentinelcore/helper:X.Y.Z) |
| compose | helper.volume /etc/suricata/suricata.yaml | ALLOWED | rendered per install (HOME_NET + capture NIC) instead of the dev file |
| compose | helper.volume /run/sentinelcore | PASS | helper_socket |
| compose | helper.volume /var/lib/sentinelcore/staging | PASS | rule_staging |
| compose | helper.volume /var/lib/suricata/rules | PASS | suricata_rules |
| compose | helper.volume /var/log/suricata | PASS | suricata_logs |
| compose | helper.volume /var/run/suricata | PASS | suricata_run |
| compose | helper.restart | PASS | unless-stopped |
| compose | helper.healthcheck | ALLOWED | release adds healthchecks; the installer waits until every service is healthy |
| compose | helper.logging | ALLOWED | release adds docker log rotation (10 MB x 5) to prevent disk fill |
| compose | helper.pull_policy | ALLOWED | sentinelcore/* images come only from the bundled tarball |
| compose | nginx.networks | PASS | ['sentinelcore-network'] |
| compose | nginx.image | PASS | nginx:1.27-alpine |
| compose | nginx.env TZ | ALLOWED | container timezone for log timestamps |
| compose | nginx.volume /etc/nginx/conf.d/default.conf | ALLOWED | release nginx config (HTTPS, static UI, headers, upload limit) |
| compose | nginx.volume /etc/nginx/tls | ALLOWED | TLS overlay: server certificate |
| compose | nginx.volume /usr/share/nginx/html | ALLOWED | static frontend build served by nginx |
| compose | nginx.ports | ALLOWED | installer-chosen bind address + ports; HTTPS 443 (TLS overlay), HTTP only redirects |
| compose | nginx.depends_on | ALLOWED | no frontend service; waits for a healthy backend |
| compose | nginx.restart | ALLOWED | release sets restart: unless-stopped on every long-running service |
| compose | nginx.healthcheck | ALLOWED | release adds healthchecks; the installer waits until every service is healthy |
| compose | nginx.logging | ALLOWED | release adds docker log rotation (10 MB x 5) to prevent disk fill |
| compose | redis.networks | PASS | ['sentinelcore-network'] |
| compose | redis.image | PASS | redis:7.4-alpine |
| compose | redis.env TZ | ALLOWED | container timezone for log timestamps |
| compose | redis.volume /data | PASS | redis_data |
| compose | redis.command | PASS | ['redis-server', '--appendonly', 'yes'] |
| compose | redis.restart | ALLOWED | release sets restart: unless-stopped on every long-running service |
| compose | redis.healthcheck | PASS | {'test': ['CMD', 'redis-cli', 'ping'], 'interval': '5s', 'timeout': '3s', 'retries': 10} |
| compose | redis.logging | ALLOWED | release adds docker log rotation (10 MB x 5) to prevent disk fill |
| compose | service relay-shim | ALLOWED | release-only email bridge (email overlay, only when email is enabled) |
| compose | worker.cap_drop | PASS | ['ALL'] |
| compose | worker.security_opt | PASS | ['no-new-privileges:true'] |
| compose | worker.networks | PASS | ['sentinelcore-network'] |
| compose | worker.env_file | PASS | .env |
| compose | worker.image | ALLOWED | pinned image from the bundled tarball (tag = package VERSION) instead of `build:` (sentinelcore/backend:X.Y.Z) |
| compose | worker.env DATABASE_URL | PASS |  |
| compose | worker.env HELPER_SOCKET_PATH | PASS |  |
| compose | worker.env REDIS_URL | PASS |  |
| compose | worker.env RUN_MIGRATIONS | PASS |  |
| compose | worker.env SSL_CERT_FILE | ALLOWED | email overlay only (httpx honours SSL_CERT_FILE) |
| compose | worker.volume /app | ALLOWED | no code bind mount: code is baked into the image |
| compose | worker.volume /etc/sentinelcore/ca-bundle.pem | ALLOWED | email overlay only: CA bundle so httpx trusts the relay shim |
| compose | worker.volume /run/sentinelcore | PASS | helper_socket |
| compose | worker.volume /var/lib/sentinelcore/pcap | PASS | pcap_storage |
| compose | worker.volume /var/lib/sentinelcore/reports | PASS | report_storage |
| compose | worker.volume /var/log/suricata | PASS | suricata_logs |
| compose | worker.command | PASS | ['python', '-m', 'app.pipeline.worker'] |
| compose | worker.depends_on | PASS | {'db': {'condition': 'service_healthy'}, 'redis': {'condition': 'service_healthy'}} |
| compose | worker.restart | PASS | unless-stopped |
| compose | worker.healthcheck | ALLOWED | release adds healthchecks; the installer waits until every service is healthy |
| compose | worker.logging | ALLOWED | release adds docker log rotation (10 MB x 5) to prevent disk fill |
| compose | worker.pull_policy | ALLOWED | sentinelcore/* images come only from the bundled tarball |
| env | .env.example ACCESS_TOKEN_EXPIRE_MINUTES | PASS | set by the release |
| env | .env.example APP_BASE_URL | PASS | set by the release |
| env | .env.example BREVO_API_KEY | PASS | set by the release |
| env | .env.example BREVO_WEBHOOK_SECRET | PASS | set by the release |
| env | .env.example CAPTURE_INTERFACE | PASS | set by the release |
| env | .env.example DATABASE_URL | PASS | set by the release |
| env | .env.example EMAIL_ALLOWED_RECIPIENT_DOMAINS | PASS | set by the release |
| env | .env.example EMAIL_DAILY_CAP_PER_RECIPIENT | PASS | set by the release |
| env | .env.example EMAIL_GLOBAL_DAILY_CAP | PASS | set by the release |
| env | .env.example EMAIL_MAX_ATTACHMENT_MB | PASS | set by the release |
| env | .env.example EMAIL_MODE | PASS | set by the release |
| env | .env.example EMAIL_REPLY_TO | PASS | set by the release |
| env | .env.example EMAIL_SENDER_ADDRESS | PASS | set by the release |
| env | .env.example EMAIL_SENDER_NAME | PASS | set by the release |
| env | .env.example ENVIRONMENT | PASS | set by the release |
| env | .env.example EVENT_RETENTION_DAYS | PASS | set by the release |
| env | .env.example LOGIN_LOCKOUT_SECONDS | PASS | set by the release |
| env | .env.example LOGIN_MAX_ATTEMPTS | PASS | set by the release |
| env | .env.example MONITORED_NETWORK | PASS | set by the release |
| env | .env.example POSTGRES_DB | PASS | set by the release |
| env | .env.example POSTGRES_PASSWORD | PASS | set by the release |
| env | .env.example POSTGRES_USER | PASS | set by the release |
| env | .env.example PROTECTED_IPS | PASS | set by the release |
| env | .env.example REDIS_URL | PASS | set by the release |
| env | .env.example REFRESH_TOKEN_EXPIRE_DAYS | PASS | set by the release |
| env | .env.example SECRET_KEY | PASS | set by the release |
| env | .env.example SEED_ADMIN_EMAIL | PASS | set by the release |
| env | .env.example SEED_ADMIN_PASSWORD | ALLOWED | never stored: passed once via the process environment of a one-shot `docker compose run` (installer/lib/admin.sh) |
| env | .env.example SEED_ADMIN_USERNAME | PASS | set by the release |
| env | .env.example SURICATA_EVE_LOG | PASS | set by the release |
| env | backend ACCESS_TOKEN_EXPIRE_MINUTES | PASS | set by the release |
| env | backend APP_BASE_URL | PASS | set by the release |
| env | backend AUTO_PROMOTE_SCORE | DEFAULT | same code default as main: 70 |
| env | backend BREVO_API_KEY | PASS | set by the release |
| env | backend BREVO_WEBHOOK_SECRET | PASS | set by the release |
| env | backend CAPTURE_INTERFACE | PASS | set by the release |
| env | backend CORRELATION_CANDIDATES_CHANNEL | DEFAULT | same code default as main: 'correlation:candidates' |
| env | backend CORRELATION_INTERVAL_SECONDS | DEFAULT | same code default as main: 30 |
| env | backend CORRELATION_LOOKBACK_GRACE_SECONDS | DEFAULT | same code default as main: 60 |
| env | backend CORRELATION_MAX_CONCURRENT_RULES | DEFAULT | same code default as main: 4 |
| env | backend CORRELATION_RULE_TIMEOUT_SECONDS | DEFAULT | same code default as main: 60 |
| env | backend DATABASE_URL | PASS | set by the release |
| env | backend EMAIL_ALLOWED_RECIPIENT_DOMAINS | PASS | set by the release |
| env | backend EMAIL_DAILY_CAP_PER_RECIPIENT | PASS | set by the release |
| env | backend EMAIL_GLOBAL_DAILY_CAP | PASS | set by the release |
| env | backend EMAIL_HEALTH_SCAN_INTERVAL_SECONDS | DEFAULT | same code default as main: 60 |
| env | backend EMAIL_MAX_ATTACHMENT_MB | PASS | set by the release |
| env | backend EMAIL_MODE | PASS | set by the release |
| env | backend EMAIL_OUTBOX_DRAIN_INTERVAL_SECONDS | DEFAULT | same code default as main: 5 |
| env | backend EMAIL_OUTBOX_REAPER_STUCK_MINUTES | DEFAULT | same code default as main: 5 |
| env | backend EMAIL_OUTBOX_RETENTION_FAILED_DAYS | DEFAULT | same code default as main: 90 |
| env | backend EMAIL_OUTBOX_RETENTION_SENT_DAYS | DEFAULT | same code default as main: 30 |
| env | backend EMAIL_REPLY_TO | PASS | set by the release |
| env | backend EMAIL_SENDER_ADDRESS | PASS | set by the release |
| env | backend EMAIL_SENDER_NAME | PASS | set by the release |
| env | backend EMAIL_SEND_EMPTY_DIGEST | DEFAULT | same code default as main: False |
| env | backend ENVIRONMENT | PASS | set by the release |
| env | backend EVENT_RETENTION_DAYS | PASS | set by the release |
| env | backend FIREWALL_EXPIRY_ALERT_AFTER_ATTEMPTS | DEFAULT | same code default as main: 5 |
| env | backend FIREWALL_EXPIRY_INTERVAL_SECONDS | DEFAULT | same code default as main: 15 |
| env | backend FIREWALL_RECONCILE_INTERVAL_SECONDS | DEFAULT | same code default as main: 300 |
| env | backend HELPER_SOCKET_PATH | PASS | set by the release |
| env | backend INCIDENT_MERGE_WINDOW_MINUTES | DEFAULT | same code default as main: 60 |
| env | backend INCIDENT_SLA_MINUTES_CRITICAL | DEFAULT | same code default as main: 15 |
| env | backend INCIDENT_SLA_MINUTES_HIGH | DEFAULT | same code default as main: 60 |
| env | backend INCIDENT_SLA_MINUTES_MEDIUM | DEFAULT | same code default as main: 240 |
| env | backend INTEL_EXPIRY_INTERVAL_SECONDS | DEFAULT | same code default as main: 3600 |
| env | backend INTEL_FEED_MAX_RESPONSE_MB | DEFAULT | same code default as main: 50 |
| env | backend INTEL_FEED_ROW_CAP | DEFAULT | same code default as main: 200000 |
| env | backend INTEL_FEED_SCHEDULER_INTERVAL_SECONDS | DEFAULT | same code default as main: 300 |
| env | backend INTEL_FEED_TIMEOUT_SECONDS | DEFAULT | same code default as main: 30 |
| env | backend INTEL_MATCH_EMAIL_MIN_CONFIDENCE | DEFAULT | same code default as main: 70 |
| env | backend JWT_ALGORITHM | DEFAULT | same code default as main: 'HS256' |
| env | backend LOGIN_LOCKOUT_SECONDS | PASS | set by the release |
| env | backend LOGIN_MAX_ATTEMPTS | PASS | set by the release |
| env | backend MAX_ACTIVE_BLOCKS | DEFAULT | same code default as main: 100 |
| env | backend MAX_CONCURRENT_REPORTS_PER_USER | DEFAULT | same code default as main: 3 |
| env | backend MAX_FLOWS_PER_PCAP | DEFAULT | same code default as main: 50000 |
| env | backend MAX_PCAP_SIZE_MB | DEFAULT | same code default as main: 500 |
| env | backend MAX_REPORT_WINDOW_DAYS | DEFAULT | same code default as main: 365 |
| env | backend MAX_SEARCH_WINDOW_DAYS | DEFAULT | same code default as main: 30 |
| env | backend MONITORED_NETWORK | PASS | set by the release |
| env | backend PCAP_PARSE_TIMEOUT_SECONDS | DEFAULT | same code default as main: 300 |
| env | backend PCAP_QUEUE_KEY | DEFAULT | same code default as main: 'pcap:queue' |
| env | backend PCAP_RETENTION_DAYS | DEFAULT | same code default as main: 30 |
| env | backend PCAP_STORAGE_PATH | DEFAULT | same code default as main: '/var/lib/sentinelcore/pcap' |
| env | backend PCAP_UPLOAD_CHUNK_BYTES | DEFAULT | same code default as main: 1024 * 1024 |
| env | backend PROTECTED_IPS | PASS | set by the release |
| env | backend REDIS_URL | PASS | set by the release |
| env | backend REFRESH_TOKEN_EXPIRE_DAYS | PASS | set by the release |
| env | backend REPORT_GENERATION_TIMEOUT_SECONDS | DEFAULT | same code default as main: 600 |
| env | backend REPORT_QUEUE_KEY | DEFAULT | same code default as main: 'reports:queue' |
| env | backend REPORT_RETENTION_DAYS | DEFAULT | same code default as main: 30 |
| env | backend REPORT_STORAGE_PATH | DEFAULT | same code default as main: '/var/lib/sentinelcore/reports' |
| env | backend SEARCH_FACET_CACHE_SECONDS | DEFAULT | same code default as main: 30 |
| env | backend SECRET_KEY | PASS | set by the release |
| env | backend SURICATA_EVE_LOG | PASS | set by the release |
| env | backend SURICATA_STAGING_DIR | DEFAULT | same code default as main: '/var/lib/sentinelcore/staging' |
| env | helper CAPTURE_INTERFACE | PASS | set by the release |
| env | helper DNS_SERVERS | DEFAULT | same code default as main |
| env | helper FIREWALL_CHAIN | DEFAULT | same code default as main |
| env | helper HELPER_ARP_TIMEOUT | DEFAULT | same code default as main |
| env | helper HELPER_FIREWALL_TIMEOUT | DEFAULT | same code default as main |
| env | helper HELPER_NMAP_TIMEOUT | DEFAULT | same code default as main |
| env | helper HELPER_OP_TIMEOUT | DEFAULT | same code default as main |
| env | helper HELPER_SOCKET_GROUP | DEFAULT | same code default as main |
| env | helper HELPER_SOCKET_PATH | PASS | set by the release |
| env | helper HELPER_SURICATA_TEST_TIMEOUT | DEFAULT | same code default as main |
| env | helper IPTABLES_PATH | DEFAULT | same code default as main |
| env | helper IP_PATH | DEFAULT | same code default as main |
| env | helper MONITORED_NETWORK | PASS | set by the release |
| env | helper NMAP_PATH | DEFAULT | same code default as main |
| env | helper PROTECTED_IPS | PASS | set by the release |
| env | helper SURICATASC_PATH | DEFAULT | same code default as main |
| env | helper SURICATA_COMMAND_SOCKET | DEFAULT | same code default as main |
| env | helper SURICATA_CONFIG | DEFAULT | same code default as main |
| env | helper SURICATA_PATH | DEFAULT | same code default as main |
| env | helper SURICATA_PID_FILE | DEFAULT | same code default as main |
| env | helper SURICATA_RULES_DIR | DEFAULT | same code default as main |
| env | helper SURICATA_STAGING_DIR | DEFAULT | same code default as main |
| packages | backend apt | PASS | main's 9 packages all present; extra: ['ca-certificates', 'tzdata'] |
| packages | backend pip source | PASS | installs main's own requirements.txt (copied from SOURCE) |
| packages | backend base image | PASS | main python:3.11-slim (floating) -> release python:3.11-slim-trixie, pinned by digest at build |
| packages | helper apt | PASS | main's 8 packages all present |
| packages | helper pip source | PASS | installs main's own requirements.txt (copied from SOURCE) |
| packages | helper base image | PASS | main python:3.11-slim (floating) -> release python:3.11-slim-trixie, pinned by digest at build |
| packages | pydyf pin | PASS | pydyf==0.10.0 |
| packages | pip freeze vs requirements | NOT RUN | needs build evidence (dist/<pkg>-build-evidence/SBOM.txt) |
| nginx | nginx-tls.conf.template /api/ proxy_pass | PASS | no trailing slash: /api prefix preserved (refresh cookie Path=/api/auth) |
| nginx | nginx-tls.conf.template upload limit | PASS | nginx 501m on /api/pcap/upload >= backend max_pcap_size_mb=500 (backend returns the clean 413) |
| nginx | nginx-tls.conf.template X-Forwarded-For | PASS | backend reads X-Forwarded-For for audit/lockout IPs (same as main) |
| nginx | nginx-http.conf.template /api/ proxy_pass | PASS | no trailing slash: /api prefix preserved (refresh cookie Path=/api/auth) |
| nginx | nginx-http.conf.template upload limit | PASS | nginx 501m on /api/pcap/upload >= backend max_pcap_size_mb=500 (backend returns the clean 413) |
| nginx | nginx-http.conf.template X-Forwarded-For | PASS | backend reads X-Forwarded-For for audit/lockout IPs (same as main) |
| nginx | main upload limit | DISCREPANCY (main) | main nginx caps every body at 20m although the backend accepts 500 MB PCAPs — uploads > 20 MB fail on main; the release fixes this only for /api/pcap/upload (main unchanged) |
| suricata | suricata.yaml vs main | PASS | only HOME_NET + af-packet interface templated (4 changed lines) |
| schema | alembic migrations in image | PASS | all 14 main migrations copied into the backend image; backend entrypoint runs `alembic upgrade head` |
| schema | pg_dump --schema-only diff | NOT RUN | needs schema-release.sql (build evidence) and --main-schema |
| security | helper not privileged | PASS |  |
| security | redis publishes no port | PASS |  |
| security | backend publishes no port | PASS |  |
| security | worker publishes no port | PASS |  |
| security | helper publishes no port | PASS |  |
| security | relay-shim publishes no port | PASS |  |
| security | db port loopback only | PASS | ['127.0.0.1:5433:5432'] |
| security | ENVIRONMENT=production | PASS | hides /api/docs, Secure refresh cookie |
| security | nginx-tls.conf.template security headers | PASS |  |
| security | nginx-http.conf.template security headers | PASS |  |

RESULT: CLEAN (no unexplained differences)
