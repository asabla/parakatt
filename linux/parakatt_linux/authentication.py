"""Delegated Teams sign-in and account selection with an OS-keyring token cache."""

from __future__ import annotations

import importlib
import threading
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol, cast
from urllib.parse import urlsplit

from .credentials import CredentialStore, secret_service
from .providers import ProviderError, object_fields

TRANSCRIPT_SCOPE = "https://graph.microsoft.com/OnlineMeetingTranscript.Read.All"
MEETING_SCOPE = "https://graph.microsoft.com/OnlineMeetings.Read"


@dataclass(frozen=True)
class Account:
    id: str
    label: str


@dataclass(frozen=True)
class DevicePrompt:
    code: str
    url: str
    message: str


class TokenCache(Protocol):
    has_state_changed: bool

    def deserialize(self, state: str) -> None: ...
    def serialize(self) -> str: ...


class MicrosoftClient(Protocol):
    def get_accounts(self) -> list[dict[str, object]]: ...
    def remove_account(self, account: dict[str, object]) -> None: ...
    def acquire_token_silent(
        self, scopes: list[str], account: dict[str, object]
    ) -> dict[str, object] | None: ...
    def initiate_device_flow(self, *, scopes: list[str]) -> dict[str, object]: ...
    def acquire_token_by_device_flow(self, flow: dict[str, object]) -> dict[str, object]: ...


class ClientFactory(Protocol):
    def __call__(
        self, client_id: str, *, authority: str, token_cache: TokenCache, timeout: int
    ) -> MicrosoftClient: ...


class CacheFactory(Protocol):
    def __call__(self) -> TokenCache: ...


class TeamsAuthentication:
    def __init__(
        self,
        client_id: str,
        tenant: str,
        *,
        meeting_links: bool = False,
        store: CredentialStore | None = None,
    ) -> None:
        if (
            not client_id
            or len(client_id) > 256
            or not all(c.isalnum() or c == "-" for c in client_id)
        ):
            raise ProviderError("Enter the Entra public-client application ID")
        if not tenant or len(tenant) > 256 or not all(c.isalnum() or c in ".-" for c in tenant):
            raise ProviderError("Enter a valid tenant ID or domain")
        # MSAL's public classes are untyped. Isolate the SDK contract here rather
        # than propagating dynamic dictionaries and unknown methods into the UI.
        sdk = importlib.import_module("msal")
        cache_factory = cast(CacheFactory, sdk.SerializableTokenCache)
        client_factory = cast(ClientFactory, sdk.PublicClientApplication)
        self.store = store if store is not None else secret_service()
        self.key = f"teams:{tenant}:{client_id}"
        self.cache = cache_factory()
        saved = self.store.get_password("parakatt-integrations", self.key)
        if saved:
            self.cache.deserialize(saved)
        self.client = client_factory(
            client_id,
            authority=f"https://login.microsoftonline.com/{tenant}",
            token_cache=self.cache,
            timeout=20,
        )
        self.scopes = [TRANSCRIPT_SCOPE] + ([MEETING_SCOPE] if meeting_links else [])

    def accounts(self) -> list[Account]:
        accounts: list[Account] = []
        for item in self.client.get_accounts():
            ident, label = item.get("home_account_id"), item.get("username")
            if isinstance(ident, str) and ident:
                accounts.append(
                    Account(ident, label if isinstance(label, str) and label else "Work account")
                )
        return accounts

    def _save(self) -> None:
        if self.cache.has_state_changed:
            self.store.set_password("parakatt-integrations", self.key, self.cache.serialize())

    def token(
        self,
        account_id: str | None = None,
        *,
        announce: Callable[[DevicePrompt], None] | None = None,
        cancel: threading.Event | None = None,
        force_sign_in: bool = False,
        interactive: bool = True,
    ) -> str:
        if cancel is not None and cancel.is_set():
            raise ProviderError("Sign-in canceled")
        accounts = self.client.get_accounts()
        if account_id is not None:
            accounts = [item for item in accounts if item.get("home_account_id") == account_id]
            if len(accounts) != 1:
                raise ProviderError("Choose an available work account or sign in again")
        elif len(accounts) > 1 and not force_sign_in:
            raise ProviderError("More than one account is cached; choose a work account")
        result = None
        if accounts and not force_sign_in:
            result = self.client.acquire_token_silent(self.scopes, account=accounts[0])
        if not result or "access_token" not in result:
            if not interactive:
                raise ProviderError(
                    "This account needs sign-in or administrator consent; use Sign in"
                )
            flow = self.client.initiate_device_flow(scopes=self.scopes)
            code = flow.get("user_code")
            if not isinstance(code, str) or not code:
                raise ProviderError(
                    "Cannot start sign-in; check public-client device authorization in the app registration"
                )
            raw_url = flow.get("verification_uri", "https://microsoft.com/devicelogin")
            message = flow.get("message")
            if (
                not isinstance(raw_url, str)
                or urlsplit(raw_url).scheme != "https"
                or urlsplit(raw_url).netloc
                not in ("microsoft.com", "www.microsoft.com", "login.microsoftonline.com")
            ):
                raise ProviderError("Microsoft returned an unsupported sign-in URL")
            if announce:
                announce(
                    DevicePrompt(
                        code,
                        raw_url,
                        message
                        if isinstance(message, str) and message
                        else f"Open {raw_url} and enter {code} to sign in.",
                    )
                )
            finished = threading.Event()

            def cancel_polling() -> None:
                while not finished.wait(0.1):
                    if cancel is not None and cancel.is_set():
                        flow["expires_at"] = 0
                        return

            watcher = threading.Thread(target=cancel_polling, daemon=True)
            watcher.start()
            try:
                result = self.client.acquire_token_by_device_flow(flow)
            finally:
                finished.set()
                watcher.join(timeout=1)
            if cancel is not None and cancel.is_set():
                raise ProviderError("Sign-in canceled")
            if account_id is not None:
                claims = object_fields(result.get("id_token_claims", {}))
                local_id = accounts[0].get("local_account_id")
                realm = accounts[0].get("realm")
                if (
                    claims.get("oid") != local_id
                    or claims.get("tid") != realm
                    or not local_id
                    or not realm
                ):
                    self._save()
                    raise ProviderError(
                        "A different account signed in; choose that account before loading transcripts"
                    )
        token = result.get("access_token") if result else None
        if not isinstance(token, str) or not token:
            raise ProviderError("Sign-in was rejected, canceled, or requires administrator consent")
        self._save()
        return token

    def sign_out(self, account_id: str) -> None:
        for account in self.client.get_accounts():
            if account.get("home_account_id") == account_id:
                self.client.remove_account(account)
                self._save()
                return
        raise ProviderError("This work account is no longer cached")
