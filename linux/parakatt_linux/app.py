"""Qt desktop UI for the shared Parakatt engine."""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QObject, QRunnable, QSize, Qt, QThreadPool, QTimer, QUrl, Signal
from PySide6.QtGui import QAction, QIcon, QKeySequence, QShortcut
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QFrame,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPushButton,
    QSlider,
    QSpinBox,
    QSplitter,
    QStyle,
    QSystemTrayIcon,
    QTableWidget,
    QTableWidgetItem,
    QTabWidget,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from .appearance import apply_appearance
from .appearance import label as ui_label
from .backend import (
    Backend,
    Importer,
    Paths,
    Recording,
    audio_sources,
    diagnostics,
    probe,
    subtitle_text,
)


class Events(QObject):
    message = Signal(str, object)


class Task(QRunnable):
    def __init__(self, function, events, kind):
        super().__init__()
        self.function, self.events, self.kind = function, events, kind

    def run(self):
        try:
            self.events.message.emit(self.kind, self.function())
        except Exception as error:
            self.events.message.emit("error", str(error))


def button(label, function, layout):
    widget = QPushButton(label)
    widget.clicked.connect(function)
    layout.addWidget(widget)
    return widget


def ask(parent, title, function):
    try:
        return function()
    except Exception as error:
        QMessageBox.warning(parent, title, str(error))
        return None


class Settings(QDialog):
    def __init__(self, backend, parent):
        super().__init__(parent)
        self.backend, self.core = backend, backend.engine
        self.setWindowTitle("Parakatt settings")
        self.resize(760, 700)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 24, 28, 24)
        layout.setSpacing(18)
        layout.addWidget(ui_label("Make it yours", "heading"))
        layout.addWidget(ui_label("Audio, speech, and the way you work."))
        tabs = QTabWidget()
        layout.addWidget(tabs)
        general = QWidget()
        form = QFormLayout(general)
        self.microphone = QComboBox()
        self.system_audio = QComboBox()
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
            form.addRow(notice)
        for widget, key in [(self.microphone, "microphone"), (self.system_audio, "system_audio")]:
            index = widget.findData(backend.preferences.get(key, ""))
            widget.setCurrentIndex(max(0, index))
        form.addRow("Microphone", self.microphone)
        form.addRow("Meeting system audio", self.system_audio)
        self.chunk = QSpinBox()
        self.chunk.setRange(10, 30)
        self.chunk.setValue(self.core.get_chunk_duration())
        form.addRow("Audio chunk seconds", self.chunk)
        self.copy = QCheckBox("Copy completed dictation to clipboard")
        self.copy.setChecked(backend.preferences.get("copy", True))
        form.addRow(self.copy)
        self.paste = QCheckBox("Paste into the focused application (X11 only; requires xdotool)")
        self.paste.setChecked(self.core.get_auto_paste())
        self.paste.setEnabled(os.environ.get("XDG_SESSION_TYPE") == "x11")
        form.addRow(self.paste)
        self.recovery = QCheckBox("Keep recovery audio for interrupted recordings")
        self.recovery.setChecked(self.core.get_recovery_audio())
        form.addRow(self.recovery)
        self.labels = QCheckBox("Label meeting microphone as Me and system audio as Speaker 1")
        self.labels.setChecked(self.core.get_speaker_labels_enabled())
        form.addRow(self.labels)
        self.retention = QSpinBox()
        self.retention.setRange(0, 36500)
        self.retention.setSpecialValueText("Keep all")
        self.retention.setValue(self.core.get_retention_days())
        form.addRow("History retention days", self.retention)
        shortcut = QLabel(
            "Add a GNOME custom shortcut for <b>parakatt-desktop --toggle</b>.<br>On Wayland, paste completed text with Ctrl+V."
        )
        shortcut.setWordWrap(True)
        form.addRow(shortcut)
        tabs.addTab(general, "General")

        llm = QWidget()
        form = QFormLayout(llm)
        settings = self.core.get_llm_settings()
        self.provider = QComboBox()
        self.provider.addItems(["none", "ollama", "lmstudio", "openai", "anthropic"])
        self.provider.setCurrentText(settings.provider or "none")
        self.url = QLineEdit(settings.base_url)
        self.model = QLineEdit(settings.model)
        self.key = QLineEdit()
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
        form.addRow(
            QLabel("Keys are stored in Secret Service / GNOME Keyring, never in settings files.")
        )
        tabs.addTab(llm, "LLM")

        speech = QWidget()
        form = QFormLayout(speech)
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
        self.preview.setCurrentIndex(max(0, self.preview.findData(selected.preview_model)))
        form.addRow("CPU threads", self.threads)
        form.addRow("Preview language", self.language)
        form.addRow("Preview model", self.preview)
        form.addRow(QLabel("Linux inference uses CPU. Install speech models in the Models tab."))
        tabs.addTab(speech, "Speech")

        dictionary = QWidget()
        form = QVBoxLayout(dictionary)
        form.addWidget(QLabel("Correct names and phrases. Patterns support regular expressions."))
        self.rules = QTableWidget(0, 5)
        self.rules.setHorizontalHeaderLabels(
            ["Pattern", "Replacement", "When", "Application / mode", "Enabled"]
        )
        for rule in self.core.get_dictionary_rules():
            self.add_rule(rule)
        form.addWidget(self.rules)
        row = QHBoxLayout()
        button("Add rule", lambda: self.add_rule(), row)
        button("Remove rule", lambda: self.rules.removeRow(self.rules.currentRow()), row)
        form.addLayout(row)
        tabs.addTab(dictionary, "Dictionary")
        modes = QWidget()
        form = QVBoxLayout(modes)
        form.addWidget(QLabel("Double-click a cell to edit a processing mode or its instructions."))
        self.modes = QTableWidget(0, 4)
        self.modes.setHorizontalHeaderLabels(["Name", "LLM provider", "Instructions", "Dictionary"])
        self.original_modes = {mode.name: mode for mode in self.core.list_modes()}
        for mode in self.original_modes.values():
            self.add_mode(mode)
        self.modes.horizontalHeader().setStretchLastSection(True)
        form.addWidget(self.modes)
        row = QHBoxLayout()
        button("Add mode", lambda: self.add_mode(), row)
        button("Remove custom mode", self.remove_mode, row)
        form.addLayout(row)
        tabs.addTab(modes, "Modes")
        actions = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        actions.accepted.connect(lambda: ask(self, "Settings", self.save))
        actions.rejected.connect(self.reject)
        layout.addWidget(actions)
        actions.button(QDialogButtonBox.StandardButton.Save).setProperty("role", "primary")
        for form in self.findChildren(QFormLayout):
            form.setContentsMargins(14, 22, 14, 16)
            form.setVerticalSpacing(15)
        for action in actions.buttons():
            if actions.buttonRole(action) == QDialogButtonBox.ButtonRole.AcceptRole:
                action.setProperty("role", "primary")

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


