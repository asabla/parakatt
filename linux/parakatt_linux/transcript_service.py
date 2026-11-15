"""Read, preview and commit meeting transcripts through the shared Rust parser."""

from __future__ import annotations

import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

from .authentication import Account, DevicePrompt, TeamsAuthentication
from .backend import Backend
from .connections import Connection
from .credentials import CredentialStore, secret_service
from .providers import (
    MAX_BYTES,
    MeetingSource,
    ProviderError,
    SlackIdentity,
    TranscriptSource,
    slack_identity,
    slack_sources,
    slack_speaker_names,
    slack_transcript,
    teams_meeting,
    teams_transcript,
    teams_transcripts,
)

if TYPE_CHECKING:
    from collections.abc import Callable

    from ._native.parakatt_core import TranscriptImportResult


@dataclass(frozen=True)
class PreviewUtterance:
    text: str
    speaker: str | None
    start_secs: float | None
    end_secs: float | None


@dataclass(frozen=True)
class PreparedTranscript:
    provider: str
    title: str
    source_id: str | None
    content: str = field(repr=False)
    utterances: tuple[PreviewUtterance, ...]
    speaker_names: dict[str, str] = field(default_factory=dict[str, str])

    @property
    def speakers(self) -> tuple[str, ...]:
        return tuple(dict.fromkeys(cue.speaker for cue in self.utterances if cue.speaker))


@dataclass(frozen=True)
class CommittedTranscript:
    result: TranscriptImportResult
    warnings: tuple[str, ...] = ()


def read_transcript(path: Path) -> str:
    with path.open("rb") as source:
        raw = source.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("Transcript exceeds 8 MiB")
    try:
        return raw.decode("utf-8-sig")
    except UnicodeError as error:
        raise ValueError("Choose a UTF-8 transcript export") from error


class TranscriptService:
    def __init__(self, backend: Backend, store: CredentialStore | None = None) -> None:
        self.backend = backend
        self._store = store

    @property
    def store(self) -> CredentialStore:
        if self._store is None:
            self._store = secret_service()
        return self._store

    def teams_auth(self, connection: Connection) -> TeamsAuthentication:
        if connection.provider != "teams":
            raise ValueError("Choose a Teams connection")
        return TeamsAuthentication(
            connection.client_id,
            connection.tenant,
            meeting_links=connection.meeting_links,
            store=self.store,
        )

    def accounts(self, connection: Connection) -> list[Account]:
        return self.teams_auth(connection).accounts()

    def sign_in(
        self,
        connection: Connection,
        announce: Callable[[DevicePrompt], None],
        cancel: threading.Event,
    ) -> list[Account]:
        auth = self.teams_auth(connection)
        auth.token(announce=announce, cancel=cancel, force_sign_in=True)
        return auth.accounts()

    def sign_out(self, connection: Connection, account_id: str) -> list[Account]:
        auth = self.teams_auth(connection)
        auth.sign_out(account_id)
        return auth.accounts()

    def connect_slack(self, token: str) -> SlackIdentity:
        if not token or any(char.isspace() for char in token):
            raise ProviderError("Enter the Slack app token")
        identity = slack_identity(token)
        if not identity.workspace_id:
            raise ProviderError("Slack did not identify the workspace")
        self.store.set_password("parakatt-integrations", f"slack:{identity.workspace_id}", token)
        return identity

    def disconnect(self, connection: Connection) -> None:
        key = (
            f"teams:{connection.tenant}:{connection.client_id}"
            if connection.provider == "teams"
            else f"slack:{connection.workspace_id}"
        )
        if self.store.get_password("parakatt-integrations", key) is not None:
            self.store.delete_password("parakatt-integrations", key)

    def _teams_token(self, connection: Connection, account_id: str, cancel: threading.Event) -> str:
        if not account_id:
            raise ProviderError("Choose a signed-in work account")
        return self.teams_auth(connection).token(account_id, cancel=cancel, interactive=False)

    def _slack_token(self, connection: Connection) -> str:
        if connection.provider != "slack":
            raise ValueError("Choose a Slack connection")
        token = self.store.get_password("parakatt-integrations", f"slack:{connection.workspace_id}")
        if not token:
            raise ProviderError("Reconnect this Slack workspace; no token is stored")
        return token

    def teams_sources(
        self,
        connection: Connection,
        account_id: str,
        reference: str,
        owner: str,
        cancel: threading.Event,
    ) -> tuple[MeetingSource, list[TranscriptSource]]:
        token = self._teams_token(connection, account_id, cancel)
        meeting = teams_meeting(token, reference, owner, connection.meeting_links, cancel=cancel)
        return meeting, teams_transcripts(token, meeting.id, owner, cancel=cancel)

    def slack_sources(
        self, connection: Connection, channel: str, cancel: threading.Event
    ) -> list[TranscriptSource]:
        return slack_sources(self._slack_token(connection), channel, cancel=cancel)

    def prepare(
        self,
        provider: str,
        title: str,
        content: str,
        source_id: str | None = None,
        speaker_names: dict[str, str] | None = None,
    ) -> PreparedTranscript:
        request = self.backend.api.request(provider, title, content, source_id)
        cues = self.backend.engine.preview_transcript(request)
        return PreparedTranscript(
            provider,
            title,
            source_id,
            content,
            tuple(
                PreviewUtterance(cue.text, cue.speaker, cue.start_secs, cue.end_secs)
                for cue in cues
            ),
            dict(speaker_names or {}),
        )

    def from_file(self, path: Path, provider: str, title: str) -> PreparedTranscript:
        return self.prepare(provider, title, read_transcript(path))

    def from_teams(
        self,
        connection: Connection,
        account_id: str,
        meeting: MeetingSource,
        source: TranscriptSource,
        owner: str,
        title: str,
        cancel: threading.Event,
    ) -> PreparedTranscript:
        token = self._teams_token(connection, account_id, cancel)
        content = teams_transcript(token, meeting.id, source.id, owner, cancel=cancel)
        if cancel.is_set():
            raise ProviderError("Request canceled")
        return self.prepare("teams", title, content, f"{owner}/{meeting.id}/{source.id}")

    def from_slack(
        self, connection: Connection, file_id: str, title: str, cancel: threading.Event
    ) -> PreparedTranscript:
        token = self._slack_token(connection)
        content = slack_transcript(token, file_id, cancel=cancel)
        if cancel.is_set():
            raise ProviderError("Request canceled")
        names = (
            slack_speaker_names(token, content, cancel=cancel) if connection.resolve_names else {}
        )
        if cancel.is_set():
            raise ProviderError("Request canceled")
        return self.prepare("slack", title, content, f"{connection.workspace_id}/{file_id}", names)

    def commit(self, preview: PreparedTranscript, title: str) -> CommittedTranscript:
        # Revalidate the exact snapshot shown in preview, never refetch a source
        # between confirmation and commit. Duplicate records keep user edits.
        request = self.backend.api.request(
            preview.provider, title, preview.content, preview.source_id
        )
        result = self.backend.engine.import_transcript(request)
        warnings: list[str] = []
        if result.created:
            for original, display in preview.speaker_names.items():
                if original not in preview.speakers:
                    continue
                try:
                    self.backend.engine.set_transcript_speaker_alias(result.id, original, display)
                except Exception:
                    warnings.append(
                        f"Could not apply the display name for {original}; its source ID is retained"
                    )
        return CommittedTranscript(result, tuple(warnings))
