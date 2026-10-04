from app import templates


def test_allowlist():
    assert templates.is_allowed_id("E01")
    assert templates.is_allowed_id("E21")
    assert not templates.is_allowed_id("E99")     # well-formed but not defined
    assert not templates.is_allowed_id("DROP")
    assert not templates.is_allowed_id("")
    # looser tag check for the shim path
    assert templates.is_allowed_tag("E07")
    assert not templates.is_allowed_tag("sentinelcore")


def test_render_fills_vars_and_escapes_html():
    subject, text, body_html = templates.render("E01", {"title": "<b>pwn</b>", "severity": "high", "link": "x"})
    assert "pwn" in subject            # subject uses raw (not HTML context)
    assert "high" in text
    assert "&lt;b&gt;pwn&lt;/b&gt;" in body_html   # escaped in HTML body
    assert "<b>pwn</b>" not in body_html


def test_render_missing_vars_are_blank():
    subject, text, body_html = templates.render("E05", {})
    assert "{" not in subject and "}" not in subject
    assert "{" not in text
