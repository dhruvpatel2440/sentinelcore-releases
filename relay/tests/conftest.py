"""Test environment: isolate the relay DB and force the fake provider BEFORE
app.config.settings is instantiated (it reads env at import time)."""

import os
import tempfile

_tmp = tempfile.mkdtemp(prefix="relay-test-")
os.environ.setdefault("RELAY_DB_PATH", os.path.join(_tmp, "relay.db"))
os.environ.setdefault("RELAY_PROVIDER", "fake")
os.environ.setdefault("RELAY_ADMIN_SECRET", "test-admin-secret")
os.environ.setdefault("RELAY_PUBLIC_URL", "http://relay.test")
# Generous limits so functional tests don't trip quotas; dedicated tests set
# their own tight limits by calling the primitives directly.
os.environ.setdefault("RELAY_DAILY_QUOTA_PER_TOKEN", "1000")
os.environ.setdefault("RELAY_SEND_RATE_PER_TOKEN_MIN", "1000")
os.environ.setdefault("RELAY_REGISTER_RATE_PER_IP_HOUR", "1000")
