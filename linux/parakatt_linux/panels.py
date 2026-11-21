"""Utility panels use the same grouped layout and compact controls as settings."""

import json

from PySide6.QtCore import QSize, Qt
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QStackedWidget,
    QTabWidget,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from .appearance import label
from .backend import diagnostics
from .desktop_widgets import button, empty_state
from .settings import group_box


def models_panel(window):
    page = QWidget()
    layout = QVBoxLayout(page)
    layout.setContentsMargins(18, 14, 18, 14)
    layout.setSpacing(14)
    layout.addWidget(label("Speech models", "heading"))
    hint = label("Download models for local recognition and optional streaming previews.")
    hint.setWordWrap(True)
    layout.addWidget(hint)
    window.models = QListWidget()
    window.models.setObjectName("modelList")
    window.models.setSpacing(4)
    window.models.setWordWrap(True)
    window.models.currentItemChanged.connect(window.model_selection_changed)
    layout.addWidget(window.models, 1)
    card, content = group_box()
    window.model_description = label("Select a model to see its purpose and available actions.")
    window.model_description.setWordWrap(True)
    content.addWidget(window.model_description)
    window.download_status = label("")
    window.download_status.setWordWrap(True)
    content.addWidget(window.download_status)
    row = QHBoxLayout()
    window.download_button = button("Download / repair", window.download_model, row)
    window.download_button.setProperty("role", "primary")
    window.cancel_download_button = button("Cancel download", window.core.cancel_download, row)
    window.cancel_download_button.setEnabled(False)
    row.addStretch()
    window.load_button = button(
        "Load speech model", lambda: window.task(window.backend.load_model, "model_loaded"), row
    )
    window.delete_model_button = button("Delete…", window.delete_model, row)
    content.addLayout(row)
    layout.addWidget(card)
    for action in (window.download_button, window.load_button, window.delete_model_button):
        action.setEnabled(False)
    return page


