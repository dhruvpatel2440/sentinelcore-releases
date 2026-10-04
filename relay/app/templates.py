"""Approved template allowlist. The strict /v1/send endpoint renders ONLY these
ids from server-side templates (no arbitrary HTML). Ids mirror the app's email
types E01..E21 (see SentinelCore app/models/email.py). Variables are escaped."""

from __future__ import annotations

import html
import re

# id -> (subject template, text body template). {var} placeholders are filled
# from the caller's `variables` dict; missing vars render as empty.
APPROVED: dict[str, tuple[str, str]] = {
    "E01": ("New incident: {title}", "A new incident was raised: {title}\nSeverity: {severity}\n{link}"),
    "E02": ("Incident escalated: {title}", "Incident escalated to {severity}: {title}\n{link}"),
    "E03": ("Incident assigned: {title}", "An incident was assigned to you: {title}\n{link}"),
    "E04": ("SLA reminder: {title}", "SLA reminder for incident {title} ({severity}).\n{link}"),
    "E05": ("Incident resolved: {title}", "Incident resolved: {title}\n{link}"),
    "E06": ("Threat intel match", "A threat-intel match was observed.\n{link}"),
    "E07": ("Firewall block applied", "A containment block was applied to {target}.\n{link}"),
    "E08": ("Firewall block expiring", "A containment block on {target} is expiring.\n{link}"),
    "E09": ("Firewall block expired", "A containment block on {target} has expired.\n{link}"),
    "E10": ("Firewall block refused", "A containment block was refused for {target}.\n{link}"),
    "E11": ("Report delivered", "Your report is delivered.\n{link}"),
    "E12": ("Report ready", "Your report is ready.\n{link}"),
    "E13": ("Report failed", "A report failed to generate.\n{link}"),
    "E14": ("SentinelCore digest", "Your activity digest.\n{link}"),
    "E15": ("Sensor health alert", "Sensor health changed: {status}.\n{link}"),
    "E16": ("Pipeline backlog", "The event pipeline is backlogged.\n{link}"),
    "E17": ("Threat feed failing", "A threat feed is failing.\n{link}"),
    "E18": ("Firewall drift detected", "Firewall drift detected.\n{link}"),
    "E19": ("Your password was changed", "Your SentinelCore password was changed.\n{link}"),
    "E20": ("Your account changed", "Your SentinelCore account was changed.\n{link}"),
    "E21": ("Suspicious login", "A suspicious login was detected.\n{link}"),
}

_ID_RE = re.compile(r"^E\d{2}$")


def is_allowed_id(template_id: str) -> bool:
    """Accept the known ids, and any well-formed E## tag the app may send."""
    return bool(_ID_RE.match(template_id or "")) and template_id in APPROVED


def is_allowed_tag(tag: str) -> bool:
    """Looser check for the Brevo-shim path: a well-formed E## tag."""
    return bool(_ID_RE.match(tag or ""))


def render(template_id: str, variables: dict) -> tuple[str, str, str]:
    """Return (subject, text, html). Variables are HTML-escaped for the html
    body and used verbatim (but allowlisted keys only) for subject/text."""
    subj_t, text_t = APPROVED[template_id]
    safe = {k: str(v) for k, v in (variables or {}).items()}

    class _D(dict):
        def __missing__(self, k):  # noqa: D401
            return ""

    subject = subj_t.format_map(_D(safe))
    text = text_t.format_map(_D(safe))
    esc = {k: html.escape(v) for k, v in safe.items()}
    body_html = "<p>" + text_t.format_map(_D(esc)).replace("\n", "<br>") + "</p>"
    return subject, text, body_html
