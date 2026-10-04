from app import auth


def test_token_roundtrip():
    t = auth.new_token()
    assert len(t) >= 30
    h = auth.hash_token(t)
    assert len(h) == 64
    assert auth.verify_token(t, h)
    assert not auth.verify_token(t + "x", h)


def test_parse_bearer():
    assert auth.parse_bearer("Bearer abc123") == "abc123"
    assert auth.parse_bearer("bearer abc123") == "abc123"
    assert auth.parse_bearer("Basic abc") is None
    assert auth.parse_bearer("") is None
    assert auth.parse_bearer(None) is None


def test_admin_secret():
    assert auth.check_admin_secret("s3cret", "s3cret")
    assert not auth.check_admin_secret("wrong", "s3cret")
    assert not auth.check_admin_secret("anything", "")  # unset secret denies all
    assert not auth.check_admin_secret("", "s3cret")
