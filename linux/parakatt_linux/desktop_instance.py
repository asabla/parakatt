"""Single desktop instance and shortcut forwarding for each config directory."""

from __future__ import annotations

import hashlib
import os
import time
from collections.abc import Callable
from pathlib import Path
from typing import Literal

from PySide6.QtCore import QLockFile
from PySide6.QtNetwork import QLocalServer, QLocalSocket

type DesktopCommand = Literal["show", "toggle", "meeting"]
COMMANDS: dict[bytes, DesktopCommand] = {
    b"show": "show",
    b"toggle": "toggle",
    b"meeting": "meeting",
}


def socket_name(config: Path) -> str:
    identity = hashlib.sha256(os.fsencode(config.resolve())).hexdigest()[:16]
    return f"parakatt-{os.getuid()}-{identity}"


def forward_command(name: str, command: DesktopCommand) -> bool:
    client = QLocalSocket()
    client.connectToServer(name)
    if not client.waitForConnected(200):
        return False
    payload = command.encode("ascii")
    if client.write(payload) != len(payload) or (
        client.bytesToWrite() and not client.waitForBytesWritten(1000)
    ):
        raise RuntimeError("Could not send the command to the running Parakatt window.")
    client.disconnectFromServer()
    return True


def claim_instance(config: Path, command: DesktopCommand) -> tuple[QLockFile, QLocalServer] | None:
    name = socket_name(config)
    config.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = QLockFile(str(config.resolve() / "desktop.lock"))
    lock.setStaleLockTime(0)
    deadline = time.monotonic() + 3
    while True:
        if forward_command(name, command):
            return None
        if lock.tryLock(0):
            break
        if lock.error() != QLockFile.LockError.LockFailedError:
            raise RuntimeError("Could not lock the Parakatt configuration directory.")
        if time.monotonic() >= deadline:
            raise RuntimeError("Parakatt is running but its shortcut socket is unavailable.")
        time.sleep(0.05)

    try:
        # Only the lock owner may remove a stale socket. Check again for a
        # running instance from a version that predates the desktop lock.
        if forward_command(name, command):
            lock.unlock()
            return None
        QLocalServer.removeServer(name)
        server = QLocalServer()
        server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
        if not server.listen(name):
            raise RuntimeError(server.errorString())
        return lock, server
    except BaseException:
        lock.unlock()
        raise


def receive_commands(server: QLocalServer, dispatch: Callable[[DesktopCommand], None]) -> None:
    def accept(client: QLocalSocket) -> None:
        payload = bytearray()
        client.setReadBufferSize(8)

        def receive() -> None:
            payload.extend(client.readAll().data())
            command = COMMANDS.get(bytes(payload))
            if command is not None:
                client.disconnectFromServer()
                dispatch(command)
            elif not any(frame.startswith(payload) for frame in COMMANDS):
                client.disconnectFromServer()

        client.readyRead.connect(receive)
        client.disconnected.connect(client.deleteLater)
        if client.bytesAvailable():
            receive()

    def drain() -> None:
        while server.hasPendingConnections():
            accept(server.nextPendingConnection())

    server.newConnection.connect(drain)
    drain()
