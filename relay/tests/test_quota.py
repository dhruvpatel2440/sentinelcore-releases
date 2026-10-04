import os
import tempfile

from app.db import Store
from app.quota import SlidingWindow


def test_sliding_window_blocks_over_limit():
    w = SlidingWindow(max_events=3, window_seconds=60)
    assert w.allow("k")
    assert w.allow("k")
    assert w.allow("k")
    assert not w.allow("k")           # 4th in the window is blocked
    assert w.allow("other")           # independent key


def test_daily_counter_increments_and_totals():
    path = os.path.join(tempfile.mkdtemp(prefix="relay-quota-"), "q.db")
    s = Store(path)
    tok, glob = s.incr_daily("hashA")
    assert (tok, glob) == (1, 1)
    tok, glob = s.incr_daily("hashA")
    assert (tok, glob) == (2, 2)
    tok, glob = s.incr_daily("hashB")
    assert tok == 1 and glob == 3     # global sums across tokens
    assert s.daily_count("hashA") == 2
