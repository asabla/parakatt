"""Settings pages for the Linux desktop; values persist through the shared engine."""

import os
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QPixmap
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QScrollArea,
    QSpinBox,
    QTableWidget,
    QTableWidgetItem,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)

from .appearance import label as ui_label
from .backend import audio_sources
from .desktop_widgets import Switch, ask, button, icon


def group_box():
    box = QFrame()
    box.setObjectName("settingsGroup")
    layout = QVBoxLayout(box)
    layout.setContentsMargins(16, 14, 16, 14)
    layout.setSpacing(12)
    return box, layout


def scroll_page(widget):
    scroll = QScrollArea()
    scroll.setWidgetResizable(True)
    scroll.setWidget(widget)
    return scroll


def behavior_row(layout, title, description, control, symbol="check", color="#0a84ff"):
    row = QHBoxLayout()
    image = QLabel()
    image.setPixmap(icon(symbol, color, 27).pixmap(27, 27))
    row.addWidget(image)
    text = QVBoxLayout()
    text.setSpacing(3)
    text.addWidget(ui_label(title, "section"))
    helper = ui_label(description)
    helper.setWordWrap(True)
    text.addWidget(helper)
    row.addLayout(text, 1)
    row.addSpacing(12)
    row.addWidget(control)
    layout.addLayout(row)