def tools_panel(window):
    page = QWidget()
    layout = QVBoxLayout(page)
    layout.setContentsMargins(18, 14, 18, 14)
    layout.setSpacing(14)
    layout.addWidget(label("Tools & recovery", "heading"))
    layout.addWidget(
        label("Manage history backups, processing profiles and interrupted recordings.")
    )
    tabs = QTabWidget()
    layout.addWidget(tabs)
    backup = QWidget()
    content = QVBoxLayout(backup)
    content.setContentsMargins(12, 16, 12, 12)
    content.setSpacing(18)
    content.addWidget(label("HISTORY", "eyebrow"))
    card, items = group_box()
    for title, helper, action, callback in [
        (
            "Export database",
            "Back up transcripts, speaker corrections and confirmed actions.",
            "Export…",
            lambda: window.database(False),
        ),
        (
            "Restore database",
            "Replace history from an existing backup. Source media and models stay separate.",
            "Restore…",
            lambda: window.database(True),
        ),
        (
            "Retention cleanup",
            "Apply the retention period configured in General settings.",
            "Run cleanup",
            lambda: window.task(window.core.run_retention_cleanup, "refresh"),
        ),
    ]:
        row = QHBoxLayout()
        text = QVBoxLayout()
        text.addWidget(label(title, "section"))
        note = label(helper)
        note.setWordWrap(True)
        text.addWidget(note)
        row.addLayout(text, 1)
        button(action, callback, row)
        items.addLayout(row)
    content.addWidget(card)
    content.addWidget(label("PROCESSING PROFILES", "eyebrow"))
    card, items = group_box()
    note = label(
        "Save and restore a named set of processing settings. Credentials stay in the desktop keyring."
    )
    note.setWordWrap(True)
    items.addWidget(note)
    row = QHBoxLayout()
    button("Save profile…", window.save_profile, row)
    button("Load profile…", window.load_profile, row)
    row.addStretch()
    button("Delete profile…", window.delete_profile, row)
    items.addLayout(row)
    content.addWidget(card)
    content.addStretch()
    tabs.addTab(backup, "Backups && profiles")
    recovery = QWidget()
    content = QVBoxLayout(recovery)
    content.setContentsMargins(12, 16, 12, 12)
    content.addWidget(label("Interrupted recordings", "section"))
    window.draft_status = label("No interrupted recordings to recover.")
    window.draft_status.setWordWrap(True)
    content.addWidget(window.draft_status)
    window.drafts = QListWidget()
    window.drafts.setWordWrap(True)
    window.recovery_stack = QStackedWidget()
    window.recovery_stack.addWidget(
        empty_state(
            "No interrupted recordings",
            "Recoverable recordings will appear here when retained data is available.",
            "wave",
        )
    )
    window.recovery_stack.addWidget(window.drafts)
    content.addWidget(window.recovery_stack, 1)
    row = QHBoxLayout()
    window.recover_text_button = button("Recover text", lambda: window.recover(False), row)
    window.recover_text_button.setProperty("role", "primary")
    window.recover_audio_button = button("Recover audio", lambda: window.recover(True), row)
    row.addStretch()
    window.discard_draft_button = button("Discard draft…", window.discard_draft, row)
    content.addLayout(row)
    for action in (
        window.recover_text_button,
        window.recover_audio_button,
        window.discard_draft_button,
    ):
        action.setEnabled(False)
    window.drafts.currentItemChanged.connect(
        lambda item, _previous: [
            action.setEnabled(item is not None)
            for action in (
                window.recover_text_button,
                window.recover_audio_button,
                window.discard_draft_button,
            )
        ]
    )
    tabs.addTab(recovery, "Recovery")
    diagnostic = QWidget()
    content = QVBoxLayout(diagnostic)
    content.setContentsMargins(12, 16, 12, 12)
    content.addWidget(label("Desktop diagnostics", "section"))
    info = diagnostics()
    card, items = group_box()
    form = QFormLayout()
    form.addRow("Desktop session", QLabel(str(info["session"])))
    form.addRow("Desktop", QLabel(str(info["desktop"])))
    tools = info["tools"]
    for name in ("ffmpeg", "ffprobe", "pactl", "yt-dlp", "xdotool"):
        form.addRow(name, QLabel("Available" if tools[name] else "Not found"))
    items.addLayout(form)
    content.addWidget(card)
    helper = label(
        "On Wayland, copy background recordings from History. Set global recording shortcuts in GNOME Settings → Keyboard."
    )
    helper.setWordWrap(True)
    content.addWidget(helper)
    row = QHBoxLayout()
    button(
        "Test LLM connection", lambda: window.task(window.core.test_llm_pipeline, "diagnostic"), row
    )
    button(
        "Copy diagnostics",
        lambda: QApplication.clipboard().setText(window.diagnostic.toPlainText()),
        row,
    )
    row.addStretch()
    content.addLayout(row)
    window.diagnostic_details = QCheckBox("Show technical details")
    content.addWidget(window.diagnostic_details)
    window.diagnostic = QTextEdit()
    window.diagnostic.setReadOnly(True)
    window.diagnostic.setPlainText(json.dumps(info, indent=2))
    content.addWidget(window.diagnostic, 1)
    window.diagnostic.hide()
    window.diagnostic_details.toggled.connect(window.diagnostic.setVisible)
    content.addStretch()
    tabs.addTab(diagnostic, "Diagnostics")
    window.tools_tabs = tabs
    return page


def populate_models(window, models):
    selected = window.models.currentItem()
    selected_id = selected.data(Qt.ItemDataRole.UserRole) if selected else None
    window.models.clear()
    from PySide6.QtWidgets import QListWidgetItem

    for model in models:
        purpose = "Speech recognition" if model.provider_type == "parakeet" else "Streaming preview"
        state = "Installed" if model.downloaded else "Not installed"
        item = QListWidgetItem(
            f"{model.display_name}\n{purpose}  ·  {model.size_bytes / 1e9:.2f} GB  ·  {state}"
        )
        item.setSizeHint(QSize(300, 72))
        item.setData(Qt.ItemDataRole.UserRole, model.id)
        item.setData(Qt.ItemDataRole.UserRole + 1, model)
        window.models.addItem(item)
        if model.id == selected_id:
            window.models.setCurrentItem(item)
