"""Typed ChatGPT presentation and cancellable sign-in; tokens stay in Rust."""

from __future__ import annotations

import threading
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    from ._native.parakatt_core import (
        ChatGptAccount,
        ChatGptModelChoice,
        ChatGptSignIn,
        ChatGptSignOut,
    )


class AccountService(Protocol):
    def list(self) -> list[ChatGptAccount]: ...
    def select(self, account_id: str) -> None: ...
    def begin_sign_in(self, account_id: str | None) -> ChatGptSignIn: ...
    def complete_sign_in(self, attempt_id: str) -> ChatGptAccount: ...
    def cancel_sign_in(self, attempt_id: str) -> None: ...
    def sign_out(self, account_id: str | None) -> ChatGptSignOut: ...
    def retry(self, account_id: str | None) -> None: ...
    def models(self, account_id: str | None) -> list[ChatGptModelChoice]: ...
    def take_plan_confirmation(self, account_id: str) -> bool: ...


class SignInRequest:
    """Cancel even when begin_sign_in hasn't returned an attempt ID yet."""

    _begin_lock = threading.Lock()

    def __init__(self, service: AccountService, account_id: str | None) -> None:
        self.service = service
        self.account_id = account_id
        self._lock = threading.Lock()
        self._cancelled = False
        self._attempt_id: str | None = None

    def begin(self) -> ChatGptSignIn | None:
        with self._begin_lock:
            with self._lock:
                if self._cancelled:
                    return None
            attempt = self.service.begin_sign_in(self.account_id)
            with self._lock:
                self._attempt_id = attempt.id
                if self._cancelled:
                    self.service.cancel_sign_in(attempt.id)
                    return None
                return attempt

    def complete(self) -> ChatGptAccount:
        with self._lock:
            if self._cancelled or self._attempt_id is None:
                raise RuntimeError("Sign-in cancelled.")
            attempt_id = self._attempt_id
        return self.service.complete_sign_in(attempt_id)

    def cancel(self) -> None:
        with self._lock:
            self._cancelled = True
            if self._attempt_id is not None:
                self.service.cancel_sign_in(self._attempt_id)


def account_name(account: ChatGptAccount, accounts: list[ChatGptAccount]) -> str:
    def name(item: ChatGptAccount) -> str:
        suffix = f" ({item.id})"
        return item.label.removesuffix(suffix)

    matches = [item.id for item in accounts if name(item) == name(account)]
    label = name(account)
    return f"{label} — Account {matches.index(account.id) + 1}" if len(matches) > 1 else label


def account_status(account: ChatGptAccount | None) -> str:
    if account is None or not account.signed_in:
        return "Not connected"
    if not account.plan_enabled:
        return "Permission needed"
    return "Usage paused" if account.paused else "Connected"


BASIC_MODES = ("dictation", "punctuation", "clean")
BUILTIN_MODES = (*BASIC_MODES, "email", "code")


def cleanup_title(mode: str) -> str:
    return {
        "dictation": "Off",
        "punctuation": "Punctuation",
        "clean": "Grammar + punctuation",
        "email": "Email",
        "code": "Code",
    }.get(mode.lower(), f"Custom: {mode}")


def cleanup_description(mode: str) -> str:
    return {
        "dictation": "Transcription and dictionary corrections only. No AI request.",
        "punctuation": "Adjust punctuation, capitalization, and spacing without changing your words.",
        "clean": "Correct grammar, spelling, and punctuation while preserving your meaning.",
        "email": "Format your words as an email using the configured provider.",
        "code": "Use code-aware processing with the configured provider.",
    }.get(mode.lower(), "Use the instructions defined for this custom mode.")