def stat_cards(stats, keys):
    widget = QWidget()
    grid = QGridLayout(widget)
    grid.setContentsMargins(0, 0, 0, 0)
    grid.setSpacing(10)
    for index, key in enumerate(keys):
        card, content = group_box()
        value = ui_label(stats.get(key, "—"), "stat")
        value.setWordWrap(True)
        value.setAlignment(Qt.AlignmentFlag.AlignCenter)
        content.addWidget(value)
        title = ui_label(key)
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        content.addWidget(title)
        grid.addWidget(card, index // 3, index % 3)
    return widget


class Settings(QDialog):
    def __init__(self, backend, parent):
        super().__init__(parent)
        self.backend, self.core = backend, backend.engine
        self.setWindowTitle("Parakatt Settings")
        self.resize(820, 680)
        self.setMinimumSize(730, 500)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(12, 12, 12, 12)
        self.tabs = tabs = QTabWidget()
        tabs.setObjectName("settingsTabs")
        layout.addWidget(tabs)
        stats = dict(self.core.get_statistics())
        dashboard = QWidget()
        content = QVBoxLayout(dashboard)
        content.setContentsMargins(22, 24, 22, 24)
        content.setSpacing(20)
        brand = QHBoxLayout()
        logo = QLabel()
        logo.setPixmap(
            QPixmap(str(Path(__file__).parent / "assets" / "appicon.png")).scaled(
                60,
                60,
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation,
            )
        )
        brand.addWidget(logo)
        name = QVBoxLayout()
        name.addWidget(ui_label("Parakatt", "heading"))
        name.addWidget(ui_label("Linux desktop · Shared Parakatt engine"))
        brand.addLayout(name, 1)
        content.addLayout(brand)
        content.addWidget(ui_label("●  STATUS", "eyebrow"))
        card, items = group_box()
        settings = self.core.get_llm_settings()
        for title, value in [
            ("Speech Model", "parakeet-tdt-0.6b-v3"),
            ("Processing Mode", self.core.get_active_mode().capitalize()),
            ("LLM Provider", settings.provider or "None"),
        ]:
            row = QHBoxLayout()
            row.addWidget(QLabel(title))
            row.addStretch()
            row.addWidget(ui_label(value))
            items.addLayout(row)
        content.addWidget(card)
        content.addWidget(ui_label("▥  ACTIVITY", "eyebrow"))
        content.addWidget(
            stat_cards(stats, ["Total transcriptions", "Total duration", "Total words"])
        )
        content.addWidget(ui_label("DESKTOP ACCESS", "eyebrow"))
        card, items = group_box()
        helper = ui_label(
            "Microphone and output audio use your desktop audio service. Device availability is shown in General. Set a global shortcut in GNOME Settings."
        )
        helper.setWordWrap(True)
        items.addWidget(helper)
        items.addWidget(ui_label("Wayland: completed text is copied; paste with Ctrl+V."))
        content.addWidget(card)
        content.addStretch()
        tabs.addTab(scroll_page(dashboard), "Dashboard")

        general = QWidget()
        content = QVBoxLayout(general)
        content.setContentsMargins(18, 22, 18, 22)
        content.setSpacing(18)
        content.addWidget(ui_label("⌨  SHORTCUT", "eyebrow"))
        card, items = group_box()
        keys = ui_label("Ctrl + Space", "section")
        items.addWidget(keys)
        items.addWidget(ui_label("Toggle · Tap to start and stop while Parakatt is focused."))
        shortcut = ui_label(
            "For a global shortcut, add parakatt-desktop --toggle in GNOME Settings → Keyboard → Custom Shortcuts. Hold-to-talk is not available yet."
        )
        shortcut.setWordWrap(True)
        items.addWidget(shortcut)
        content.addWidget(card)
        content.addWidget(ui_label("Text cleanup", "section"))
        card, items = group_box()
        self.cleanup = QComboBox()
        self.cleanup.addItems([mode.name for mode in self.core.list_modes()])
        self.cleanup.setCurrentText(self.core.get_active_mode())
        items.addWidget(self.cleanup)
        helper = ui_label(
            "Processing applies to your next recording. Remote AI providers receive the recognized text and, when enabled, preceding speech as context. Failed processing keeps your original text."
        )
        helper.setWordWrap(True)
        items.addWidget(helper)
        content.addWidget(card)
        content.addWidget(ui_label("BEHAVIOR", "eyebrow"))
        card, items = group_box()
        self.copy = Switch("Copy completed dictation")
        self.copy.setChecked(backend.preferences.get("copy", True))
        behavior_row(
            items,
            "Copy completed dictation",
            "Copy text to the clipboard after recording",
            self.copy,
            "copy",
        )
        self.paste = Switch("Auto-paste transcription")
        self.paste.setChecked(self.core.get_auto_paste())
        self.paste.setEnabled(os.environ.get("XDG_SESSION_TYPE") == "x11")
        behavior_row(
            items,
            "Auto-paste transcription",
            "X11 with xdotool. On Wayland, paste copied text with Ctrl+V.",
            self.paste,
            "copy",
        )
        self.overlay = Switch("Show recording overlay")
        self.overlay.setChecked(self.core.get_show_overlay())
        behavior_row(
            items,
            "Show recording overlay",
            "Display compact recording controls above other windows",
            self.overlay,
            "sidebar",
            "#30d158",
        )
        self.recovery = Switch("Temporary audio for recovery")
        self.recovery.setChecked(self.core.get_recovery_audio())
        behavior_row(
            items,
            "Temporary audio for recovery",
            "Keep local audio for interrupted recordings within the shared engine's retention limits",
            self.recovery,
            "wave",
        )
        self.debug = Switch("Debug mode")
        self.debug.setChecked(self.core.get_debug_mode())
        behavior_row(
            items,
            "Debug mode",
            "Enable diagnostic logging without transcript contents",
            self.debug,
            "document",
            "#ff9f32",
        )
        self.labels = Switch("Microphone and system audio labels")
        self.labels.setChecked(self.core.get_speaker_labels_enabled())
        behavior_row(
            items,
            "Microphone and system audio labels",
            "Label microphone speech as Me and system audio as Speaker 1. Individual system speakers are not identified.",
            self.labels,
            "people",
            "#dc45f5",
        )
        content.addWidget(card)
        content.addWidget(ui_label("AUDIO & HISTORY", "eyebrow"))
        card, items = group_box()
        form = QFormLayout()
        self.microphone, self.system_audio = QComboBox(), QComboBox()
        self.microphone.addItem("System default microphone", "")
        self.system_audio.addItem("Monitor of default output", "")
        try:
            for name, description in audio_sources():
                self.microphone.addItem(description, name)
                self.system_audio.addItem(description, name)
        except Exception as error:
            notice = ui_label("Audio devices will appear when the audio service is available.")
            notice.setToolTip(str(error))
            notice.setWordWrap(True)
            items.addWidget(notice)
        for widget, key in [(self.microphone, "microphone"), (self.system_audio, "system_audio")]:
            saved = backend.preferences.get(key, "")
            if saved and widget.findData(saved) < 0:
                widget.addItem(saved + " (unavailable)", saved)
            widget.setCurrentIndex(max(0, widget.findData(saved)))
        form.addRow("Microphone", self.microphone)
        form.addRow("Meeting system audio", self.system_audio)
        self.chunk = QSpinBox()
        self.chunk.setRange(10, 30)
        self.chunk.setValue(self.core.get_chunk_duration())
        self.chunk.setSuffix(" seconds")
        form.addRow("Audio batch", self.chunk)
        self.retention = QSpinBox()
        self.retention.setRange(0, 36500)
        self.retention.setSpecialValueText("Keep all")
        self.retention.setValue(self.core.get_retention_days())
        form.addRow("History retention days", self.retention)
        items.addLayout(form)
        content.addWidget(card)
        content.addWidget(ui_label("CUSTOM MODES", "eyebrow"))
        self.modes = QTableWidget(0, 4)
        self.modes.setHorizontalHeaderLabels(["Name", "LLM provider", "Instructions", "Dictionary"])
        self.original_modes = {mode.name: mode for mode in self.core.list_modes()}
        for mode in self.original_modes.values():
            self.add_mode(mode)
        self.modes.setMinimumHeight(180)
        self.modes.horizontalHeader().setStretchLastSection(True)
        content.addWidget(self.modes)
        row = QHBoxLayout()
        button("+ New mode", lambda: self.add_mode(), row)
        button("Remove custom mode", self.remove_mode, row)
        row.addStretch()
        content.addLayout(row)
        tabs.addTab(scroll_page(general), "General")

        speech = QWidget()
        content = QVBoxLayout(speech)
        content.setContentsMargins(22, 24, 22, 24)
        content.addWidget(ui_label("SPEECH MODELS", "eyebrow"))
        card, items = group_box()
        items.addWidget(ui_label("parakeet-tdt-0.6b-v3", "section"))
        items.addWidget(ui_label("On-device recognition · CPU inference on Linux"))
        button("Manage downloads…", lambda: parent.open_panel("models", self), items)
        content.addWidget(card)
        form = QFormLayout()
        selected = self.core.get_speech_settings()
        self.threads = QSpinBox()
        self.threads.setRange(0, 64)
        self.threads.setValue(selected.cpu_threads)
        self.threads.setSpecialValueText("Automatic")
        self.language = QComboBox()
        self.language.addItems(["Automatic", "English", "Swedish"])
        self.language.setCurrentIndex(
            [
                backend.api.SpeechLanguage.AUTOMATIC,
                backend.api.SpeechLanguage.ENGLISH,
                backend.api.SpeechLanguage.SWEDISH,
            ].index(selected.language)
        )
        self.preview = QComboBox()
        self.preview.addItem("Disabled", None)
        for model in parent.model_catalog:
            if model.provider_type == "nemotron-streaming":
                self.preview.addItem(model.display_name, model.id)
        if selected.preview_model and self.preview.findData(selected.preview_model) < 0:
            self.preview.addItem(selected.preview_model, selected.preview_model)
        self.preview.setCurrentIndex(max(0, self.preview.findData(selected.preview_model)))
        form.addRow("CPU threads", self.threads)
        form.addRow("Preview language", self.language)
        form.addRow("Preview model", self.preview)
        content.addLayout(form)
        content.addStretch()
        tabs.addTab(speech, "Models")

        llm = QWidget()
        form = QFormLayout(llm)
        settings = self.core.get_llm_settings()
        self.provider = QComboBox()
        self.provider.addItems(["none", "ollama", "lmstudio", "openai", "anthropic"])
        self.provider.setCurrentText(settings.provider or "none")
        self.url, self.model, self.key = (
            QLineEdit(settings.base_url),
            QLineEdit(settings.model),
            QLineEdit(),
        )
        self.key.setEchoMode(QLineEdit.EchoMode.Password)
        self.key.setPlaceholderText("Leave blank to keep the stored key")
        form.addRow("Provider", self.provider)
        form.addRow("Server URL", self.url)
        form.addRow("Model", self.model)
        form.addRow("API key (desktop keyring)", self.key)
        self.context = QCheckBox("Use preceding recognized speech as context")
        self.context.setChecked(self.core.get_llm_context_enabled())
        form.addRow(self.context)
        generation = self.core.get_generation_settings()
        self.tokens = QSpinBox()
        self.tokens.setRange(1, 1000000)
        self.tokens.setValue(generation.output_limit)
        form.addRow("Output token limit", self.tokens)
        self.provider.currentTextChanged.connect(self.provider_changed)
        notice = ui_label(
            "Keys are stored in Secret Service / GNOME Keyring, never in settings files."
        )
        notice.setWordWrap(True)
        form.addRow(notice)
        tabs.addTab(llm, "LLM")

        dictionary = QWidget()
        form = QVBoxLayout(dictionary)
        notice = ui_label("Correct names and phrases. Patterns support regular expressions.")
        notice.setWordWrap(True)
        form.addWidget(notice)
        self.rules = QTableWidget(0, 5)
        self.rules.setHorizontalHeaderLabels(
            ["Pattern", "Replacement", "When", "Application / mode", "Enabled"]
        )
        for rule in self.core.get_dictionary_rules():
            self.add_rule(rule)
        self.rules.horizontalHeader().setStretchLastSection(True)
        form.addWidget(self.rules)
        row = QHBoxLayout()
        button("Add rule", lambda: self.add_rule(), row)
        button("Remove rule", lambda: self.rules.removeRow(self.rules.currentRow()), row)
        row.addStretch()
        form.addLayout(row)
        tabs.addTab(dictionary, "Dictionary")

        statistics = QWidget()
        content = QVBoxLayout(statistics)
        content.setContentsMargins(22, 24, 22, 24)
        content.setSpacing(20)
        content.addWidget(ui_label("▥  OVERVIEW", "eyebrow"))
        content.addWidget(
            stat_cards(
                stats,
                [
                    "Total transcriptions",
                    "Total duration",
                    "Total words",
                    "Avg duration",
                    "Total segments",
                    "Database size",
                ],
            )
        )
        content.addWidget(ui_label("BY TYPE", "eyebrow"))
        card, items = group_box()
        for title, value in stats.items():
            if title.startswith("Mode:") or title in ("Meetings", "Voice notes", "import"):
                row = QHBoxLayout()
                row.addWidget(QLabel(title.replace("Mode: ", "")))
                row.addStretch()
                row.addWidget(ui_label(value))
                items.addLayout(row)
        content.addWidget(card)
        if "Longest" in stats:
            longest = ui_label("Longest · " + stats["Longest"])
            longest.setWordWrap(True)
            content.addWidget(longest)
        content.addStretch()
        tabs.addTab(scroll_page(statistics), "Statistics")
        actions = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        actions.accepted.connect(lambda: ask(self, "Settings", self.save))
        actions.rejected.connect(self.reject)
        actions.button(QDialogButtonBox.StandardButton.Save).setProperty("role", "primary")
        layout.addWidget(actions)
        for form in self.findChildren(QFormLayout):
            form.setContentsMargins(16, 18, 16, 14)
            form.setVerticalSpacing(14)

    def provider_changed(self, provider):
        settings = self.core.get_provider_settings(provider)
        self.url.setText(settings.base_url)
        self.model.setText(settings.model)
        self.key.clear()

    def add_rule(self, rule=None):
        row = self.rules.rowCount()
        self.rules.insertRow(row)
        values = (
            [rule.pattern, rule.replacement, rule.context_value or ""] if rule else ["", "", ""]
        )
        for column, value in zip([0, 1, 3], values, strict=True):
            self.rules.setItem(row, column, QTableWidgetItem(value))
        context = QComboBox()
        for label, value in [
            ("Always", "always"),
            ("In application", "in_app"),
            ("In mode", "when_mode"),
        ]:
            context.addItem(label, value)
        context.setCurrentIndex(max(0, context.findData(rule.context_type if rule else "always")))
        self.rules.setCellWidget(row, 2, context)
        enabled = QTableWidgetItem()
        enabled.setCheckState(
            Qt.CheckState.Checked if rule is None or rule.enabled else Qt.CheckState.Unchecked
        )
        self.rules.setItem(row, 4, enabled)

    def add_mode(self, mode=None):
        row = self.modes.rowCount()
        self.modes.insertRow(row)
        for column, value in enumerate(
            [mode.name, mode.llm_provider or "", mode.system_prompt or ""]
            if mode
            else ["New mode", "", ""]
        ):
            self.modes.setItem(row, column, QTableWidgetItem(value))
        enabled = QTableWidgetItem()
        enabled.setCheckState(
            Qt.CheckState.Checked
            if mode is None or mode.dictionary_enabled
            else Qt.CheckState.Unchecked
        )
        self.modes.setItem(row, 3, enabled)

    def remove_mode(self):
        row = self.modes.currentRow()
        if row >= 0:
            name = self.modes.item(row, 0).text()
            if name.lower() in ("dictation", "clean", "email", "code"):
                QMessageBox.information(
                    self, "Mode", "Built-in modes can be edited but cannot be removed."
                )
            else:
                self.modes.removeRow(row)

    def save(self):
        rules = [
            self.backend.api.ReplacementRule(
                pattern=self.rules.item(row, 0).text(),
                replacement=self.rules.item(row, 1).text(),
                context_type=self.rules.cellWidget(row, 2).currentData(),
                context_value=self.rules.item(row, 3).text() or None,
                enabled=self.rules.item(row, 4).checkState() == Qt.CheckState.Checked,
            )
            for row in range(self.rules.rowCount())
        ]
        modes = []
        for row in range(self.modes.rowCount()):
            name = self.modes.item(row, 0).text().strip()
            if not name or name.lower() in [mode.name.lower() for mode in modes]:
                raise ValueError("Each mode needs a unique, non-empty name")
            original = self.original_modes.get(name)
            modes.append(
                self.backend.api.ModeConfig(
                    name=name,
                    stt_provider=original.stt_provider if original else None,
                    llm_provider=self.modes.item(row, 1).text() or None,
                    system_prompt=self.modes.item(row, 2).text() or None,
                    dictionary_enabled=self.modes.item(row, 3).checkState()
                    == Qt.CheckState.Checked,
                )
            )
        names = {mode.name.lower() for mode in modes}
        if not {"dictation", "clean", "email", "code"}.issubset(names):
            raise ValueError(
                "Keep the four built-in mode names; add a custom mode for a different name"
            )
        for rule in rules:
            message = self.core.validate_dictionary_pattern(rule.pattern)
            if message:
                raise ValueError(message)
        self.backend.configure_llm(
            self.provider.currentText(), self.url.text(), self.model.text(), self.key.text()
        )
        self.core.set_dictionary_rules(rules)
        for mode in modes:
            self.core.save_mode(mode)
        for name in self.original_modes:
            if name.lower() not in names:
                self.core.delete_mode(name)
        self.core.set_chunk_duration(self.chunk.value())
        self.core.set_recovery_audio(self.recovery.isChecked())
        self.core.set_speaker_labels_enabled(self.labels.isChecked())
        self.core.set_retention_days(self.retention.value())
        self.core.set_auto_paste(self.paste.isChecked())
        self.core.set_show_overlay(self.overlay.isChecked())
        self.core.set_debug_mode(self.debug.isChecked())
        self.core.set_active_mode(self.cleanup.currentText())
        self.core.set_llm_context_enabled(self.context.isChecked())
        generation = self.core.get_generation_settings()
        generation.output_limit = self.tokens.value()
        self.core.set_generation_settings(generation)
        speech = self.core.get_speech_settings()
        speech.cpu_threads = self.threads.value()
        speech.language = [
            self.backend.api.SpeechLanguage.AUTOMATIC,
            self.backend.api.SpeechLanguage.ENGLISH,
            self.backend.api.SpeechLanguage.SWEDISH,
        ][self.language.currentIndex()]
        speech.backend = self.backend.api.SpeechBackend.CPU
        speech.preview_model = self.preview.currentData()
        self.core.set_speech_settings(speech)
        self.core.unload_model()
        preferences = dict(
            self.backend.preferences,
            microphone=self.microphone.currentData(),
            system_audio=self.system_audio.currentData(),
            copy=self.copy.isChecked(),
        )
        self.backend.save_preferences(preferences)
        self.accept()
