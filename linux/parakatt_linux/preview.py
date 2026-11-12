"""Render review screenshots from isolated synthetic data, without audio capture."""

import argparse
import tempfile
from datetime import UTC, datetime, timedelta
from pathlib import Path

from PySide6.QtWidgets import QApplication

from .app import Window
from .backend import Backend, Paths
from .settings import Settings


def populate(backend):
    examples = [
        (
            "Sprint planning",
            "The release checklist is ready. We should review the accessibility changes before Friday.",
            "meeting",
            184,
        ),
        (
            "Note 2026-11-12 16:24",
            "Please add a short setup guide to the project readme. Include the Linux dependencies and an example command.",
            "push_to_talk",
            16,
        ),
        (
            "Note 2026-11-12 15:37",
            "The new search makes it easier to find meeting decisions. Next, let us review the timeline and export options.",
            "push_to_talk",
            12,
        ),
        (
            "Customer interview",
            "The team needs a faster way to prepare meeting notes and share confirmed action items.",
            "import",
            427,
        ),
        (
            "Note 2026-11-12 14:09",
            "Remember to check the microphone before the afternoon call.",
            "push_to_talk",
            8,
        ),
        (
            "Product discussion",
            "We agreed to keep the interface familiar and make the recording controls easier to reach.",
            "meeting",
            95,
        ),
    ]
    for index, (title, text, source, seconds) in enumerate(examples):
        backend.engine.save_transcription(
            backend.api.StoredTranscription(
                id=f"demo-{index}",
                created_at=(
                    datetime(2026, 11, 12, 16, 24, tzinfo=UTC) - timedelta(minutes=index * 43)
                ).isoformat(),
                duration_secs=seconds,
                source=source,
                mode="dictation",
                audio_source=None,
                app_context=None,
                title=title,
                text=text,
            )
        )
    backend.engine.import_transcript(
        backend.api.TranscriptImportRequest(
            provider=backend.api.TranscriptProvider.TEAMS,
            source_id="synthetic-demo",
            title="Design review",
            content=(
                "WEBVTT\n\n00:00:00.000 --> 00:00:06.000\n"
                "<v Alex>The history window should use a simple split view with search above the list.</v>\n\n"
                "00:00:06.000 --> 00:00:12.000\n"
                "<v Morgan>Agreed. Keep the same settings tabs, and make the recording controls easy to find.</v>\n\n"
                "00:00:12.000 --> 00:00:18.000\n"
                "<v Alex>I will check the keyboard navigation and share the updated build tomorrow.</v>\n"
            ),
        )
    )


def render(output):
    app = QApplication.instance() or QApplication([])
    output.mkdir(parents=True, exist_ok=True)

    def save(widget, name):
        app.processEvents()
        if not widget.grab().save(str(output / f"{name}.png")):
            raise OSError(f"Could not save {name} screenshot")

    with tempfile.TemporaryDirectory(prefix="parakatt-preview-") as directory:
        backend = Backend(Paths.discover(data=directory))
        populate(backend)
        window = Window(backend)
        settings = None
        try:
            window.show()
            for _ in range(3):
                window.pool.waitForDone()
                app.processEvents()
            save(window, "history-empty")
            window.history.setCurrentRow(0)
            save(window, "history")
            window.history_view.setCurrentIndex(1)
            save(window, "timeline")
            settings = Settings(backend, window)
            settings.show()
            for index, name in [(0, "dashboard"), (1, "general"), (5, "statistics")]:
                settings.tabs.setCurrentIndex(index)
                save(settings, name)
            settings.hide()
            # Stage the reference states without starting hardware or inventing levels.
            window.live_window.reset(True)
            window.live_window.mode_name = "Dictation"
            window.live_window.update_clock(6, 30, True)
            window.live_window.show()
            save(window.live_window, "meeting")
            window.overlay.state.setText("Recording")
            window.overlay.model.setText("Transcription model ready")
            window.overlay.show()
            save(window.overlay, "overlay")
        finally:
            if settings:
                settings.hide()
            window.overlay.hide()
            window.live_window.active = False
            window.live_window.hide()
            window.timer.stop()
            window.recording_timer.stop()
            window.pool.waitForDone()
            window.player.stop()
            window.quitting = True
            window.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("target/linux-ui-preview"))
    args = parser.parse_args()
    render(args.output)
    print(f"Saved synthetic desktop previews to {args.output.resolve()}")


if __name__ == "__main__":
    main()
