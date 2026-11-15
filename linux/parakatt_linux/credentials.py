"""Narrow interface to Secret Service; credentials never fall back to files."""

from typing import Protocol, cast


class CredentialStore(Protocol):
    def get_password(self, service: str, account: str) -> str | None: ...
    def set_password(self, service: str, account: str, password: str) -> None: ...
    def delete_password(self, service: str, account: str) -> None: ...


def secret_service() -> CredentialStore:
    from keyring.backends.SecretService import Keyring

    # Keyring's decorated methods lose their annotations. Keep that third-party
    # boundary here; callers use the documented get/set/delete contract.
    return cast(CredentialStore, Keyring())
