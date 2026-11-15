"""Capture the follow-up screens with isolated synthetic data and no account access."""

import argparse
import tempfile
from pathlib import Path

from PySide6.QtWidgets import QApplication

from .app import Window
from .authentication import Account
from .backend import Backend, Paths
from .connections import Connection
from .editors import ModeEditor, RuleEditor
from .preview import populate
from .providers import MeetingSource, TranscriptSource
from .settings import Settings
from .transcript_dialog import ConnectionDialog, TranscriptImportDialog
from .transcript_service import TranscriptService

VTT = "WEBVTT\n\n00:00:00.000 --> 00:00:05.000\n<v Alex>We should keep the imported transcript linked to its source.</v>\n\n00:00:05.000 --> 00:00:10.000\n<v Morgan>I will review the minutes and confirm the action items.</v>\n"


class DemoService(TranscriptService):
    def accounts(self, connection: Connection) -> list[Account]:
        return [Account("sample-account", "alex@example.invalid (sample)")]


def render(output: Path) -> None:
    app = QApplication.instance() or QApplication([])
    output.mkdir(parents=True, exist_ok=True)

    def save(widget, name):
        app.processEvents()
        if not widget.grab().save(str(output / f"{name}.png")):
            raise OSError(f"Could not save {name}")

    with tempfile.TemporaryDirectory(prefix="parakatt-workflows-") as directory:
        backend = Backend(Paths.discover(data=directory))
        populate(backend)
        backend.engine.set_dictionary_rules(
            [
                backend.api.ReplacementRule(
                    pattern="para cat",
                    replacement="Parakatt",
                    context_type="always",
                    context_value=None,
                    enabled=True,
                ),
                backend.api.ReplacementRule(
                    pattern="graph q l",
                    replacement="GraphQL",
                    context_type="when_mode",
                    context_value="code",
                    enabled=True,
                ),
            ]
        )
        window = Window(backend)
        window.show()
        for _ in range(3):
            window.pool.waitForDone()
            app.processEvents()
        print(
            "Model providers:", [(model.id, model.provider_type) for model in window.model_catalog]
        )
        settings = Settings(backend, window)
        settings.show()
        for index, name in [(2, "models-settings"), (3, "llm-settings"), (4, "dictionary")]:
            settings.tabs.setCurrentIndex(index)
            if index == 3:
                settings.provider.setCurrentText("ollama")
            save(settings, name)
        rule = RuleEditor(settings, "graph q l", "GraphQL", "when_mode", "code")
        rule.show()
        save(rule, "dictionary-editor")
        rule.hide()
        mode = ModeEditor(
            settings,
            "clean",
            "",
            "Fix grammar, punctuation and spacing. Preserve names, facts and meaning.",
        )
        mode.show()
        save(mode, "mode-editor")
        mode.hide()
        settings.hide()
        window.open_panel("models")
        window.models.setCurrentRow(0)
        save(window.panel_windows["models"], "model-downloads")
        window.panel_windows["models"].hide()
        window.open_panel("tools")
        for index, name in [(0, "tools-backups"), (1, "tools-recovery"), (2, "tools-diagnostics")]:
            window.tools_tabs.setCurrentIndex(index)
            save(window.panel_windows["tools"], name)
        window.panel_windows["tools"].hide()
        service = DemoService(backend)
        dialog = TranscriptImportDialog(backend, window, service)
        dialog.show()
        dialog.show_preview(service.prepare("teams", "Design review", VTT))
        save(dialog, "transcript-preview")
        teams = Connection(
            "sample-teams",
            "teams",
            "Work (sample)",
            client_id="00000000-0000-0000-0000-000000000000",
            tenant="example.onmicrosoft.com",
            meeting_links=True,
        )
        slack = Connection("sample-slack", "slack", "Office (sample)", workspace_id="SAMPLE")
        dialog.connections = [teams, slack]
        dialog.refresh_connections(teams.id)
        dialog.source_type.setCurrentIndex(1)
        for _ in range(3):
            window.pool.waitForDone()
            app.processEvents()
        dialog.meeting_reference.setText("https://teams.microsoft.com/l/meetup-join/sample")
        dialog.meeting = MeetingSource("sample-meeting", "Design review")
        dialog.teams_sources.addItem(
            "14 Nov 2026 · 09:00", TranscriptSource("sample-transcript", "Design review")
        )
        dialog.show_preview(service.prepare("teams", "Design review", VTT))
        dialog.status.setText(
            "Sample account and source for layout review. No account is connected."
        )
        save(dialog, "teams-import")
        dialog.source_type.setCurrentIndex(2)
        dialog.refresh_connections(slack.id)
        dialog.slack_sources.addItem(
            "Project Huddle (sample)", TranscriptSource("SAMPLE-FILE", "Project Huddle")
        )
        dialog.show_preview(
            service.prepare(
                "slack",
                "Project Huddle",
                '{"lines":[{"text":"We should review the updated project plan.","user_id":"U123"},{"text":"I will prepare the notes.","user_id":"U456"}]}',
            )
        )
        dialog.status.setText(
            "Sample workspace and source for layout review. No account is connected."
        )
        save(dialog, "slack-import")
        setup = ConnectionDialog("teams", dialog, teams)
        setup.show()
        save(setup, "teams-connection")
        setup.hide()
        dialog.reject()
        settings.reject()
        window.timer.stop()
        window.pool.waitForDone()
        window.quitting = True
        window.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("target/linux-workflow-preview"))
    args = parser.parse_args()
    render(args.output)
    print(f"Saved synthetic workflow previews to {args.output.resolve()}")


if __name__ == "__main__":
    main()
