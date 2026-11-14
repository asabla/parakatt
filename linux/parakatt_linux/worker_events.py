"""Checked worker messages and lifecycle states at the GUI boundary."""

from __future__ import annotations

from enum import StrEnum
from typing import TYPE_CHECKING, Literal, Protocol, overload

if TYPE_CHECKING:
    from ._native.parakatt_core import ChunkResult, ImportJob, TranscriptionResult


class RecordingState(StrEnum):
    NEW = "new"
    PREPARING = "preparing"
    RECORDING = "recording"
    PAUSED = "paused"
    FINISHING = "finishing"
    COMPLETED = "completed"
    DISCARDED = "discarded"
    FAILED = "failed"


class ImportState(StrEnum):
    QUEUED = "queued"
    DOWNLOADING = "downloading"
    TRANSCRIBING = "transcribing"
    PAUSING = "pausing"
    PAUSED = "paused"
    COMPLETED = "completed"
    FAILED = "failed"


class Notify(Protocol):
    @overload
    def __call__(
        self, kind: Literal["error", "status", "live", "preview"], value: str, /
    ) -> None: ...
    @overload
    def __call__(self, kind: Literal["audio_level"], value: float, /) -> None: ...
    @overload
    def __call__(self, kind: Literal["live_segments"], value: ChunkResult, /) -> None: ...
    @overload
    def __call__(self, kind: Literal["recorded"], value: TranscriptionResult, /) -> None: ...
    @overload
    def __call__(self, kind: Literal["import_progress"], value: ImportJob, /) -> None: ...
    @overload
    def __call__(self, kind: Literal["recording_done", "import_done"], value: None, /) -> None: ...
    @overload
    def __call__(self, kind: Literal["recording_state"], value: RecordingState, /) -> None: ...
    @overload
    def __call__(self, kind: Literal["import_state"], value: ImportState, /) -> None: ...
