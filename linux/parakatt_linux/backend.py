"""Platform services; the shared Rust engine remains the source of truth."""

import ctypes
import hashlib
import json
import math
import os
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from array import array
from dataclasses import dataclass
from pathlib import Path

from .preferences import load_preferences, save_preferences

MODEL = "parakeet-tdt-0.6b-v3"
RATE = 16000


@dataclass
class Paths:
    data: Path
    config: Path
    models: Path

    @classmethod
    def discover(cls, models: Path | str | None = None, data: Path | str | None = None) -> "Paths":
        home = Path.home()
        root = (
            Path(data)
            if data
            else Path(os.environ.get("XDG_DATA_HOME", home / ".local/share")) / "parakatt"
        )
        config = (
            root / "config"
            if data
            else Path(os.environ.get("XDG_CONFIG_HOME", home / ".config")) / "parakatt"
        )
        return cls(root, config, Path(models) if models else root / "models")


def native_module():
    directory = Path(__file__).parent / "_native"
    # Resolve bundled ONNX before loading the UniFFI library, without changing
    # the user's dynamic-loader settings or disabling library verification.
    runtime = directory / "libonnxruntime.so.1"
    if runtime.exists():
        ctypes.CDLL(str(runtime), mode=ctypes.RTLD_GLOBAL)
    try:
        from ._native import parakatt_core

        return parakatt_core
    except ImportError as error:
        raise RuntimeError("Build native bindings first: make linux-native") from error


def run_tool(arguments: list[str]) -> bytes:
    arguments = [tool_path(arguments[0]), *arguments[1:]]
    try:
        result = subprocess.run(arguments, capture_output=True, timeout=30)
    except FileNotFoundError as error:
        raise RuntimeError(f"Install the required program: {arguments[0]}") from error
    if result.returncode:
        message = result.stderr.decode(errors="replace")[-2000:]
        raise RuntimeError(f"{arguments[0]} failed: {message}")
    return result.stdout


def tool_path(name: str) -> str:
    # Launching an absolute venv entry point does not add its bin directory to
    # PATH. Prefer companion tools installed with the desktop package.
    companion = Path(sys.executable).parent / name
    return str(companion) if companion.is_file() else shutil.which(name) or name


def decode_samples(data: bytes) -> list[float]:
    if len(data) % 4:
        raise RuntimeError("Audio capture returned a partial float sample")
    samples = array("f")
    samples.frombytes(data)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples.tolist()


def audio_sources():
    """Use PulseAudio's compatibility API on both PipeWire and PulseAudio."""
    output = run_tool(["pactl", "--format=json", "list", "sources"])
    return [(s["name"], s.get("description", s["name"])) for s in json.loads(output)]


def default_monitor() -> str:
    sink = run_tool(["pactl", "get-default-sink"]).decode().strip()
    sources = {name for name, _ in audio_sources()}
    monitor = f"{sink}.monitor"
    if monitor not in sources:
        raise RuntimeError(
            "No monitor for the default output. Select a system-audio source in Settings."
        )
    return monitor


