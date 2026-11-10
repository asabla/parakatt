"""Validated, recoverable Linux preferences; contains no credentials."""

import json
import os
import tempfile
import uuid
from pathlib import Path
from typing import TypedDict, cast


class Preferences(TypedDict):
    microphone: str
    system_audio: str
    copy: bool


def validate_preferences(value: object) -> Preferences:
    if not isinstance(value, dict):
        raise ValueError("Settings must be a JSON object")
    fields = cast(dict[object, object], value)
    microphone = fields.get("microphone", "")
    system_audio = fields.get("system_audio", "")
    copy = fields.get("copy", True)
    if not isinstance(microphone, str) or not isinstance(system_audio, str):
        raise ValueError("Audio device names must be strings")
    if not isinstance(copy, bool):
        raise ValueError("Clipboard preference must be a boolean")
    if len(microphone) > 4096 or len(system_audio) > 4096:
        raise ValueError("Audio device name is too long")
    return {"microphone": microphone, "system_audio": system_audio, "copy": copy}


def load_preferences(path: Path) -> tuple[Preferences, list[str]]:
    if not path.exists():
        return validate_preferences({}), []
    try:
        with path.open("rb") as source:
            data = source.read(65537)
        if len(data) > 65536:
            raise ValueError("Settings exceed 64 KiB")
        return validate_preferences(json.loads(data)), []
    except (ValueError, UnicodeError) as error:
        backup = path.with_name(f"{path.stem}.invalid-{uuid.uuid4().hex}{path.suffix}")
        try:
            path.replace(backup)
        except OSError:
            return validate_preferences({}), [f"Cannot read settings; using defaults: {error}"]
        return validate_preferences({}), [
            f"Invalid settings preserved at {backup}; using defaults: {error}"
        ]
    except OSError as error:
        return validate_preferences({}), [f"Cannot read settings; using defaults: {error}"]


def save_preferences(path: Path, value: object) -> Preferences:
    preferences = validate_preferences(value)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name, suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(preferences, output, indent=2)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return preferences
