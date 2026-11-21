"""Exercise shortcut forwarding across processes during desktop startup."""

import os
import select
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(os.environ.get("PARAKATT_TEST_QT"), "Set PARAKATT_TEST_QT=1")
class DesktopInstanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from PySide6.QtWidgets import QApplication

        cls.app = QApplication.instance() or QApplication([])

    def test_shortcut_waits_for_the_instance_that_is_still_starting(self):
        from PySide6.QtCore import QLockFile
        from PySide6.QtNetwork import QLocalServer

        from parakatt_linux.desktop_instance import receive_commands, socket_name

        with tempfile.TemporaryDirectory() as directory:
            lock = QLockFile(str(Path(directory) / "desktop.lock"))
            self.assertTrue(lock.tryLock(0))
            server = QLocalServer()
            commands = []
            client_code = """
import sys
from pathlib import Path
from PySide6.QtCore import QCoreApplication
from parakatt_linux import desktop_instance

app = QCoreApplication([])
forward = desktop_instance.forward_command

def report_attempt(*args):
    result = forward(*args)
    desktop_instance.forward_command = forward
    print('attempted', flush=True)
    return result

desktop_instance.forward_command = report_attempt
result = desktop_instance.claim_instance(Path(sys.argv[1]), 'meeting')
raise SystemExit(0 if result is None else 1)
"""
            process = subprocess.Popen(
                [sys.executable, "-c", client_code, directory],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                self.assertIsNotNone(process.stdout)
                ready, _, _ = select.select([process.stdout], [], [], 5)
                self.assertTrue(ready, "Shortcut client did not try to connect")
                self.assertEqual(process.stdout.readline().strip(), "attempted")
                self.assertTrue(server.listen(socket_name(Path(directory))))
                receive_commands(server, commands.append)
                _, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, stderr)
                for _ in range(3):
                    self.app.processEvents()
                self.assertEqual(commands, ["meeting"])
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate()
                server.close()
                lock.unlock()
