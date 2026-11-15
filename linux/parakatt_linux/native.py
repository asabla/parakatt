"""Lazy, typed entry point for the generated UniFFI API and bundled runtime."""

from __future__ import annotations

import ctypes
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ._native import parakatt_core as ffi


class NativeAPI:
    """Expose generated constructors with their types, without importing models at startup."""

    def __init__(self) -> None:
        directory = Path(__file__).parent / "_native"
        runtime = directory / "libonnxruntime.so.1"
        if runtime.exists():
            ctypes.CDLL(str(runtime), mode=ctypes.RTLD_GLOBAL)
        try:
            from ._native import parakatt_core
        except ImportError as error:
            raise RuntimeError("Build native bindings first: make linux-native") from error
        self.CoreError = parakatt_core.CoreError
        self.Engine = parakatt_core.Engine
        self.EngineConfig = parakatt_core.EngineConfig
        self.TranscriptionQuery = parakatt_core.TranscriptionQuery
        self.StoredTranscription = parakatt_core.StoredTranscription
        self.ChunkSource = parakatt_core.ChunkSource
        self.MediaAttachment = parakatt_core.MediaAttachment
        self.ModeConfig = parakatt_core.ModeConfig
        self.ReplacementRule = parakatt_core.ReplacementRule
        self.SpeechBackend = parakatt_core.SpeechBackend
        self.SpeechLanguage = parakatt_core.SpeechLanguage
        self.TranscriptProvider = parakatt_core.TranscriptProvider
        self.TranscriptImportRequest = parakatt_core.TranscriptImportRequest
        self.init_logging = parakatt_core.init_logging

    def request(
        self, provider: str, title: str, content: str, source_id: str | None = None
    ) -> ffi.TranscriptImportRequest:
        if provider not in ("teams", "slack"):
            raise ValueError("Choose Teams meetings or Slack Huddles")
        return self.TranscriptImportRequest(
            provider=self.TranscriptProvider.TEAMS
            if provider == "teams"
            else self.TranscriptProvider.SLACK,
            source_id=source_id,
            title=title,
            content=content,
        )