def fingerprint(path: Path | str) -> str:
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def probe(path):
    info = json.loads(
        run_tool(
            ["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)]
        )
    )
    tracks = [s for s in info["streams"] if s.get("codec_type") == "audio"]
    if not tracks:
        raise RuntimeError("The source has no audio track")
    duration = float(info["format"].get("duration", 0))
    if not 0 < duration < 60 * 60 * 24 * 7:
        raise RuntimeError("The source must have a finite duration of less than seven days")
    return duration, tracks


class Backend:
    def __init__(self, paths: Paths) -> None:
        self.paths = paths
        self.api = native_module()
        paths.data.mkdir(parents=True, exist_ok=True)
        paths.config.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.api.init_logging("warn")
        self.engine = self.api.Engine(
            self.api.EngineConfig(
                models_dir=str(paths.models),
                config_dir=str(paths.config),
                active_stt_model=None,
                active_llm_provider=None,
                active_mode="",
            )
        )
        self.capture_active = threading.Event()
        self.inference = threading.RLock()
        self.preferences_file = paths.config / "linux.json"
        self.preferences, self.startup_warnings = load_preferences(self.preferences_file)
        try:
            self.restore_credentials()
        except Exception as error:
            self.startup_warnings.append(
                f"LLM disabled until the desktop keyring is available: {error}"
            )

    def save_preferences(self, preferences: object) -> None:
        self.preferences = save_preferences(self.preferences_file, preferences)

    def restore_credentials(self) -> None:
        from keyring.backends.SecretService import Keyring

        store = Keyring()
        for credential in self.engine.legacy_credentials():
            store.set_password("parakatt", credential.account, credential.api_key)
            if store.get_password("parakatt", credential.account) != credential.api_key:
                raise RuntimeError("Cannot verify migrated credential in Secret Service")
            self.engine.acknowledge_credential_migration(credential)
        settings = self.engine.get_llm_settings()
        if settings.provider in ("openai", "anthropic"):
            key = store.get_password("parakatt", self.engine.credential_account(settings.provider))
            self.engine.configure_llm(settings.provider, settings.base_url, settings.model, key)

    def configure_llm(self, provider: str, url: str, model: str, key: str | None) -> None:
        if provider in ("openai", "anthropic"):
            from keyring.backends.SecretService import Keyring

            store = Keyring()
            # Require a functional desktop keyring rather than falling back to a file.
            account = self.engine.credential_account(provider)
            if key:
                store.set_password("parakatt", account, key)
            key = store.get_password("parakatt", account)
        self.engine.configure_llm(provider, url, model, key or None)

    def load_model(self) -> None:
        with self.inference:
            if not self.engine.is_model_loaded():
                self.engine.load_model(MODEL)

    def history(self, search: str = "", offset: int = 0, category: str | None = None):
        def page(start):
            return self.engine.list_transcriptions(
                self.api.TranscriptionQuery(
                    search_text=search or None, source_filter=None, limit=100, offset=start
                )
            )

        if not category or category == "All":
            return page(offset)
        # Imported Teams/Slack transcripts belong to Meetings. Scan stored pages
        # before slicing so filtered pagination cannot skip matching records.
        matches, start = [], 0
        while len(matches) < offset + 100:
            rows = page(start)
            for row in rows:
                kind = (
                    "Meetings"
                    if row.source == "meeting" or row.audio_source in ("teams", "slack")
                    else "Videos"
                    if row.source == "import"
                    else "Notes"
                )
                if kind == category:
                    matches.append(row)
            if len(rows) < 100:
                break
            start += 100
        return matches[offset : offset + 100]


class Recording:
    """Bounded capture queue and one inference worker, with explicit gap reporting."""

    def __init__(self, backend, meeting, mode, notify):
        self.backend, self.meeting, self.mode, self.notify = backend, meeting, mode, notify
        self.id = str(uuid.uuid4())
        self.stop_event = threading.Event()
        self.pause_event = threading.Event()
        self.discard_event = threading.Event()
        self.ready = threading.Event()
        self.clock_lock = threading.Lock()
        self.started_at = None
        self.stopped_at = None
        self.paused_at = None
        self.paused_seconds = 0.0
        self.chunks = queue.Queue(maxsize=8)
        self.processes = []
        self.readers = []
        self.error = None
        self.preview = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.backend.capture_active.set()
        self.thread.start()

    def set_paused(self, paused):
        with self.clock_lock:
            if not self.ready.is_set() or self.stop_event.is_set():
                return
            now = time.monotonic()
            if paused and not self.pause_event.is_set():
                self.paused_at = now
                self.pause_event.set()
            elif not paused and self.pause_event.is_set():
                self.paused_seconds += now - self.paused_at
                self.paused_at = None
                self.pause_event.clear()

    def elapsed_seconds(self):
        with self.clock_lock:
            if self.started_at is None:
                return 0.0
            end = self.stopped_at or time.monotonic()
            paused = (end - self.paused_at) if self.paused_at is not None else 0.0
            return max(0, end - self.started_at - self.paused_seconds - paused)

    def discard(self):
        self.discard_event.set()
        self.stop()

    def stop(self):
        with self.clock_lock:
            if self.stopped_at is None:
                self.stopped_at = time.monotonic()
            self.stop_event.set()
        for process in list(self.processes):
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                timer = threading.Timer(3, lambda p=process: p.kill() if p.poll() is None else None)
                timer.daemon = True
                timer.start()

    def _capture(self, source, kind):
        process = None
        try:
            with tempfile.TemporaryFile() as errors:
                process = subprocess.Popen(
                    [
                        tool_path("ffmpeg"),
                        "-nostdin",
                        "-hide_banner",
                        "-loglevel",
                        "error",
                        "-f",
                        "pulse",
                        "-i",
                        source,
                        "-ac",
                        "1",
                        "-ar",
                        str(RATE),
                        "-f",
                        "f32le",
                        "pipe:1",
                    ],
                    stdout=subprocess.PIPE,
                    stderr=errors,
                )
                self.processes.append(process)
                # Stop may arrive while Popen is starting, before the process
                # is visible to stop(). Recheck before draining its pipe.
                if self.stop_event.is_set():
                    self.stop()
                duration = min(30, max(5, self.backend.engine.get_chunk_duration()))
                buffer = bytearray()
                checkpoint = bytearray()
                chunk_index = 0
                while not self.stop_event.is_set():
                    data = process.stdout.read(4096)
                    if not data:
                        break
                    if self.pause_event.is_set() or self.discard_event.is_set():
                        continue  # Drain the audio service without retaining paused audio.
                    if kind == self.backend.api.ChunkSource.MIC:
                        samples = decode_samples(data)
                        rms = math.sqrt(
                            sum(sample * sample for sample in samples) / max(1, len(samples))
                        )
                        self.notify("audio_level", min(1.0, rms * 5) if math.isfinite(rms) else 0.0)
                    buffer.extend(data)
                    if self.preview and kind == self.backend.api.ChunkSource.MIC:
                        self.preview.feed(data, chunk_index, bytes(buffer))
                    checkpoint.extend(data)
                    while len(checkpoint) >= RATE * 4:
                        self.backend.engine.append_capture_audio(
                            self.id, kind, decode_samples(bytes(checkpoint[: RATE * 4]))
                        )
                        del checkpoint[: RATE * 4]
                    size = duration * RATE * 4
                    if len(buffer) >= size:
                        self._enqueue(kind, chunk_index, bytes(buffer[:size]))
                        del buffer[:size]
                        chunk_index += 1
                remainder = process.stdout.read()
                if self.pause_event.is_set() or self.discard_event.is_set():
                    remainder = b""
                buffer.extend(remainder)
                checkpoint.extend(remainder)
                for offset in range(0, len(checkpoint), RATE * 4):
                    self.backend.engine.append_capture_audio(
                        self.id, kind, decode_samples(bytes(checkpoint[offset : offset + RATE * 4]))
                    )
                if buffer:
                    self._enqueue(kind, chunk_index, bytes(buffer))
                process.wait(timeout=5)
                if not self.stop_event.is_set():
                    errors.seek(0)
                    raise RuntimeError(
                        "Audio capture stopped: " + errors.read().decode(errors="replace")[-1500:]
                    )
        except Exception as error:
            self.error = str(error)
            try:
                self.backend.engine.mark_capture_gap(self.id, True)
            finally:
                self.stop()
        finally:
            if process:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdout.close()

    def _enqueue(self, kind, index, data):
        try:
            self.chunks.put_nowait((kind, index, decode_samples(data)))
        except queue.Full:
            self.backend.engine.mark_capture_gap(self.id, True)
            raise RuntimeError(
                "Recognition cannot keep up; recording stopped. Committed text is retained in recovery."
            ) from None

    def _run(self):
        core = self.backend.engine
        started = False
        try:
            self.backend.load_model()
            if self.stop_event.is_set():
                return
            source = "meeting" if self.meeting else "push_to_talk"
            core.start_recording(self.id, source, self.mode)
            started = True
            core.begin_capture(self.id, source, self.mode)
            if core.get_streaming_preview_enabled():
                self.preview = Preview(self.backend, self.id, self.notify)
                self.preview.start()
            streams = [
                (
                    self.backend.preferences.get("microphone") or "default",
                    self.backend.api.ChunkSource.MIC,
                )
            ]
            if self.meeting:
                streams.append(
                    (
                        self.backend.preferences.get("system_audio") or default_monitor(),
                        self.backend.api.ChunkSource.SYSTEM,
                    )
                )
            with self.clock_lock:
                self.started_at = time.monotonic()
            self.ready.set()
            for device, kind in streams:
                thread = threading.Thread(target=self._capture, args=(device, kind), daemon=True)
                self.readers.append(thread)
                thread.start()
            self.notify(
                "status",
                "Recording microphone + system audio" if self.meeting else "Recording microphone",
            )
            while any(t.is_alive() for t in self.readers) or not self.chunks.empty():
                try:
                    kind, index, samples = self.chunks.get(timeout=0.1)
                except queue.Empty:
                    continue
                if self.discard_event.is_set():
                    continue
                with self.backend.inference:
                    result = core.process_source_chunk(
                        self.id, kind, index, samples, RATE, 0.0, self.mode, None
                    )
                self.notify("live", core.get_session_text(self.id))
                self.notify("live_segments", result)
            if self.discard_event.is_set():
                self.notify("status", "Recording discarded")
                return
            if self.error:
                raise RuntimeError(self.error)
            core.end_capture(self.id)
            result = core.finish_session(self.id, self.mode, None, source)
            self.notify("recorded", result)
        except Exception as error:
            self.notify("error", str(error))
        finally:
            failures = []
            actions = [self.stop]
            if self.preview:
                actions.append(self.preview.stop)
            actions.extend(lambda reader=reader: reader.join(timeout=6) for reader in self.readers)
            if started:
                actions.extend(
                    [lambda: core.end_capture(self.id), lambda: core.cancel_session(self.id)]
                )
            if started and self.discard_event.is_set():
                actions.append(lambda: core.discard_recording_draft(self.id))
            try:
                for action in actions:
                    try:
                        action()
                    except Exception as error:
                        failures.append(str(error))
            finally:
                self.backend.capture_active.clear()
                self.notify("recording_done", None)
            for failure in failures:
                self.notify("error", f"Recording cleanup: {failure}")


class Preview:
    """Best-effort previews never commit history or block the capture queue."""

    def __init__(self, backend, session, notify):
        self.backend, self.session, self.notify = backend, session, notify
        self.id = session + "-preview"
        self.pending = queue.Queue(maxsize=8)
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.streaming = False
        self.buffer = bytearray()
        self.last_buffer_size = 0
        self.index = -1

    def start(self):
        core = self.backend.engine
        selected = core.get_speech_settings().preview_model
        if selected:
            try:
                core.load_model(selected)
                self.streaming = core.should_use_streaming_preview()
            except Exception as error:
                self.notify(
                    "status", f"Streaming preview unavailable; using buffered preview: {error}"
                )
        if self.streaming:
            core.start_streaming_session(self.id)
        else:
            core.buffered_preview_start(self.id)
        self.thread.start()

    def feed(self, data, index, snapshot):
        if self.streaming:
            self.buffer.extend(data)
            size = self.backend.engine.streaming_native_chunk_samples() * 4
            if not size:
                return
            while len(self.buffer) >= size:
                self._put((index, bytes(self.buffer[:size])))
                del self.buffer[:size]
        else:
            if index != self.index:
                self.index, self.last_buffer_size = index, 0
            if len(snapshot) - self.last_buffer_size >= RATE * 4 * 3:
                self.last_buffer_size = len(snapshot)
                self._put((index, snapshot))

    def _put(self, item):
        try:
            self.pending.put_nowait(item)
        except queue.Full:
            # Preview loss is separate from durable capture; reset agreement so
            # the next result cannot imply continuity across skipped audio.
            while not self.pending.empty():
                try:
                    self.pending.get_nowait()
                except queue.Empty:
                    break
            self.pending.put_nowait((None, b""))

    def _run(self):
        core, previous = self.backend.engine, -1
        try:
            while not self.stopped.is_set():
                try:
                    index, data = self.pending.get(timeout=0.1)
                except queue.Empty:
                    continue
                if index is None:
                    if self.streaming:
                        core.reset_streaming_session(self.id)
                    else:
                        core.buffered_preview_reset(self.id)
                    continue
                if not self.streaming and index != previous:
                    core.buffered_preview_reset(self.id)
                previous = index
                with self.backend.inference:
                    if self.stopped.is_set():
                        break
                    result = (
                        core.feed_streaming_chunk(self.id, decode_samples(data))
                        if self.streaming
                        else core.buffered_preview_update(self.id, decode_samples(data), RATE)
                    )
                self.notify("preview", result.committed_text + " " + result.tentative_text)
        except Exception as error:
            if not self.stopped.is_set():
                self.notify("status", f"Preview stopped; final transcription continues: {error}")

    def stop(self):
        self.stopped.set()
        core = self.backend.engine
        if self.streaming:
            core.cancel_streaming_session(self.id)
        else:
            core.buffered_preview_cancel(self.id)
        self.thread.join(timeout=10)


class Importer:
    def __init__(self, backend, job, notify, browser=None):
        self.backend, self.job, self.notify = backend, job, notify
        self.pause_event = threading.Event()
        self.finished = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.process = None
        self.browser = browser

    def start(self):
        self.thread.start()

    def pause(self):
        if self.finished.is_set():
            return
        self.pause_event.set()
        try:
            self.backend.engine.set_import_state(
                self.job.id, "paused", "Pausing; committed text retained"
            )
        finally:
            if self.process and self.process.poll() is None:
                self.process.terminate()

    def _download(self):
        directory = self.backend.paths.data / "media" / self.job.id
        directory.mkdir(parents=True, exist_ok=True)
        # yt-dlp also handles direct media URLs; no shell or user yt-dlp config.
        arguments = [
            tool_path("yt-dlp"),
            "--ignore-config",
            "--no-playlist",
            "--no-progress",
            "--match-filter",
            "!is_live",
            "--max-filesize",
            "20G",
            "--merge-output-format",
            "mkv",
            "--print",
            "after_move:filepath",
            "-o",
            str(directory / "source.%(ext)s"),
        ]
        if self.browser:
            arguments.extend(["--cookies-from-browser", self.browser])
        arguments.extend(["--", self.job.input])
        self.process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        output, errors = self.process.communicate()
        if self.process.returncode:
            raise RuntimeError(errors.decode(errors="replace")[-1500:])
        path = Path(output.decode().strip().splitlines()[-1]).resolve()
        if not path.is_relative_to(directory.resolve()) or not path.is_file():
            raise RuntimeError("Downloader did not produce a local media file")
        return path

    def _run(self):
        core = self.backend.engine
        try:
            self.backend.load_model()
            path = Path(self.job.attachment.path or self.job.input)
            if not self.job.attachment.path and self.job.kind != "file":
                core.set_import_state(self.job.id, "downloading", "Downloading media")
                path = self._download()
            if self.pause_event.is_set():
                return
            duration, tracks = probe(path)
            track = self.job.attachment.audio_track
            if track >= len(tracks):
                raise RuntimeError("Selected audio track no longer exists")
            digest = fingerprint(path)
            attachment = self.backend.api.MediaAttachment(
                path=str(path.resolve()),
                bookmark=b"",
                fingerprint=digest,
                review_path="",
                audio_track=track,
                duration_secs=duration,
            )
            self.job = core.attach_import_media(self.job.id, attachment)
            self.job = core.set_import_state(self.job.id, "transcribing", "")
            while self.job.processed_until + 0.001 < duration:
                if self.pause_event.is_set():
                    return
                if self.backend.capture_active.is_set():
                    self.pause_event.wait(0.2)
                    continue
                offset = max(0.0, self.job.processed_until - 2) if self.job.next_chunk else 0.0
                length = min(30.0, duration - offset)
                data = run_tool(
                    [
                        "ffmpeg",
                        "-nostdin",
                        "-v",
                        "error",
                        "-ss",
                        str(offset),
                        "-i",
                        str(path),
                        "-t",
                        str(length),
                        "-map",
                        f"0:a:{track}",
                        "-ac",
                        "1",
                        "-ar",
                        str(RATE),
                        "-f",
                        "f32le",
                        "pipe:1",
                    ]
                )
                samples = decode_samples(data)
                # Audio tracks can end before the video, and codecs may decode
                # padded frames beyond its duration. Match the requested media
                # interval so durable offsets stay on the 16 kHz timebase.
                expected = round(length * RATE)
                samples = samples[:expected]
                samples.extend([0.0] * (expected - len(samples)))
                if self.pause_event.is_set():
                    return
                with self.backend.inference:
                    self.job = core.process_import_chunk(self.job.id, samples, offset)
                core.process_import_text(self.job.id)
                self.notify("import_progress", self.job)
            if fingerprint(path) != digest:
                core.invalidate_import_source(self.job.id)
                raise RuntimeError("The source changed during transcription")
            core.set_import_state(self.job.id, "completed", "")
            self.notify("status", "Import completed")
        except Exception as error:
            if not self.pause_event.is_set():
                try:
                    core.set_import_state(self.job.id, "failed", str(error))
                except Exception as persistence_error:
                    self.notify("error", f"Cannot save import failure: {persistence_error}")
                self.notify("error", str(error))
        finally:
            try:
                if self.pause_event.is_set():
                    core.set_import_state(self.job.id, "paused", "Paused; committed text retained")
            except Exception as error:
                self.notify("error", f"Cannot save paused import: {error}")
            finally:
                self.finished.set()
                self.notify("import_done", None)


def subtitle_text(segments, webvtt=False):
    def stamp(seconds):
        milliseconds = max(0, round(seconds * 1000))
        hours, milliseconds = divmod(milliseconds, 3600000)
        minutes, milliseconds = divmod(milliseconds, 60000)
        seconds, milliseconds = divmod(milliseconds, 1000)
        separator = "." if webvtt else ","
        return f"{hours:02}:{minutes:02}:{seconds:02}{separator}{milliseconds:03}"

    blocks = ["WEBVTT\n"] if webvtt else []
    for index, segment in enumerate(segments, 1):
        text = f"{segment.speaker}: {segment.text}" if segment.speaker else segment.text
        blocks.append(
            f"{index}\n{stamp(segment.start_secs)} --> {stamp(segment.end_secs)}\n{text}\n"
        )
    return "\n".join(blocks)


def diagnostics():
    return {
        "session": os.environ.get("XDG_SESSION_TYPE", "unknown"),
        "desktop": os.environ.get("XDG_CURRENT_DESKTOP", "unknown"),
        "tools": {
            name: bool(shutil.which(tool_path(name)))
            for name in ("ffmpeg", "ffprobe", "pactl", "yt-dlp", "xdotool")
        },
        "global_shortcut": "Bind parakatt-desktop --toggle in GNOME Settings > Keyboard > Custom Shortcuts",
        "wayland_paste": "Transcript is copied to the clipboard; paste with Ctrl+V",
    }
