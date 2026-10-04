"""Provider interface. Implementations send one transactional email and return
a provider message id, or raise ProviderError."""

from __future__ import annotations

from dataclasses import dataclass


class ProviderError(Exception):
    def __init__(self, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.retryable = retryable


@dataclass
class Outgoing:
    to: str
    subject: str
    text: str
    html: str
    tag: str


class Provider:
    name = "base"

    def send(self, msg: Outgoing) -> str:  # pragma: no cover - interface
        raise NotImplementedError
