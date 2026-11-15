"""Validated connection metadata. Tokens and token caches live only in the keyring."""

import json
import os
import tempfile
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal, cast


@dataclass(frozen=True)
class Connection:
    id: str
    provider: Literal["teams", "slack"]
    label: str
    client_id: str = ""
    tenant: str = "organizations"
    workspace_id: str = ""
    meeting_links: bool = False
    resolve_names: bool = False


def connection(value: object) -> Connection:
    if not isinstance(value, dict):
        raise ValueError("Invalid connection")
    fields = cast(dict[object, object], value)
    provider = fields.get("provider")
    if provider not in ("teams", "slack"):
        raise ValueError("Unsupported connection provider")
    strings: dict[str, str] = {}
    for key, default in [
        ("id", ""),
        ("label", ""),
        ("client_id", ""),
        ("tenant", "organizations"),
        ("workspace_id", ""),
    ]:
        item = fields.get(key, default)
        if not isinstance(item, str) or len(item) > 256 or any(ord(char) < 32 for char in item):
            raise ValueError("Invalid connection metadata")
        strings[key] = item.strip()
    meeting_links, resolve_names = (
        fields.get("meeting_links", False),
        fields.get("resolve_names", False),
    )
    if not isinstance(meeting_links, bool) or not isinstance(resolve_names, bool):
        raise ValueError("Invalid connection options")
    if not strings["id"] or not strings["label"]:
        raise ValueError("Each connection needs an ID and a label")
    if provider == "teams" and (not strings["client_id"] or not strings["tenant"]):
        raise ValueError("Teams needs an application ID and tenant")
    if provider == "slack" and not strings["workspace_id"]:
        raise ValueError("Slack needs a workspace ID")
    return Connection(
        id=strings["id"],
        provider="teams" if provider == "teams" else "slack",
        label=strings["label"],
        client_id=strings["client_id"],
        tenant=strings["tenant"],
        workspace_id=strings["workspace_id"],
        meeting_links=meeting_links,
        resolve_names=resolve_names,
    )


def load_connections(path: Path) -> tuple[list[Connection], str | None]:
    if not path.exists():
        return [], None
    try:
        with path.open("rb") as stream:
            raw = stream.read(65537)
        if len(raw) > 65536:
            raise ValueError("Connection settings exceed 64 KiB")
        data: object = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError("Invalid connection settings")
        fields = cast(dict[object, object], data)
        items = fields.get("connections")
        if (
            fields.get("version") != 1
            or not isinstance(items, list)
            or len(cast(list[object], items)) > 32
        ):
            raise ValueError("Unsupported connection settings")
        result = [connection(item) for item in cast(list[object], items)]
        if len({item.id for item in result}) != len(result):
            raise ValueError("Duplicate connection IDs")
        if len({connection_key(item) for item in result}) != len(result):
            raise ValueError("Duplicate app/tenant or workspace connections")
        return result, None
    except (ValueError, UnicodeError) as error:
        backup = path.with_name(f"{path.stem}.invalid-{uuid.uuid4().hex}.json")
        path.replace(backup)
        return [], f"Connection settings were invalid and preserved in {backup.name}: {error}"


def connection_key(value: Connection) -> tuple[str, str, str]:
    return (
        (value.provider, value.tenant.lower(), value.client_id.lower())
        if value.provider == "teams"
        else (value.provider, value.workspace_id, "")
    )


def save_connections(path: Path, values: list[Connection]) -> None:
    if len(values) > 32 or len({item.id for item in values}) != len(values):
        raise ValueError("Expected at most 32 unique connections")
    verified = [connection(asdict(item)) for item in values]
    if len({connection_key(item) for item in verified}) != len(verified):
        raise ValueError("This app/tenant or workspace already has a connection; edit it instead")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name, suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(
                {"version": 1, "connections": [asdict(item) for item in verified]}, output, indent=2
            )
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
