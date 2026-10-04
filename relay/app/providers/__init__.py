"""Provider adapter layer. Switch providers by changing relay config only
(RELAY_PROVIDER + that provider's server-side env). Nothing here is shipped to
installs."""

from __future__ import annotations

from app.config import settings
from app.providers.base import Provider
from app.providers.fake import FakeProvider


def get_provider() -> Provider:
    name = settings.provider.lower()
    if name == "brevo":
        from app.providers.brevo import BrevoProvider
        return BrevoProvider()
    return FakeProvider()
