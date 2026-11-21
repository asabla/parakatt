"""Capture cleanup and signed-out ChatGPT settings without reading account storage."""

import argparse
import tempfile
from pathlib import Path

from PySide6.QtWidgets import QApplication

from .app import Window
from .backend import Backend, Paths
from .settings import Settings


class SignedOutPreview:
    def list(self):
        return []


def render(output):
    app = QApplication.instance() or QApplication([])
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="parakatt-cleanup-preview-") as directory:
        backend = Backend(Paths.discover(data=directory))
        window = Window(backend)
        settings = Settings(backend, window, SignedOutPreview())
        try:
            settings.resize(900, 1000)
            settings.show()
            settings.tabs.setCurrentIndex(1)
            settings.cleanup.setCurrentIndex(settings.cleanup.findData("punctuation"))
            app.processEvents()
            if not settings.grab().save(str(output / "cleanup.png")):
                raise OSError("Cannot save cleanup preview")
            settings.tabs.setCurrentIndex(3)
            settings.provider.setCurrentIndex(settings.provider.findData("chatgpt"))
            for _ in range(3):
                window.pool.waitForDone()
                app.processEvents()
            settings.chatgpt.message.setText(
                "Signed-out layout preview. No account storage or network access."
            )
            app.processEvents()
            if not settings.grab().save(str(output / "chatgpt.png")):
                raise OSError("Cannot save ChatGPT preview")
        finally:
            settings.reject()
            window.pool.waitForDone()
            app.processEvents()
            window.timer.stop()
            window.search_timer.stop()
            window.quitting = True
            window.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("target/linux-cleanup-preview"))
    render(parser.parse_args().output)


if __name__ == "__main__":
    main()
