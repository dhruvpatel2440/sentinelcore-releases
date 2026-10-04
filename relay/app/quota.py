"""In-memory sliding-window rate limiters (per-IP registration, per-token send)
plus daily quota checks backed by the DB. In-memory state is per-process; for a
multi-replica deploy, front with one replica or move these to Redis. The daily
quota (the hard cap) is always DB-backed and correct across restarts."""

from __future__ import annotations

import threading
import time
from collections import defaultdict, deque


class SlidingWindow:
    def __init__(self, max_events: int, window_seconds: int) -> None:
        self.max = max_events
        self.window = window_seconds
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            dq = self._hits[key]
            while dq and dq[0] <= now - self.window:
                dq.popleft()
            if len(dq) >= self.max:
                return False
            dq.append(now)
            return True
