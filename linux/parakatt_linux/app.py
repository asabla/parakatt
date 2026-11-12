"""Qt desktop UI for the shared Parakatt engine."""

import argparse
import contextlib
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, QTimer, QUrl, Signal
from PySide6.QtGui import (
    QAction,
    QColor,
    QIcon,
    QKeySequence,
    QShortcut,
    QTextCursor,
    QTextDocument,
)
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtWidgets import (
    QAbstractItemView,
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QFileDialog,
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
    QSlider,
    QSplitter,
    QStackedWidget,
    QSystemTrayIcon,
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
    diagnostics,
    probe,
    subtitle_text,
)
from .desktop_widgets import (
    ROW_DATA,
    HistoryDelegate,
    RecordingOverlay,
    RecordingWindow,
    SegmentedControl,
    TimelineDelegate,
    add_segment,
    ask,
    button,
    duration,
    empty_state,
    icon,
    source_label,
)
from .settings import Settings


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
        self.setWindowTitle("Transcription History")
        self.resize(1240, 820)
        self.setMinimumSize(850, 570)
        self.setWindowIcon(QIcon(str(Path(__file__).parent / "assets" / "appicon.png")))
        self.mode = QComboBox(self)
        self.mode.hide()
        self.refresh_modes()
        self.mode.currentTextChanged.connect(
            lambda name: ask(self, "Mode", lambda: self.core.set_active_mode(name))
        )
        self.panels = {}
        self.panel_windows = {}
        self.tabs = QTabWidget()
        self.tabs.tabBar().hide()
        self.setCentralWidget(self.tabs)
        self.setup_live()
        self.setup_history()
        self.setup_imports()
        self.setup_models()
        self.setup_tools()
        file_menu = self.menuBar().addMenu("Parakatt")
        self.record_button = file_menu.addAction("Record voice note", self.toggle_recording)
        self.meeting_button = file_menu.addAction(
            "Start meeting", lambda: self.toggle_recording(True)
        )
        file_menu.addSeparator()
        self.settings_button = file_menu.addAction("Settings…", self.settings)
        self.settings_button.setShortcut(QKeySequence("Ctrl+,"))
        file_menu.addAction("Imports…", lambda: self.open_panel("imports"))
        file_menu.addAction("Tools & recovery…", lambda: self.open_panel("tools"))
        file_menu.addSeparator()
        file_menu.addAction("Quit", self.quit, QKeySequence("Ctrl+Q"))
        imports_menu = self.menuBar().addMenu("Import")
        imports_menu.addAction("Video or audio…", self.import_file)
        imports_menu.addAction("Link…", self.import_link)
        imports_menu.addAction("Teams / Slack transcript…", self.import_transcript)
        self.find_shortcut = QShortcut(QKeySequence("Ctrl+F"), self)
        self.find_shortcut.activated.connect(self.focus_find)
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

    def open_panel(self, name, owner=None):
        page = self.panels[name]
        if owner:
            dialog = QDialog(owner)
            dialog.setWindowTitle(
                {"models": "Speech Models", "imports": "Imports", "tools": "Tools & Recovery"}[name]
            )
            dialog.resize(820, 580)
            layout = QVBoxLayout(dialog)
            layout.addWidget(page)
            page.show()
            dialog.exec()
            page.setParent(self)
            page.hide()
            return
        dialog = self.panel_windows.get(name)
        if dialog is None:
            dialog = QDialog(self, Qt.WindowType.Window)
            dialog.setWindowTitle(
                {"models": "Speech Models", "imports": "Imports", "tools": "Tools & Recovery"}[name]
            )
            dialog.resize(820, 580)
            layout = QVBoxLayout(dialog)
            layout.addWidget(page)
            self.panel_windows[name] = dialog
        elif dialog.layout().indexOf(page) < 0:
            dialog.layout().addWidget(page)
        page.show()
        dialog.show()
        dialog.raise_()
        dialog.activateWindow()

    def setup_live(self):
        self.live_window = RecordingWindow(self)
        self.live_window.stop_requested.connect(self.toggle_recording)
        self.live_window.pause_requested.connect(self.pause_recording)
        self.live_window.discard_requested.connect(self.discard_recording)
        self.live_text = self.live_window.text
        self.live_status = self.live_window.status
        self.preview_text = self.live_window.preview
        self.overlay = RecordingOverlay(self)
        self.overlay.stop_requested.connect(self.toggle_recording)
        self.overlay.open_requested.connect(self.live_window.show)
        self.recording_timer = QTimer(self)
        self.recording_timer.setInterval(200)
        self.recording_timer.timeout.connect(self.update_recording_clock)

    def setup_history(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        toolbar = QFrame()
        toolbar.setObjectName("toolbar")
        row = QHBoxLayout(toolbar)
        row.setContentsMargins(14, 12, 18, 12)
        row.setSpacing(12)
        self.sidebar_toggle = button("", self.toggle_sidebar, row)
        self.sidebar_toggle.setIcon(icon("sidebar"))
        self.sidebar_toggle.setAccessibleName("Show or hide transcript sidebar")
        self.sidebar_toggle.setToolTip("Show or hide transcript sidebar")
        self.sidebar_toggle.setProperty("role", "quiet")
        self.search = QLineEdit()
        self.search.setObjectName("historySearch")
        self.search.setPlaceholderText("Search transcriptions")
        self.search.addAction(icon("search"), QLineEdit.ActionPosition.LeadingPosition)
        self.search.setClearButtonEnabled(True)
        self.search.setMaximumWidth(420)
        self.search_timer = QTimer(self)
        self.search_timer.setSingleShot(True)
        self.search_timer.setInterval(250)
        self.search_timer.timeout.connect(self.refresh_history)
        self.search.textChanged.connect(lambda: self.search_timer.start())
        self.search.returnPressed.connect(self.refresh_history)
        row.addWidget(self.search, 1)
        row.addStretch()
        button("Import Video…", self.import_file, row)
        button("Import Link…", self.import_link, row)
        more = button("…", lambda: None, row)
        more.setAccessibleName("Additional imports and recording controls")
        more.setProperty("role", "quiet")
        menu = QMenu(more)
        menu.addAction("Import Teams / Slack transcript…", self.import_transcript)
        menu.addAction("Manage imports…", lambda: self.open_panel("imports"))
        menu.addSeparator()
        menu.addAction("Record voice note", self.toggle_recording)
        menu.addAction("Start meeting", lambda: self.toggle_recording(True))
        menu.addSeparator()
        menu.addAction("Settings…", self.settings)
        more.setMenu(menu)
        layout.addWidget(toolbar)
        self.splitter = splitter = QSplitter()
        splitter.setHandleWidth(1)
        self.history_pane = QWidget()
        self.history_pane.setObjectName("historyPane")
        side = QVBoxLayout(self.history_pane)
        side.setContentsMargins(0, 0, 0, 0)
        side.setSpacing(0)
        filters = QFrame()
        filters.setObjectName("filterBar")
        bar = QHBoxLayout(filters)
        bar.setContentsMargins(10, 9, 10, 9)
        self.filters = SegmentedControl(["All", "Notes", "Meetings", "Videos"])
        self.filters.changed.connect(self.refresh_history)
        bar.addWidget(self.filters, 1)
        self.selection_button = button("", self.toggle_selection, bar)
        self.selection_button.setIcon(icon("check"))
        self.selection_button.setAccessibleName("Select multiple transcriptions")
        self.selection_button.setToolTip("Select multiple transcriptions")
        self.selection_button.setProperty("role", "quiet")
        self.selection_button.setCheckable(True)
        side.addWidget(filters)
        self.history = QListWidget()
        self.history.setObjectName("recordings")
        self.history.setItemDelegate(HistoryDelegate(self.history))
        self.history.setMouseTracking(True)
        self.history.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.history.setMinimumWidth(275)
        self.history.currentItemChanged.connect(self.select_history)
        side.addWidget(self.history, 1)
        self.history_empty = ui_label(
            "No transcriptions yet.\nRecord a note or import a conversation."
        )
        self.history_empty.setWordWrap(True)
        self.history_empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.history_empty.setContentsMargins(20, 20, 20, 20)
        side.addWidget(self.history_empty)
        self.history_empty.hide()

        footer = QHBoxLayout()
        footer.setContentsMargins(10, 5, 10, 7)
        self.more_button = button("Load more", self.more_history, footer)
        self.more_button.setProperty("role", "quiet")
        footer.addStretch()
        self.delete_selected = button("Delete selected…", self.delete_selection, footer)
        self.delete_selected.hide()
        side.addLayout(footer)
        splitter.addWidget(self.history_pane)
        self.detail_stack = QStackedWidget()
        self.detail_stack.addWidget(
            empty_state(
                "Select a transcription", "Choose an item from the sidebar to view its full text."
            )
        )
        detail = QWidget()
        content = QVBoxLayout(detail)
        content.setContentsMargins(0, 0, 0, 0)
        content.setSpacing(0)
        header = QFrame()
        header.setObjectName("detailHeader")
        head = QVBoxLayout(header)
        head.setContentsMargins(24, 22, 24, 20)
        head.setSpacing(12)
        row = QHBoxLayout()
        self.title = QLineEdit()
        self.title.setObjectName("recordingTitle")
        self.title.setReadOnly(True)
        row.addWidget(self.title, 1)
        edit = button("", self.edit_transcript, row)
        edit.setIcon(icon("edit"))
        edit.setProperty("role", "quiet")
        edit.setAccessibleName("Edit title and processed text")
        edit.setToolTip("Edit title and processed text")
        head.addLayout(row)
        self.recording_meta = ui_label("")
        self.recording_meta.setWordWrap(True)
        head.addWidget(self.recording_meta)
        row = QHBoxLayout()
        copy = button("Copy", self.copy_transcript, row)
        copy.setIcon(icon("copy"))
        export = button("Export…", self.export, row)
        export.setMinimumWidth(130)
        more = button("…", lambda: None, row)
        more.setAccessibleName("Transcript actions")
        more.setMinimumWidth(70)
        menu = QMenu(more)
        self.original = QCheckBox("Original recognized text", self)
        self.original.hide()
        original_action = menu.addAction("Original recognized text")
        original_action.setCheckable(True)
        original_action.toggled.connect(self.original.setChecked)
        self.original.toggled.connect(self.load_selected)
        for title, callback in [
            ("Edit title and processed text", self.edit_transcript),
            ("Meeting actions…", self.meeting_actions),
            ("Correct speaker name…", self.correct_speaker),
            ("Undo last edit", lambda: self.history_action(self.core.undo_transcription_edit)),
            (
                "Retry LLM processing",
                lambda: self.history_action(self.core.retry_history_processing),
            ),
        ]:
            menu.addAction(title, callback)
        more.setMenu(menu)
        self.open_media = button("Open video", self.load_video, row)
        self.open_media.hide()
        row.addStretch()
        delete = button("Delete", self.delete_history, row)
        delete.setIcon(icon("trash"))
        head.addLayout(row)
        self.edit_bar = QWidget()
        edit_row = QHBoxLayout(self.edit_bar)
        edit_row.setContentsMargins(0, 0, 0, 0)
        edit_row.addWidget(ui_label("Editing processed text"))
        edit_row.addStretch()
        button("Cancel", self.load_selected, edit_row)
        button("Save changes", self.save_edit, edit_row).setProperty("role", "primary")
        head.addWidget(self.edit_bar)
        self.edit_bar.hide()
        content.addWidget(header)
        viewbar = QFrame()
        viewbar.setObjectName("toolbar")
        view_layout = QHBoxLayout(viewbar)
        view_layout.setContentsMargins(24, 14, 24, 14)
        self.history_view = SegmentedControl(["Processed text", "Recognized timeline"])
        self.history_view.setMaximumWidth(470)
        self.history_view.changed.connect(self.change_transcript_view)
        view_layout.addWidget(self.history_view, 1)
        view_layout.addStretch()
        content.addWidget(viewbar)
        body = QWidget()
        body.setObjectName("transcriptBody")
        body_layout = QVBoxLayout(body)
        body_layout.setContentsMargins(24, 12, 24, 18)
        body_layout.setSpacing(22)
        find_row = QHBoxLayout()
        self.find = QLineEdit()
        self.find.setPlaceholderText("Find in transcript")
        self.find.setClearButtonEnabled(True)
        self.find.textChanged.connect(self.find_in_transcript)
        self.find.returnPressed.connect(lambda: self.next_match(1))
        find_row.addWidget(self.find, 1)
        self.match_count = ui_label("0 matches")
        find_row.addWidget(self.match_count)
        self.previous_match = button("⌃", lambda: self.next_match(-1), find_row)
        self.next_match_button = button("⌄", lambda: self.next_match(1), find_row)
        self.previous_match.setAccessibleName("Previous match")
        self.next_match_button.setAccessibleName("Next match")
        body_layout.addLayout(find_row)
        self.transcript_stack = QStackedWidget()
        self.transcript = QTextEdit()
        self.transcript.setObjectName("transcript")
        self.transcript.setReadOnly(True)
        self.transcript.document().setDocumentMargin(0)
        self.transcript.textChanged.connect(self.find_in_transcript)
        self.transcript_stack.addWidget(self.transcript)
        self.segments = QListWidget()
        self.segments.setObjectName("timeline")
        self.segments.setItemDelegate(TimelineDelegate(self.segments))
        self.segments.setWordWrap(True)
        self.segments.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.segments.itemActivated.connect(self.seek_segment)
        self.transcript_stack.addWidget(self.segments)
        body_layout.addWidget(self.transcript_stack, 1)
        content.addWidget(body, 1)
        self.find_matches = []
        self.match_index = -1
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
        self.detail_stack.addWidget(detail)
        splitter.addWidget(self.detail_stack)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([420, 820])
        layout.addWidget(splitter, 1)
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
        hero_layout.addWidget(ui_label("IMPORT MEDIA & TRANSCRIPTS", "eyebrow"))
        hero_layout.addWidget(ui_label("Imports", "heading"))
        note = ui_label("Import audio, video, links, Teams meetings, or Slack Huddle transcripts.")
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
        row.addWidget(ui_label("IMPORT QUEUE", "eyebrow"))
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
        layout.addWidget(ui_label("Pausing retains completed chunks so you can resume later."))
        self.panels["imports"] = page
        page.setParent(self)
        page.hide()

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
        self.panels["models"] = page
        page.setParent(self)
        page.hide()

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
        self.panels["tools"] = page
        page.setParent(self)
        page.hide()

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
            self.live_window.state.setText("Finishing…")
            self.live_window.pause.setEnabled(False)
            self.live_window.stop.setEnabled(False)
            self.live_window.discard.setEnabled(False)
            self.overlay.state.setText("Finishing…")
            self.overlay.stop.setEnabled(False)
            return
        self.recording = Recording(
            self.backend, meeting, self.mode.currentText(), self.events.message.emit
        )
        self.record_button.setText("Stop recording")
        self.meeting_button.setText("Stop recording")
        self.settings_button.setEnabled(False)
        self.mode.setEnabled(False)
        self.live_window.reset(meeting)
        self.live_window.mode_name = self.mode.currentText().capitalize()
        self.live_status.setText("Loading speech model…")
        self.overlay.state.setText("Preparing…")
        self.overlay.model.setText("Loading speech model…")
        self.overlay.stop.setEnabled(True)
        self.overlay.meter.set_level(0)
        device = self.backend.preferences.get("microphone") or "System default microphone"
        self.overlay.device.setText(device if len(device) < 32 else device[:29] + "…")
        self.overlay.device.setToolTip(device)
        if meeting or not self.core.get_show_overlay():
            self.live_window.show()
            self.live_window.raise_()
        if self.core.get_show_overlay():
            screen = self.screen().availableGeometry()
            self.overlay.move(screen.center().x() - self.overlay.width() // 2, screen.y() + 24)
            self.overlay.show()
        self.recording_timer.start()
        self.recording.start()

    def pause_recording(self):
        if (
            not self.recording
            or not self.recording.ready.is_set()
            or self.recording.stop_event.is_set()
        ):
            return
        paused = not self.recording.pause_event.is_set()
        self.recording.set_paused(paused)
        self.live_window.paused = paused
        self.live_window.pause.setText("▶  Resume" if paused else "Ⅱ  Pause")
        self.preview_text.clear()
        self.overlay.meter.set_level(0)
        self.update_recording_clock()

    def discard_recording(self):
        if not self.recording:
            return
        if (
            QMessageBox.question(
                self.live_window,
                "Discard recording",
                "Discard this recording and its recovery audio?",
            )
            == QMessageBox.StandardButton.Yes
        ):
            self.recording.discard()
            self.live_window.state.setText("Discarding…")
            self.live_window.pause.setEnabled(False)
            self.live_window.stop.setEnabled(False)
            self.live_window.discard.setEnabled(False)
            self.overlay.hide()

    def update_recording_clock(self):
        if not self.recording or self.recording.stop_event.is_set():
            return
        ready = self.recording.ready.is_set()
        self.live_window.update_clock(
            self.recording.elapsed_seconds(), self.core.get_chunk_duration(), ready
        )
        if ready:
            self.overlay.state.setText(
                "Paused" if self.recording.pause_event.is_set() else "Recording"
            )
            self.overlay.model.setText("Transcription model ready")

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
            self.live_window.update_view()
            self.preview_text.clear()
        elif kind == "audio_level":
            if self.recording and not self.recording.pause_event.is_set():
                self.overlay.meter.set_level(value)
        elif kind == "live_segments":
            for segment in value.segments:
                text = (segment.speaker + ": " if segment.speaker else "") + segment.text
                add_segment(
                    self.live_window.timeline, segment.start_secs + value.chunk_offset_secs, text
                )
            self.live_window.update_view()
        elif kind == "preview":
            self.preview_text.setText("Microphone preview: " + value)
            self.preview_text.show()
        elif kind == "recorded":
            self.live_text.setPlainText(value.text)
            self.live_window.update_view()
            self.selected = self.recording.id if self.recording else None
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
            self.recording_timer.stop()
            self.overlay.hide()
            self.live_window.active = False
            self.live_window.state.setText("Recording complete")
            self.live_window.pause.setEnabled(False)
            self.live_window.stop.setEnabled(False)
            self.live_window.discard.setEnabled(False)
            self.live_window.hide()
            self.record_button.setText("Record voice note")
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
        elif kind == "edit_saved":
            self.edit_bar.hide()
            self.title.setReadOnly(True)
            self.transcript.setReadOnly(True)
            self.refresh_history()
            self.statusBar().showMessage("Changes saved")
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
            self.tabs.setCurrentIndex(0)
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

    def toggle_sidebar(self):
        self.history_pane.setVisible(self.history_pane.isHidden())

    def toggle_selection(self):
        selecting = self.selection_button.isChecked()
        self.history.setSelectionMode(
            QAbstractItemView.SelectionMode.ExtendedSelection
            if selecting
            else QAbstractItemView.SelectionMode.SingleSelection
        )
        self.delete_selected.setVisible(selecting)

    def delete_selection(self):
        ids = [item.data(Qt.ItemDataRole.UserRole) for item in self.history.selectedItems()]
        if not ids:
            return
        if self.importer and self.importer.job.id in ids:
            QMessageBox.information(
                self, "Import active", "Pause the import before deleting its transcript."
            )
            return
        if (
            QMessageBox.question(
                self,
                "Delete transcriptions",
                f"Delete {len(ids)} selected transcriptions? External media files will remain.",
            )
            == QMessageBox.StandardButton.Yes
        ):
            self.task(lambda: self.core.delete_transcriptions(ids), "refresh")

    def refresh_history(self):
        self.search_timer.stop()
        self.history_offset = 0
        self.history_generation += 1
        generation = self.history_generation
        query = self.search.text()
        category = self.filters.buttons[self.filters.currentIndex()].text()
        self.task(
            lambda: (generation, 0, self.backend.history(query, category=category)), "history"
        )

    def more_history(self):
        self.more_button.setEnabled(False)
        self.history_offset += 100
        query, offset = self.search.text(), self.history_offset
        category = self.filters.buttons[self.filters.currentIndex()].text()
        generation = self.history_generation
        self.task(
            lambda: (generation, offset, self.backend.history(query, offset, category)), "history"
        )

    def populate_history(self, rows, offset=0):
        selected = self.selected
        self.history.blockSignals(True)
        if offset == 0:
            self.history.clear()
        selected_item = None
        for row in rows:
            item = QListWidgetItem(row.title or row.text[:60] or "Untitled")
            item.setData(Qt.ItemDataRole.UserRole, row.id)
            item.setData(ROW_DATA, row)
            item.setToolTip(row.title or "Untitled")
            self.history.addItem(item)
            if row.id == selected:
                selected_item = item
        if selected_item:
            self.history.setCurrentItem(selected_item)
        self.history.blockSignals(False)
        if offset == 0:
            if selected_item:
                self.selected = selected
                if self.edit_bar.isHidden():
                    self.load_selected()
            else:
                self.select_history(None, None)
        self.more_button.setEnabled(len(rows) == 100)
        self.history_empty.setVisible(self.history.count() == 0)
        self.history_empty.setText(
            "No matching transcriptions.\nTry another search or category."
            if self.search.text() or self.filters.currentIndex()
            else "No transcriptions yet.\nRecord a note or import a conversation."
        )

    def select_history(self, item, _previous):
        self.player.stop()
        self.player.setSource(QUrl())
        self.video.hide()
        self.media_controls.hide()
        self.selected = item.data(Qt.ItemDataRole.UserRole) if item else None
        self.load_selected()

    def load_selected(self):
        self.history_view.buttons[0].setText(
            "Original text" if self.original.isChecked() else "Processed text"
        )
        self.detail_stack.setCurrentIndex(1 if self.selected else 0)
        self.edit_bar.hide()
        self.title.setReadOnly(True)
        self.transcript.setReadOnly(True)
        if not self.selected:
            self.title.clear()
            self.transcript.clear()
            self.segments.clear()
            return
        row = self.core.get_transcription(self.selected)
        self.title.setText(row.title or "Untitled")
        date = datetime.fromisoformat(row.created_at.replace("Z", "+00:00")).astimezone()
        self.recording_meta.setText(
            f"{source_label(row)}    ·    {date:%d %b %Y at %H:%M}    ·    {duration(row.duration_secs)}    ·    {row.mode.capitalize()}"
        )
        self.open_media.setVisible(
            any(job.id == self.selected for job in self.core.list_import_jobs())
        )
        text = (
            self.core.get_transcription_processing(self.selected).recognized_text
            if self.original.isChecked()
            else row.text
        )
        cues = []
        # Audio recordings have no imported-utterance record.
        with contextlib.suppress(Exception):
            cues = self.core.get_imported_utterances(self.selected)
        if (
            not self.original.isChecked()
            and cues
            and text == self.core.get_transcription_processing(self.selected).recognized_text
        ):
            text = "\n\n".join(
                (f"{cue.speaker}: " if cue.speaker else "") + cue.text for cue in cues
            )
        self.transcript.setPlainText(text)
        self.segments.clear()
        # Preserve corrected imported names without changing the stored source text.
        segments = cues if cues else self.core.get_transcription_segments(self.selected)
        for segment in segments:
            text = (segment.speaker + ": " if segment.speaker else "") + segment.text
            if segment.start_secs is not None:
                add_segment(self.segments, segment.start_secs, text)
        if not self.segments.count():
            item = QListWidgetItem("No timed segments are available for this transcription.")
            item.setFlags(Qt.ItemFlag.NoItemFlags)
            self.segments.addItem(item)
        self.find_in_transcript()

    def edit_transcript(self):
        if self.selected and not self.original.isChecked():
            self.history_view.setCurrentIndex(0)
            self.title.setReadOnly(False)
            self.transcript.setReadOnly(False)
            self.edit_bar.show()
            self.title.setFocus()
        elif self.selected:
            self.statusBar().showMessage(
                "Switch off Original recognized text in the transcript menu to edit processed text."
            )

    def copy_transcript(self):
        if self.history_view.currentIndex():
            text = "\n".join(
                self.segments.item(i).data(ROW_DATA) or "" for i in range(self.segments.count())
            )
        else:
            text = self.transcript.toPlainText()
        QApplication.clipboard().setText(text)

    def change_transcript_view(self, index):
        self.transcript_stack.setCurrentIndex(index)
        self.find_in_transcript()

    def focus_find(self):
        target = self.find if self.selected else self.search
        target.setFocus()
        target.selectAll()

    def find_in_transcript(self):
        if not hasattr(self, "segments"):
            return
        query = self.find.text()
        self.find_matches = []
        selections = []
        if query:
            if self.history_view.currentIndex():
                for index in range(self.segments.count()):
                    text = self.segments.item(index).data(ROW_DATA) or ""
                    if query.casefold() in text.casefold():
                        self.find_matches.append(index)
            else:
                cursor = QTextCursor(self.transcript.document())
                while True:
                    cursor = self.transcript.document().find(
                        query, cursor, QTextDocument.FindFlag(0)
                    )
                    if cursor.isNull():
                        break
                    self.find_matches.append(QTextCursor(cursor))
                    selection = QTextEdit.ExtraSelection()
                    selection.cursor = QTextCursor(cursor)
                    selection.format.setBackground(QColor("#70571d"))
                    selection.format.setForeground(QColor("#ffffff"))
                    selections.append(selection)
        self.transcript.setExtraSelections(selections)
        self.match_index = -1
        self.match_count.setText(f"{len(self.find_matches)} matches")
        self.previous_match.setEnabled(bool(self.find_matches))
        self.next_match_button.setEnabled(bool(self.find_matches))

    def next_match(self, direction):
        if not self.find_matches:
            return
        if self.match_index < 0:
            self.match_index = 0 if direction > 0 else len(self.find_matches) - 1
        else:
            self.match_index = (self.match_index + direction) % len(self.find_matches)
        match = self.find_matches[self.match_index]
        if self.history_view.currentIndex():
            self.segments.setCurrentRow(match)
            self.segments.scrollToItem(self.segments.item(match))
        else:
            self.transcript.setTextCursor(match)
            self.transcript.ensureCursorVisible()
        self.match_count.setText(f"{self.match_index + 1} of {len(self.find_matches)}")

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

            self.task(save, "edit_saved")

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
                self, "Missing media", "Locate the source in Import → Manage imports first."
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
