"""Fake provider for local/dev/e2e. Records sent mail in memory and (if
RELAY_FAKE_OUTBOX is set) appends a JSON line per send so tests can assert
delivery. Never contacts the network."""

from __future__ import annotations

import json
import os
import uuid

from app.providers.base import Outgoing, Provider

SENT: list[dict] = []


class FakeProvider(Provider):
    name = "fake"

    def send(self, msg: Outgoing) -> str:
        mid = f"fake-{uuid.uuid4().hex[:12]}"
        rec = {"id": mid, "to": msg.to, "subject": msg.subject, "tag": msg.tag}
        SENT.append(rec)
        path = os.getenv("RELAY_FAKE_OUTBOX")
        if path:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec) + "\n")
        return mid