class Window(QMainWindow):
    def __init__(self, backend):
        super().__init__()
        apply_appearance()
        self.backend, self.core = backend, backend.engine
        self.events = Events()
        self.events.message.connect(self.on_event)
        self.pool = QThreadPool(self)
        self.pool.setMaxThreadCount(2)
        self.recording = None
        self.importer = None
        self.selected = None
        self.history_offset = 0
        self.history_generation = 0
        self.model_catalog = []
        self.quitting = False
        self.setWindowTitle("Parakatt")
        self.resize(1280, 840)
        self.setMinimumSize(1080, 700)
        self.setWindowIcon(
            QIcon.fromTheme(
                "audio-input-microphone",
                self.style().standardIcon(QStyle.StandardPixmap.SP_MediaVolume),
            )
        )
        central = QWidget()
        shell = QHBoxLayout(central)
        shell.setContentsMargins(0, 0, 0, 0)
        shell.setSpacing(0)
        sidebar = QFrame()
        sidebar.setObjectName("sidebar")
        sidebar.setFixedWidth(212)
        side = QVBoxLayout(sidebar)
        side.setContentsMargins(20, 30, 20, 24)
        side.setSpacing(14)
        brand = QHBoxLayout()
        mark = QLabel("≋")
        mark.setObjectName("brandMark")
        mark.setAlignment(Qt.AlignmentFlag.AlignCenter)
        mark.setFixedSize(40, 40)
        brand.addWidget(mark)
        brand.addWidget(ui_label("parakatt", "section"))
        brand.addStretch()
        side.addLayout(brand)
        side.addSpacing(28)
        side.addWidget(ui_label("YOUR WORKSPACE", "eyebrow"))
        self.navigation = QListWidget()
        self.navigation.setObjectName("navigation")
        self.navigation.addItems(
            ["Capture", "History", "Imports", "Speech models", "Tools & recovery"]
        )
        side.addWidget(self.navigation)
        private = QFrame()
        private_layout = QVBoxLayout(private)
        private_layout.setContentsMargins(8, 8, 8, 8)
        private_layout.addWidget(ui_label("●  Local by design", "badge"))
        private_layout.addWidget(ui_label("Your voice stays with you."))
        side.addWidget(private)
        settings_row = QHBoxLayout()
        self.settings_button = button("Settings", self.settings, settings_row)
        self.settings_button.setProperty("role", "quiet")
        side.addLayout(settings_row)
        shell.addWidget(sidebar)
        workspace = QWidget()
        layout = QVBoxLayout(workspace)
        layout.setContentsMargins(32, 28, 32, 18)
        layout.setSpacing(25)
        bar = QHBoxLayout()
        heading = QVBoxLayout()
        heading.setSpacing(5)
        self.page_heading = ui_label("Capture", "heading")
        self.page_description = ui_label("A little less typing. A little more thinking.")
        heading.addWidget(self.page_heading)
        heading.addWidget(self.page_description)
        bar.addLayout(heading)
        bar.addStretch()
        self.mode = QComboBox()
        self.mode.setMinimumWidth(120)
        self.refresh_modes()
        self.mode.currentTextChanged.connect(
            lambda name: ask(self, "Mode", lambda: self.core.set_active_mode(name))
        )
        bar.addWidget(self.mode)
        self.meeting_button = button("Start meeting", lambda: self.toggle_recording(True), bar)
        self.record_button = button("●  Record", self.toggle_recording, bar)
        self.record_button.setProperty("role", "primary")
        layout.addLayout(bar)
        self.tabs = QTabWidget()
        self.tabs.tabBar().hide()
        self.navigation.currentRowChanged.connect(self.tabs.setCurrentIndex)
        self.tabs.currentChanged.connect(self.change_page)
        layout.addWidget(self.tabs)
        shell.addWidget(workspace, 1)
        self.setCentralWidget(central)
        self.setup_live()
        self.setup_history()
        self.setup_imports()
        self.setup_models()
        self.setup_tools()
        self.navigation.setCurrentRow(0)
        self.statusBar().showMessage(
            "; ".join(backend.startup_warnings) or "Ready. Speech processing runs locally."
        )
        self.tray = QSystemTrayIcon(self.windowIcon(), self)
        menu = QMenu(self)
        for label, callback in [
            ("Open Parakatt", self.show_window),
            ("Start / stop dictation", self.toggle_recording),
            ("Start / stop meeting", lambda: self.toggle_recording(True)),
            ("Quit", self.quit),
        ]:
            action = QAction(label, self)
            action.triggered.connect(callback)
            menu.addAction(action)
        self.tray.setContextMenu(menu)
        self.tray.setToolTip("Parakatt")
        self.tray.activated.connect(lambda _: self.show_window())
        if QSystemTrayIcon.isSystemTrayAvailable():
            self.tray.show()
        self.shortcut = QShortcut(QKeySequence("Ctrl+Space"), self)
        self.shortcut.activated.connect(self.toggle_recording)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.poll)
        self.timer.start(1000)
        self.refresh_history()
        self.refresh_imports()
        self.refresh_models()
        self.refresh_recovery()

    def task(self, function, kind="done"):
        self.pool.start(Task(function, self.events, kind))

    def change_page(self, index):
        titles = [
            "Capture",
            "Your words, collected.",
            "Bring it all together.",
            "A voice for every thought.",
            "A little housekeeping.",
        ]
        descriptions = [
            "A little less typing. A little more thinking.",
            "Recordings, meetings, and ideas worth keeping.",
            "Turn audio and video into something you can use.",
            "Speech recognition that runs right here on your computer.",
            "Backups, profiles, and interrupted recordings.",
        ]
        self.page_heading.setText(titles[index])
        self.page_description.setText(descriptions[index])
        self.navigation.blockSignals(True)
        self.navigation.setCurrentRow(index)
        self.navigation.blockSignals(False)

    def setup_live(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(22)
        hero = QFrame()
        hero.setObjectName("captureHero")
        hero_layout = QVBoxLayout(hero)
        hero_layout.setContentsMargins(34, 30, 34, 30)
        hero_layout.setSpacing(14)
        hero_layout.addWidget(ui_label("ROOM TO THINK", "eyebrow"))
        hero_layout.addWidget(ui_label("Say what’s on your mind.", "heading"))
        self.live_status = ui_label(
            "Record a quick thought, dictate a draft, or bring your next meeting along."
        )
        self.live_status.setWordWrap(True)
        hero_layout.addWidget(self.live_status)
        hero_layout.addWidget(
            ui_label("On-device speech recognition  ·  Ready when you are", "muted")
        )
        layout.addWidget(hero)
        card = QFrame()
        card.setObjectName("liveCard")
        content = QVBoxLayout(card)
        content.setContentsMargins(28, 24, 28, 24)
        row = QHBoxLayout()
        row.addWidget(ui_label("YOUR TRANSCRIPT", "eyebrow"))
        row.addStretch()
        button(
            "Copy text", lambda: QApplication.clipboard().setText(self.live_text.toPlainText()), row
        ).setProperty("role", "quiet")
        content.addLayout(row)
        self.live_text = QTextEdit()
        self.live_text.setObjectName("liveText")
        self.live_text.setPlaceholderText("Your words will appear here.")
        self.live_text.setReadOnly(True)
        self.live_text.document().setDocumentMargin(10)
        content.addWidget(self.live_text)
        self.preview_text = ui_label("")
        self.preview_text.setWordWrap(True)
        content.addWidget(self.preview_text)
        layout.addWidget(card, 1)
        layout.addWidget(
            ui_label(
                "TIP   Bind a desktop shortcut to capture ideas without leaving your flow.", "muted"
            )
        )
        self.tabs.addTab(page, "Live")

    def setup_history(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(18)
        row = QHBoxLayout()
        self.search = QLineEdit()
        self.search.setPlaceholderText("Search your words…")
        self.search.returnPressed.connect(self.refresh_history)
        self.search.setMaximumWidth(340)
        row.addWidget(self.search)
        button("Search", self.refresh_history, row).setProperty("role", "quiet")
        row.addStretch()
        button("Load more", self.more_history, row).setProperty("role", "quiet")
        layout.addLayout(row)
        splitter = QSplitter()
        splitter.setHandleWidth(20)
        self.history = QListWidget()
        self.history.setObjectName("recordings")
        self.history.setWordWrap(True)
        self.history.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.history.setTextElideMode(Qt.TextElideMode.ElideRight)
        self.history.setMinimumWidth(245)
        self.history.currentItemChanged.connect(self.select_history)
        splitter.addWidget(self.history)
        detail = QFrame()
        detail.setObjectName("paper")
        content = QVBoxLayout(detail)
        content.setContentsMargins(28, 26, 28, 24)
        content.setSpacing(15)
        row = QHBoxLayout()
        row.addWidget(ui_label("TRANSCRIPT", "eyebrow"))
        row.addStretch()
        self.original = QCheckBox("Original text")
        self.original.toggled.connect(self.load_selected)
        row.addWidget(self.original)
        content.addLayout(row)
        self.title = QLineEdit()
        self.title.setObjectName("recordingTitle")
        self.title.setPlaceholderText("A thought worth keeping")
        content.addWidget(self.title)
        self.recording_meta = ui_label("Select a recording to settle in.")
        content.addWidget(self.recording_meta)
        self.transcript = QTextEdit()
        self.transcript.setObjectName("transcript")
        self.transcript.setPlaceholderText("Your recordings have a home here.")
        self.transcript.document().setDocumentMargin(6)
        content.addWidget(self.transcript, 1)
        self.segments = QListWidget()
        self.segments.itemActivated.connect(self.seek_segment)
        self.segments.setMaximumHeight(110)
        self.segments.hide()
        content.addWidget(self.segments)
        row = QHBoxLayout()
        timeline = button(
            "Sentence timeline", lambda: self.segments.setVisible(self.segments.isHidden()), row
        )
        timeline.setProperty("role", "quiet")
        row.addStretch()
        self.open_media = button("Open video", self.load_video, row)
        self.open_media.setProperty("role", "quiet")
        content.addLayout(row)
        row = QHBoxLayout()
        button("Save changes", self.save_edit, row).setProperty("role", "primary")
        button("Copy", lambda: QApplication.clipboard().setText(self.transcript.toPlainText()), row)
        button("Export…", self.export, row)
        row.addStretch()
        more = button("More", lambda: None, row)
        more.setProperty("role", "quiet")
        menu = QMenu(more)
        for title, callback in [
            ("Meeting actions…", self.meeting_actions),
            ("Correct speaker name…", self.correct_speaker),
            ("Undo last edit", lambda: self.history_action(self.core.undo_transcription_edit)),
            (
                "Retry LLM processing",
                lambda: self.history_action(self.core.retry_history_processing),
            ),
            ("Delete recording…", self.delete_history),
        ]:
            menu.addAction(title, callback)
        more.setMenu(menu)
        content.addLayout(row)
        self.video = QVideoWidget()
        self.video.setMinimumHeight(180)
        self.video.hide()
        content.addWidget(self.video)
        self.player = QMediaPlayer(self)
        self.audio = QAudioOutput(self)
        self.player.setAudioOutput(self.audio)
        self.player.setVideoOutput(self.video)
        self.playback_track = 0
        self.player.tracksChanged.connect(
            lambda: self.player.setActiveAudioTrack(self.playback_track)
        )
        self.player.errorOccurred.connect(
            lambda _error, message: self.statusBar().showMessage(f"Playback: {message}")
        )
        self.media_controls = QWidget()
        row = QHBoxLayout(self.media_controls)
        row.setContentsMargins(0, 0, 0, 0)
        button("Play / pause", self.play_pause, row)
        self.seek = QSlider(Qt.Orientation.Horizontal)
        self.seek.sliderMoved.connect(self.player.setPosition)
        self.player.durationChanged.connect(lambda value: self.seek.setRange(0, value))
        self.player.positionChanged.connect(self.seek.setValue)
        row.addWidget(self.seek)
        speed = QComboBox()
        speed.addItems(["0.5×", "1×", "1.5×", "2×"])
        speed.setCurrentIndex(1)
        speed.currentIndexChanged.connect(
            lambda index: self.player.setPlaybackRate([0.5, 1, 1.5, 2][index])
        )
        row.addWidget(speed)
        volume = QSlider(Qt.Orientation.Horizontal)
        volume.setRange(0, 100)
        volume.setValue(100)
        volume.setMaximumWidth(90)
        volume.valueChanged.connect(lambda value: self.audio.setVolume(value / 100))
        row.addWidget(volume)
        content.addWidget(self.media_controls)
        self.media_controls.hide()
        splitter.addWidget(detail)
        splitter.setSizes([260, 700])
        layout.addWidget(splitter)
        self.tabs.addTab(page, "History")

    def setup_imports(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(22)
        hero = QFrame()
        hero.setObjectName("captureHero")
        hero_layout = QVBoxLayout(hero)
        hero_layout.setContentsMargins(30, 28, 30, 28)
        hero_layout.setSpacing(14)
        hero_layout.addWidget(ui_label("FROM WATCHING TO UNDERSTANDING", "eyebrow"))
        hero_layout.addWidget(ui_label("Every recording has a story.", "heading"))
        note = ui_label("Bring in a conversation, a lecture, or a video. We’ll find the words.")
        note.setWordWrap(True)
        hero_layout.addWidget(note)
        row = QHBoxLayout()
        button("Choose audio or video", self.import_file, row).setProperty("role", "primary")
        button("Paste a link", self.import_link, row)
        button("Import transcript…", self.import_transcript, row)
        row.addStretch()
        hero_layout.addLayout(row)
        layout.addWidget(hero)
        row = QHBoxLayout()
        row.addWidget(ui_label("YOUR IMPORTS", "eyebrow"))
        row.addStretch()
        button("Pause", self.pause_import, row).setProperty("role", "quiet")
        button("Resume", self.resume_import, row).setProperty("role", "quiet")
        more = button("Manage source", lambda: None, row)
        more.setProperty("role", "quiet")
        menu = QMenu(more)
        menu.addAction("Locate original file…", self.locate_source)
        menu.addAction("Remove downloaded media…", self.remove_media)
        more.setMenu(menu)
        layout.addLayout(row)
        self.jobs = QListWidget()
        layout.addWidget(self.jobs, 1)
        browser_row = QHBoxLayout()
        browser_row.addWidget(ui_label("YouTube sign-in"))
        self.browser = QComboBox()
        self.browser.addItems(["None", "firefox", "chromium", "chrome", "brave"])
        self.browser.setMaximumWidth(180)
        browser_row.addWidget(self.browser)
        browser_row.addStretch()
        browser_row.addWidget(ui_label("Applies to your next import only."))
        layout.addLayout(browser_row)
        layout.addWidget(ui_label("Pick up where you left off. Pausing keeps your progress safe."))
        self.tabs.addTab(page, "Imports")

    def setup_models(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        self.models = QListWidget()
        layout.addWidget(self.models)
        self.download_status = QLabel()
        layout.addWidget(self.download_status)
        row = QHBoxLayout()
        button("Download / repair", self.download_model, row)
        button("Cancel download", self.core.cancel_download, row)
        button("Load speech model", lambda: self.task(self.backend.load_model, "model_loaded"), row)
        button("Delete model", self.delete_model, row)
        layout.addLayout(row)
        self.tabs.addTab(page, "Models")

    def setup_tools(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        row = QHBoxLayout()
        button("Export database…", lambda: self.database(False), row)
        button("Restore database…", lambda: self.database(True), row)
        button("Test LLM", lambda: self.task(self.core.test_llm_pipeline, "diagnostic"), row)
        button(
            "Run retention cleanup",
            lambda: self.task(self.core.run_retention_cleanup, "refresh"),
            row,
        )
        layout.addLayout(row)
        row = QHBoxLayout()
        button("Save settings profile…", self.save_profile, row)
        button("Load settings profile…", self.load_profile, row)
        button("Delete settings profile…", self.delete_profile, row)
        layout.addLayout(row)
        layout.addWidget(QLabel("Interrupted recordings"))
        self.drafts = QListWidget()
        layout.addWidget(self.drafts)
        row = QHBoxLayout()
        button("Recover committed text", lambda: self.recover(False), row)
        button("Recover saved audio", lambda: self.recover(True), row)
        button("Discard draft", self.discard_draft, row)
        layout.addLayout(row)
        self.diagnostic = QTextEdit()
        self.diagnostic.setReadOnly(True)
        self.diagnostic.setPlainText(json.dumps(diagnostics(), indent=2))
        layout.addWidget(self.diagnostic)
        self.tabs.addTab(page, "Tools & recovery")

    def show_window(self):
        self.showNormal()
        self.raise_()
        self.activateWindow()

    def refresh_modes(self):
        self.mode.blockSignals(True)
        self.mode.clear()
        self.mode.addItems([mode.name for mode in self.core.list_modes()])
        self.mode.setCurrentText(self.core.get_active_mode())
        self.mode.blockSignals(False)

    def settings(self):
        if self.recording or self.importer:
            QMessageBox.information(
                self,
                "Settings",
                "Stop recording and pause the import before changing processing settings.",
            )
            return
        if Settings(self.backend, self).exec():
            self.refresh_modes()

    def toggle_recording(self, meeting=False):
        if self.recording:
            self.recording.stop()
            self.record_button.setEnabled(False)
            self.meeting_button.setEnabled(False)
            self.live_status.setText("Finishing recording…")
            return
        self.recording = Recording(
            self.backend, meeting, self.mode.currentText(), self.events.message.emit
        )
        self.record_button.setText("Stop recording")
        self.meeting_button.setText("Stop meeting" if meeting else "Stop recording")
        self.settings_button.setEnabled(False)
        self.mode.setEnabled(False)
        self.live_text.clear()
        self.live_status.setText("Loading speech model…")
        self.tabs.setCurrentIndex(0)
        self.recording.start()

    def on_event(self, kind, value):
        if kind == "error":
            self.statusBar().showMessage(value)
            self.live_status.setText(value)
            if self.isVisible():
                QMessageBox.warning(self, "Parakatt", value)
            else:
                self.tray.showMessage("Parakatt", value, QSystemTrayIcon.MessageIcon.Warning)
        elif kind == "live":
            self.live_text.setPlainText(value)
            self.preview_text.clear()
        elif kind == "preview":
            self.preview_text.setText("Microphone preview: " + value)
        elif kind == "recorded":
            self.live_text.setPlainText(value.text)
            if self.backend.preferences.get("copy", True):
                QApplication.clipboard().setText(value.text)
            if self.core.get_auto_paste() and os.environ.get("XDG_SESSION_TYPE") == "x11":
                self.task(
                    lambda: subprocess.run(
                        ["xdotool", "key", "--clearmodifiers", "ctrl+v"], check=True
                    )
                )
            self.live_status.setText(
                "Recording saved. Text copied."
                if self.backend.preferences.get("copy", True)
                else "Recording saved."
            )
        elif kind == "recording_done":
            self.preview_text.clear()
            self.recording = None
            self.record_button.setText("●  Record")
            self.meeting_button.setText("Start meeting")
            self.record_button.setEnabled(True)
            self.meeting_button.setEnabled(True)
            self.settings_button.setEnabled(True)
            self.mode.setEnabled(True)
            self.refresh_history()
            self.refresh_recovery()
        elif kind == "import_done":
            self.importer = None
            self.refresh_imports()
            self.refresh_history()
        elif kind == "import_progress":
            self.statusBar().showMessage(
                f"Import: {value.processed_until:.1f} / {value.attachment.duration_secs:.1f} seconds"
            )
            self.refresh_imports()
            self.refresh_history()
        elif kind == "history":
            generation, offset, rows = value
            if generation == self.history_generation:
                self.populate_history(rows, offset)
        elif kind == "refresh":
            self.refresh_history()
            self.refresh_recovery()
        elif kind == "diagnostic":
            self.diagnostic.setPlainText(
                "\n".join(
                    f"{name}: {getattr(value, name)}"
                    for name in ("connection", "authentication", "model", "completion")
                )
            )
        elif kind == "transcript_imported":
            self.refresh_history()
            self.tabs.setCurrentIndex(1)
            self.statusBar().showMessage(
                "Transcript imported"
                if value.created
                else "Transcript already exists; original edits retained"
            )
        elif kind == "models":
            self.model_catalog = value
            self.populate_models(value)
        elif kind == "model_loaded":
            self.statusBar().showMessage("Speech model loaded")
        elif kind == "status":
            self.statusBar().showMessage(value)
            self.live_status.setText(value)
        if self.quitting:
            self.finish_quit()

    def poll(self):
        progress = self.core.get_download_progress()
        self.download_status.setText(
            f"{progress.current_file}  {progress.bytes_downloaded / 1000000:.1f} / {progress.bytes_total / 1000000:.1f} MB  {progress.state}"
        )
        if (
            progress.state.is_COMPLETED()
            and getattr(self, "last_download", None) != progress.model_id
        ):
            self.last_download = progress.model_id
            self.refresh_models()
        if self.recording:
            for event in self.core.poll_transcription_events(self.recording.id):
                if event.error:
                    self.statusBar().showMessage(event.error)
        if self.quitting:
            self.finish_quit()

    def refresh_history(self):
        self.history_offset = 0
        self.history_generation += 1
        generation = self.history_generation
        query = self.search.text()
        self.task(lambda: (generation, 0, self.backend.history(query)), "history")

    def more_history(self):
        self.history_offset += 100
        query, offset = self.search.text(), self.history_offset
        generation = self.history_generation
        self.task(lambda: (generation, offset, self.backend.history(query, offset)), "history")

    def populate_history(self, rows, offset=0):
        selected = self.selected
        if offset == 0:
            self.history.clear()
        for row in rows:
            item = QListWidgetItem(
                f"{row.title or row.text[:44] or 'Untitled'}\n\n{datetime.fromisoformat(row.created_at.replace('Z', '+00:00')):%b %d}  ·  {row.duration_secs:.0f}s  ·  {row.mode.capitalize()}"
            )
            item.setData(Qt.ItemDataRole.UserRole, row.id)
            item.setSizeHint(QSize(230, 108))
            self.history.addItem(item)
            if row.id == selected:
                self.history.setCurrentItem(item)

    def select_history(self, item, _previous):
        self.player.stop()
        self.player.setSource(QUrl())
        self.video.hide()
        self.media_controls.hide()
        self.selected = item.data(Qt.ItemDataRole.UserRole) if item else None
        self.load_selected()

    def load_selected(self):
        if not self.selected:
            self.title.clear()
            self.transcript.clear()
            self.segments.clear()
            return
        row = self.core.get_transcription(self.selected)
        self.title.setText(row.title or "")
        date = datetime.fromisoformat(row.created_at.replace("Z", "+00:00"))
        self.recording_meta.setText(
            f"{date:%B %d, %Y}   ·   {row.duration_secs:.0f} seconds   ·   {row.mode.capitalize()}"
        )
        text = (
            self.core.get_transcription_processing(self.selected).recognized_text
            if self.original.isChecked()
            else row.text
        )
        if (
            not self.original.isChecked()
            and text == self.core.get_transcription_processing(self.selected).recognized_text
        ):
            try:
                cues = self.core.get_imported_utterances(self.selected)
                text = "\n\n".join(
                    (f"{cue.speaker}: " if cue.speaker else "") + cue.text for cue in cues
                )
            except Exception:
                pass  # Audio recordings have no imported-utterance record.
        self.transcript.setPlainText(text)
        self.transcript.setReadOnly(self.original.isChecked())
        self.segments.clear()
        for segment in self.core.get_transcription_segments(self.selected):
            label = f"{segment.start_secs:.1f}s  {segment.speaker + ': ' if segment.speaker else ''}{segment.text}"
            item = QListWidgetItem(label)
            item.setData(Qt.ItemDataRole.UserRole, segment.start_secs)
            self.segments.addItem(item)

    def history_action(self, function):
        if self.selected:
            selected = self.selected
            self.task(lambda: function(selected), "refresh")

    def save_edit(self):
        if self.selected and not self.original.isChecked():
            selected, text, title = self.selected, self.transcript.toPlainText(), self.title.text()

            def save():
                self.core.update_transcription_title(selected, title)
                self.core.edit_transcription(selected, text)

            self.task(save, "refresh")

    def delete_history(self):
        if self.importer and self.importer.job.id == self.selected:
            QMessageBox.information(
                self, "Import active", "Pause the import before deleting its transcript."
            )
            return
        if (
            self.selected
            and QMessageBox.question(
                self,
                "Delete recording",
                "Delete this transcript? External media files will remain.",
            )
            == QMessageBox.StandardButton.Yes
        ):
            self.history_action(self.core.delete_transcription)
            self.selected = None

    def correct_speaker(self):
        if not self.selected:
            return
        original, ok = QInputDialog.getText(
            self, "Speaker correction", "Original speaker label or Slack user ID"
        )
        if not ok or not original:
            return
        display, ok = QInputDialog.getText(
            self, "Speaker correction", "Display name (empty restores the original)"
        )
        if ok:
            ident = self.selected
            ask(
                self,
                "Speaker correction",
                lambda: self.core.set_transcript_speaker_alias(ident, original, display),
            )
            self.load_selected()

    def meeting_actions(self):
        if not self.selected:
            return
        ident = self.selected
        dialog = QDialog(self)
        dialog.setWindowTitle("Confirmed meeting actions")
        dialog.resize(680, 380)
        layout = QVBoxLayout(dialog)
        layout.addWidget(
            QLabel("Actions are entered by you and linked to a supporting transcript passage.")
        )
        items = QListWidget()
        layout.addWidget(items)

        def refresh():
            items.clear()
            for action in self.core.get_meeting_actions(ident):
                details = " · ".join(value for value in (action.owner, action.due_date) if value)
                item = QListWidgetItem(
                    f"{'Done' if action.completed else 'Open'} · {action.text}"
                    + (f" · {details}" if details else "")
                    + f"\nSource: {action.source_quote}"
                )
                item.setData(Qt.ItemDataRole.UserRole, action.id)
                items.addItem(item)

        def add():
            try:
                cues = self.core.get_imported_utterances(ident)
            except Exception:
                cues = self.core.get_transcription_segments(ident)
            choices = [f"{index}: {cue.text[:160]}" for index, cue in enumerate(cues)]
            if not choices:
                QMessageBox.information(
                    dialog, "No source", "This recording has no source utterances yet."
                )
                return
            choice, ok = QInputDialog.getItem(
                dialog, "Supporting passage", "Select the source utterance", choices, editable=False
            )
            if not ok:
                return
            text, ok = QInputDialog.getText(dialog, "Action", "Confirmed action")
            if not ok or not text.strip():
                return
            owner, ok = QInputDialog.getText(
                dialog, "Owner", "Owner (optional; leave empty if unknown)"
            )
            if not ok:
                return
            due, ok = QInputDialog.getText(
                dialog, "Due date", "YYYY-MM-DD (optional; leave empty if unknown)"
            )
            if ok:
                self.core.add_meeting_action(
                    ident, text, owner or None, due or None, choices.index(choice)
                )
                refresh()

        def complete():
            item = items.currentItem()
            if item:
                self.core.complete_meeting_action(ident, item.data(Qt.ItemDataRole.UserRole), True)
                refresh()

        row = QHBoxLayout()
        button("Add action…", lambda: ask(dialog, "Meeting action", add), row)
        button("Mark complete", lambda: ask(dialog, "Meeting action", complete), row)
        button("Close", dialog.accept, row)
        layout.addLayout(row)
        refresh()
        dialog.exec()

    def export(self):
        if not self.selected:
            return
        path, _ = QFileDialog.getSaveFileName(
            self,
            "Export transcript",
            "transcript.txt",
            "Text (*.txt);;Markdown (*.md);;SubRip (*.srt);;WebVTT (*.vtt)",
        )
        if path:
            text = self.transcript.toPlainText()
            if Path(path).suffix in (".srt", ".vtt"):
                text = subtitle_text(
                    self.core.get_transcription_segments(self.selected), path.endswith(".vtt")
                )
            if Path(path).suffix == ".md":
                from .meeting_notes import render_minutes

                try:
                    origin = self.core.get_transcript_origin(self.selected)
                    cues = self.core.get_imported_utterances(self.selected)
                    provider, source_id = origin.provider, origin.source_id
                except Exception:
                    cues = self.core.get_transcription_segments(self.selected)
                    provider, source_id = "local", self.selected
                row = self.core.get_transcription(self.selected)
                recognized = self.core.get_transcription_processing(self.selected).recognized_text
                text = render_minutes(
                    row.title or "Meeting",
                    provider,
                    source_id,
                    cues,
                    self.core.get_meeting_actions(self.selected),
                    row.text if row.text != recognized else None,
                )
            ask(self, "Export", lambda: Path(path).write_text(text, encoding="utf-8"))

    def seek_segment(self, item):
        self.player.setPosition(round(item.data(Qt.ItemDataRole.UserRole) * 1000))

    def load_video(self):
        if not self.selected:
            return
        job = next((job for job in self.core.list_import_jobs() if job.id == self.selected), None)
        if not job:
            return
        path = job.attachment.path
        if not Path(path).is_file():
            QMessageBox.information(
                self, "Missing media", "Locate the source in the Imports tab first."
            )
            return
        self.video.show()
        self.media_controls.show()
        self.player.setSource(QUrl.fromLocalFile(path))
        self.playback_track = job.attachment.audio_track

    def play_pause(self):
        if self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState:
            self.player.pause()
        else:
            self.player.play()

    def refresh_imports(self):
        selected = self.jobs.currentItem()
        selected = selected.data(Qt.ItemDataRole.UserRole) if selected else None
        self.jobs.clear()
        for job in self.core.list_import_jobs():
            item = QListWidgetItem(
                f"{job.title}\n\n{job.state.capitalize()}  ·  {job.processed_until:.0f} of {job.attachment.duration_secs:.0f} seconds"
                + (f"\n{job.message}" if job.message else "")
            )
            item.setData(Qt.ItemDataRole.UserRole, job.id)
            self.jobs.addItem(item)
            if selected == job.id:
                self.jobs.setCurrentItem(item)

    def current_job(self):
        item = self.jobs.currentItem()
        return self.core.get_import_job(item.data(Qt.ItemDataRole.UserRole)) if item else None

    def import_transcript(self):
        path, _ = QFileDialog.getOpenFileName(
            self,
            "Import Teams or Slack Huddle transcript",
            "",
            "Teams WebVTT (*.vtt);;Slack Huddle JSON (*.json)",
        )
        if not path:
            return

        def ingest():
            from .import_cli import read_transcript

            source = Path(path)
            provider = (
                self.backend.api.TranscriptProvider.SLACK
                if source.suffix.lower() == ".json"
                else self.backend.api.TranscriptProvider.TEAMS
            )
            return self.core.import_transcript(
                self.backend.api.TranscriptImportRequest(
                    provider=provider,
                    source_id=None,
                    title=source.stem,
                    content=read_transcript(source),
                )
            )

        self.task(ingest, "transcript_imported")

    def import_file(self):
        if self.importer:
            QMessageBox.information(
                self, "Import busy", "Pause the current import before starting another."
            )
            return
        path, _ = QFileDialog.getOpenFileName(self, "Import video or audio")
        if path:
            ask(self, "Import", lambda: self.create_import("file", path))

    def import_link(self):
        if self.importer:
            return
        value, ok = QInputDialog.getText(
            self, "Import link", "Finite YouTube video or direct HTTP(S) media URL"
        )
        if ok and value:
            from urllib.parse import urlparse

            url = urlparse(value)
            if url.scheme not in ("http", "https") or not url.hostname:
                QMessageBox.warning(self, "Import", "Enter a complete HTTP or HTTPS URL.")
                return
            kind = (
                "youtube"
                if url.hostname in ("youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be")
                else "direct"
            )
            ask(self, "Import", lambda: self.create_import(kind, value))

    def create_import(self, kind, value):
        job = self.core.create_import_job(
            kind, value, Path(value).name if kind == "file" else value, self.mode.currentText()
        )
        if kind == "file":
            _duration, tracks = probe(value)
            if len(tracks) > 1:
                options = [
                    f"{i}: {track.get('tags', {}).get('language', 'unknown')} ({track.get('codec_name', '')})"
                    for i, track in enumerate(tracks)
                ]
                choice, ok = QInputDialog.getItem(
                    self, "Audio track", "Transcribe which audio track?", options, editable=False
                )
                if not ok:
                    self.core.delete_transcription(job.id)
                    return
                job.attachment.audio_track = options.index(choice)
                self.core.attach_import_media(job.id, job.attachment)
        self.start_import(job)

    def start_import(self, job):
        browser = self.browser.currentText()
        self.browser.setCurrentIndex(0)
        self.importer = Importer(
            self.backend, job, self.events.message.emit, None if browser == "None" else browser
        )
        self.importer.start()
        self.refresh_imports()

    def pause_import(self):
        if self.importer:
            self.importer.pause()
            self.statusBar().showMessage("Pausing after the current chunk…")

    def resume_import(self):
        job = self.current_job()
        if job and not self.importer and job.state != "completed":
            self.start_import(job)

    def locate_source(self):
        job = self.current_job()
        if not job or self.importer:
            return
        path, _ = QFileDialog.getOpenFileName(self, "Locate the original source")
        if path:
            from .backend import fingerprint

            def locate():
                digest = fingerprint(path)
                if job.attachment.fingerprint and digest != job.attachment.fingerprint:
                    raise ValueError("The source changed. Start a new import.")
                job.attachment.path = path
                self.core.attach_import_media(job.id, job.attachment)

            ask(self, "Locate source", locate)

    def remove_media(self):
        job = self.current_job()
        if not job or self.importer:
            return
        directory = (self.backend.paths.data / "media" / job.id).resolve()
        path = Path(job.attachment.path).resolve()
        if not path.is_relative_to(directory) or not path.is_file():
            QMessageBox.information(
                self, "Media", "This source is an external file; it is not removed by Parakatt."
            )
            return
        if (
            QMessageBox.question(
                self, "Remove media", "Remove the downloaded video and retain its transcript?"
            )
            == QMessageBox.StandardButton.Yes
        ):
            path.unlink()

    def refresh_models(self):
        self.task(self.core.list_models, "models")

    def populate_models(self, models):
        self.models.clear()
        for model in models:
            item = QListWidgetItem(
                f"{model.display_name} — {'installed' if model.downloaded else 'not installed'} — {model.size_bytes / 1e9:.2f} GB"
            )
            item.setData(Qt.ItemDataRole.UserRole, model.id)
            self.models.addItem(item)

    def download_model(self):
        item = self.models.currentItem()
        if item:
            ask(
                self,
                "Download",
                lambda: self.core.start_download(item.data(Qt.ItemDataRole.UserRole)),
            )

    def delete_model(self):
        item = self.models.currentItem()
        if (
            item
            and not self.recording
            and not self.importer
            and QMessageBox.question(
                self, "Delete model", "Delete this model? You can download it again."
            )
            == QMessageBox.StandardButton.Yes
        ):
            ask(
                self,
                "Delete model",
                lambda: self.core.delete_model(item.data(Qt.ItemDataRole.UserRole)),
            )
            self.refresh_models()

    def database(self, restore):
        if self.recording or self.importer:
            QMessageBox.information(self, "Database", "Stop recording and pause imports first.")
            return
        if restore:
            path, _ = QFileDialog.getOpenFileName(self, "Restore database")
            if (
                path
                and QMessageBox.question(
                    self,
                    "Restore database",
                    "Replace the current transcript history with this backup?",
                )
                != QMessageBox.StandardButton.Yes
            ):
                return
        else:
            path, _ = QFileDialog.getSaveFileName(self, "Export database", "parakatt-backup.db")
        if path:
            self.task(
                lambda: (self.core.import_database if restore else self.core.export_database)(path),
                "refresh",
            )

    def save_profile(self):
        name, ok = QInputDialog.getText(self, "Save profile", "Profile name")
        if ok and name:
            ask(self, "Profile", lambda: self.core.save_profile(name))

    def profile_choice(self):
        return QInputDialog.getItem(
            self, "Profile", "Select profile", self.core.list_profiles(), editable=False
        )

    def load_profile(self):
        if self.recording or self.importer:
            return
        name, ok = self.profile_choice()
        if ok and name:

            def load():
                self.core.load_profile(name)
                self.backend.restore_credentials()
                self.refresh_modes()

            ask(self, "Profile", load)

    def delete_profile(self):
        name, ok = self.profile_choice()
        if ok and name:
            ask(self, "Profile", lambda: self.core.delete_profile(name))

    def refresh_recovery(self):
        self.drafts.clear()
        for draft in self.core.list_recording_drafts():
            item = QListWidgetItem(
                f"{draft.created_at} · {draft.source} · {draft.chunk_count} chunks · {draft.recognized_text[:80]}"
            )
            item.setData(Qt.ItemDataRole.UserRole, draft.id)
            self.drafts.addItem(item)

    def recover(self, audio):
        item = self.drafts.currentItem()
        if item:
            ident = item.data(Qt.ItemDataRole.UserRole)
            self.task(lambda: self.core.recover_recording(ident, audio), "refresh")

    def discard_draft(self):
        item = self.drafts.currentItem()
        if (
            item
            and QMessageBox.question(
                self, "Discard draft", "Permanently discard this interrupted recording?"
            )
            == QMessageBox.StandardButton.Yes
        ):
            ident = item.data(Qt.ItemDataRole.UserRole)
            ask(self, "Discard draft", lambda: self.core.discard_recording_draft(ident))
            self.refresh_recovery()

    def closeEvent(self, event):
        if self.quitting:
            event.accept()
        elif self.tray.isVisible():
            self.hide()
            event.ignore()
        else:
            event.ignore()
            self.quit()

    def quit(self):
        self.quitting = True
        self.centralWidget().setEnabled(False)
        if self.recording:
            self.recording.stop()
        if self.importer:
            self.importer.pause()
        self.core.cancel_download()
        self.statusBar().showMessage("Finishing active work before closing…")
        self.finish_quit()

    def finish_quit(self):
        if not self.recording and not self.importer and not self.pool.activeThreadCount():
            self.player.stop()
            QApplication.quit()


def main():
    parser = argparse.ArgumentParser(description="Parakatt Linux desktop")
    parser.add_argument(
        "--toggle", action="store_true", help="Toggle dictation in the running desktop app"
    )
    parser.add_argument("--meeting", action="store_true", help="Toggle meeting capture")
    parser.add_argument("--models-dir", type=Path)
    parser.add_argument(
        "--data-dir", type=Path, help="Use isolated application data (testing / portable use)"
    )
    parser.add_argument("--diagnostics", action="store_true")
    args = parser.parse_args()
    if args.diagnostics:
        print(json.dumps(diagnostics(), indent=2))
        return
    app = QApplication(sys.argv[:1])
    app.setApplicationName("Parakatt")
    app.setOrganizationName("Parakatt")
    app.setQuitOnLastWindowClosed(False)
    paths = Paths.discover(args.models_dir, args.data_dir)
    # One instance per data directory. Never unlink a live instance's socket.
    import hashlib

    ident = hashlib.sha256(str(paths.config.resolve()).encode()).hexdigest()[:16]
    name = f"parakatt-{os.getuid()}-{ident}"
    client = QLocalSocket()
    client.connectToServer(name)
    if client.waitForConnected(500):
        client.write(b"meeting" if args.meeting else b"toggle" if args.toggle else b"show")
        client.waitForBytesWritten(1000)
        client.disconnectFromServer()
        return
    QLocalServer.removeServer(name)
    server = QLocalServer()
    server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
    if not server.listen(name):
        raise RuntimeError(server.errorString())
    try:
        backend = Backend(paths)
        window = Window(backend)
    except Exception as error:
        QMessageBox.critical(None, "Parakatt startup", str(error))
        return 1

    def connection():
        socket = server.nextPendingConnection()

        def receive():
            message = bytes(socket.readAll())
            if message == b"toggle":
                window.toggle_recording()
            elif message == b"meeting":
                window.toggle_recording(True)
            elif message == b"show":
                window.show_window()
            socket.disconnectFromServer()

        socket.readyRead.connect(receive)
        socket.disconnected.connect(socket.deleteLater)
        if socket.bytesAvailable():
            receive()

    server.newConnection.connect(connection)
    window.show()
    if args.toggle or args.meeting:
        QTimer.singleShot(0, lambda: window.toggle_recording(args.meeting))
    result = app.exec()
    server.close()
    return result


if __name__ == "__main__":
    sys.exit(main())
