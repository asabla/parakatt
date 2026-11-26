"""Desktop transcript sources, account setup and explicit preview/confirmation."""

from __future__ import annotations

import threading
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING, Literal, override

from PySide6.QtCore import (
    QAbstractTableModel,
    QModelIndex,
    QObject,
    QPersistentModelIndex,
    QRunnable,
    Qt,
    QUrl,
    Signal,
)
from PySide6.QtGui import QCloseEvent, QDesktopServices
from PySide6.QtWidgets import (
    QAbstractItemView,
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QSplitter,
    QStackedWidget,
    QTableView,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from .appearance import label
from .authentication import Account, DevicePrompt
from .backend import Backend
from .connections import Connection, load_connections, save_connections
from .desktop_widgets import SegmentedControl, button, empty_state, timestamp
from .providers import MeetingSource, SlackIdentity, TranscriptSource
from .settings import scroll_page
from .transcript_service import CommittedTranscript, PreparedTranscript, TranscriptService

if TYPE_CHECKING:
    from .app import Window

type Provider = Literal["teams", "slack"]
type ImportResult = (
    tuple[Literal["prepared"], PreparedTranscript]
    | tuple[Literal["accounts"], list[Account]]
    | tuple[Literal["teams_sources"], tuple[MeetingSource, list[TranscriptSource]]]
    | tuple[Literal["slack_sources"], list[TranscriptSource]]
    | tuple[Literal["slack_connected"], tuple[SlackIdentity, str, bool, str | None]]
    | tuple[Literal["disconnected"], str]
    | tuple[Literal["committed"], CommittedTranscript]
)
type ImportMessage = (
    ImportResult | tuple[Literal["device_prompt"], DevicePrompt] | tuple[Literal["error"], str]
)


class ImportSignals(QObject):
    message = Signal(int, object)

    def send(self, generation: int, message: ImportMessage) -> None:
        self.message.emit(generation, message)


class ImportTask(QRunnable):
    def __init__(
        self, generation: int, function: Callable[[], ImportResult], signals: ImportSignals
    ) -> None:
        super().__init__()
        self.generation, self.function, self.signals = generation, function, signals

    @override
    def run(self) -> None:
        try:
            result = self.function()
        except Exception as error:
            self.signals.send(self.generation, ("error", str(error)))
        else:
            self.signals.send(self.generation, result)


class UtteranceModel(QAbstractTableModel):
    def __init__(self, preview: PreparedTranscript, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.preview = preview

    @override
    def rowCount(self, parent: QModelIndex | QPersistentModelIndex | None = None) -> int:
        return 0 if parent is not None and parent.isValid() else len(self.preview.utterances)

    @override
    def columnCount(self, parent: QModelIndex | QPersistentModelIndex | None = None) -> int:
        return 0 if parent is not None and parent.isValid() else 3

    @override
    def headerData(
        self, section: int, orientation: Qt.Orientation, role: int = Qt.ItemDataRole.DisplayRole
    ) -> str | None:
        columns = ("Time", "Speaker", "Transcript")
        if (
            role == Qt.ItemDataRole.DisplayRole
            and orientation == Qt.Orientation.Horizontal
            and 0 <= section < len(columns)
        ):
            return columns[section]
        return None

    @override
    def data(
        self, index: QModelIndex | QPersistentModelIndex, role: int = Qt.ItemDataRole.DisplayRole
    ) -> str | None:
        if not index.isValid() or role not in (
            Qt.ItemDataRole.DisplayRole,
            Qt.ItemDataRole.ToolTipRole,
        ):
            return None
        cue = self.preview.utterances[index.row()]
        if role == Qt.ItemDataRole.ToolTipRole:
            return cue.text if index.column() == 2 else cue.speaker
        return [
            timestamp(cue.start_secs) if cue.start_secs is not None else "Untimed",
            self.preview.speaker_names.get(cue.speaker, cue.speaker)
            if cue.speaker
            else "Unlabeled",
            cue.text,
        ][index.column()]


class ConnectionDialog(QDialog):
    def __init__(
        self, provider: Provider, parent: QWidget, existing: Connection | None = None
    ) -> None:
        super().__init__(parent)
        self.provider = provider
        self.setWindowTitle("Teams connection" if provider == "teams" else "Slack connection")
        self.resize(540, 360)
        layout = QVBoxLayout(self)
        layout.addWidget(
            label("Connect Teams" if provider == "teams" else "Connect Slack", "heading")
        )
        form = QFormLayout()
        self.label = QLineEdit(existing.label if existing else "")
        self.label.setPlaceholderText("e.g. Work")
        form.addRow("Connection name", self.label)
        self.client = QLineEdit(existing.client_id if existing else "")
        self.tenant = QLineEdit(existing.tenant if existing else "organizations")
        self.token = QLineEdit()
        self.token.setEchoMode(QLineEdit.EchoMode.Password)
        self.option = QCheckBox(
            "Allow meeting-link lookup (OnlineMeetings.Read)"
            if provider == "teams"
            else "Resolve participant names (users:read)"
        )
        self.option.setChecked(
            (existing.meeting_links if provider == "teams" else existing.resolve_names)
            if existing
            else False
        )
        if provider == "teams":
            form.addRow("Application ID", self.client)
            form.addRow("Tenant ID / domain", self.tenant)
        else:
            form.addRow("App token", self.token)
        layout.addLayout(form)
        layout.addWidget(self.option)
        permissions = label(
            "Requires an Entra public-client application approved for OnlineMeetingTranscript.Read.All. Link lookup adds read-only meeting metadata access. No calendar, chat or message permissions are requested."
            if provider == "teams"
            else "Use an administrator-approved Slack app token with files:read. Optional name lookup also needs users:read. Tokens are stored in the desktop keyring; Parakatt does not send messages."
        )
        permissions.setWordWrap(True)
        layout.addWidget(permissions)
        layout.addStretch()
        actions = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        actions.accepted.connect(self.validate)
        actions.rejected.connect(self.reject)
        layout.addWidget(actions)

    def validate(self) -> None:
        if not self.label.text().strip():
            QMessageBox.information(self, "Connection name", "Enter a name for this connection.")
            return
        if self.provider == "teams" and (
            not self.client.text().strip() or not self.tenant.text().strip()
        ):
            QMessageBox.information(
                self, "Teams setup", "Enter the approved public-client application ID and tenant."
            )
            return
        if self.provider == "slack" and not self.token.text().strip():
            QMessageBox.information(self, "Slack setup", "Enter the approved Slack app token.")
            return
        self.accept()


class TranscriptImportDialog(QDialog):
    imported = Signal(object)

    def __init__(
        self, backend: Backend, parent: Window, service: TranscriptService | None = None
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle("Import Meeting Transcript")
        self.resize(1080, 760)
        self.setMinimumSize(900, 600)
        self.backend = backend
        self.service = service or TranscriptService(backend)
        self.pool = parent.pool
        self.signals = ImportSignals()
        self.signals.message.connect(self.on_result)
        self.connections_path = backend.paths.config / "connections.json"
        self.connections_unavailable = False
        try:
            self.connections, warning = load_connections(self.connections_path)
        except OSError as error:
            self.connections, warning = [], f"Cannot read connection settings: {error}"
            self.connections_unavailable = True
        self.prepared: PreparedTranscript | None = None
        self.meeting: MeetingSource | None = None
        self.device_url: str | None = None
        self.generation = 0
        self.cancel_event = threading.Event()
        self.busy = False
        self.committing = False
        self.setWindowModality(Qt.WindowModality.WindowModal)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(18, 18, 18, 14)
        layout.setSpacing(14)
        layout.addWidget(label("Import a meeting transcript", "heading"))
        layout.addWidget(
            label("Choose a source, review its speakers and text, then save it to history.")
        )
        splitter = QSplitter()
        left = QWidget()
        source_layout = QVBoxLayout(left)
        source_layout.setContentsMargins(0, 0, 14, 0)
        source_layout.setSpacing(12)
        self.source_type = SegmentedControl(["File", "Teams", "Slack"])
        self.source_type.changed.connect(self.source_changed)
        source_layout.addWidget(self.source_type)
        self.source_pages = QStackedWidget()
        source_layout.addWidget(self.source_pages, 1)
        self.setup_file()
        self.setup_provider("teams")
        self.setup_provider("slack")
        splitter.addWidget(left)
        right = QWidget()
        preview_layout = QVBoxLayout(right)
        preview_layout.setContentsMargins(14, 0, 0, 0)
        preview_layout.setSpacing(12)
        preview_layout.addWidget(label("TRANSCRIPT PREVIEW", "eyebrow"))
        self.title = QLineEdit()
        self.title.setPlaceholderText("Meeting title")
        preview_layout.addWidget(self.title)
        self.summary = label("Nothing is saved until you choose Import.")
        self.summary.setWordWrap(True)
        preview_layout.addWidget(self.summary)
        self.preview_stack = QStackedWidget()
        self.preview_stack.addWidget(
            empty_state(
                "Preview a transcript", "Select an export or load a transcript from Teams or Slack."
            )
        )
        self.table = QTableView()
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setAlternatingRowColors(True)
        self.table.setWordWrap(False)
        self.table.verticalHeader().hide()
        self.preview_stack.addWidget(self.table)
        preview_layout.addWidget(self.preview_stack, 1)
        self.passage = QTextEdit()
        self.passage.setReadOnly(True)
        self.passage.setMaximumHeight(100)
        self.passage.setPlaceholderText("Select a row to read its complete passage.")
        preview_layout.addWidget(self.passage)
        note = label(
            "Names and times come from the source. Unnamed and untimed speech stays unlabeled and untimed."
        )
        note.setWordWrap(True)
        preview_layout.addWidget(note)
        splitter.addWidget(right)
        splitter.setSizes([350, 700])
        splitter.setStretchFactor(1, 1)
        layout.addWidget(splitter, 1)
        self.status = label(warning or "")
        self.status.setWordWrap(True)
        self.status.setTextFormat(Qt.TextFormat.PlainText)
        layout.addWidget(self.status)
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setTextVisible(False)
        self.progress.setFixedHeight(5)
        self.progress.hide()
        layout.addWidget(self.progress)
        footer = QHBoxLayout()
        self.cancel_request = button("Cancel request", self.cancel_request_now, footer)
        self.cancel_request.hide()
        footer.addStretch()
        self.close_button = button("Cancel", self.reject, footer)
        self.import_button = button("Import", self.commit, footer)
        self.import_button.setProperty("role", "primary")
        self.import_button.setEnabled(False)
        layout.addLayout(footer)
        self.refresh_connections()

    def setup_file(self) -> None:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 8, 0, 0)
        self.file_provider = QComboBox()
        self.file_provider.addItem("Teams WebVTT (.vtt)", "teams")
        self.file_provider.addItem("Slack Huddle JSON (.json)", "slack")
        self.file_provider.currentIndexChanged.connect(self.invalidate_preview)
        layout.addWidget(self.file_provider)
        self.file_label = label("Choose an exported meeting transcript.")
        self.file_label.setWordWrap(True)
        layout.addWidget(self.file_label)
        self.file_button = button("Choose transcript…", self.open_file, layout)
        hint = label(
            "UTF-8 exports up to 8 MiB. Existing transcripts do not need a speech model or an LLM."
        )
        hint.setWordWrap(True)
        layout.addWidget(hint)
        layout.addStretch()
        self.source_pages.addWidget(scroll_page(page))

    def setup_provider(self, provider: Provider) -> None:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 8, 0, 0)
        connections = QComboBox()
        connections.setMinimumContentsLength(16)
        connections.currentIndexChanged.connect(lambda: self.connection_changed(provider))
        layout.addWidget(connections)
        row = QHBoxLayout()
        button("Add…", lambda: self.add_connection(provider), row)
        button("Edit…", lambda: self.edit_connection(provider), row)
        button("Remove…", lambda: self.remove_connection(provider), row)
        layout.addLayout(row)
        if provider == "teams":
            self.teams_connections = connections
            self.accounts = QComboBox()
            self.accounts.currentIndexChanged.connect(self.invalidate_sources)
            layout.addWidget(self.accounts)
            row = QHBoxLayout()
            button("Sign in…", self.sign_in, row)
            button("Sign out", self.sign_out, row)
            layout.addLayout(row)
            self.device_prompt = QLabel()
            self.device_prompt.setWordWrap(True)
            self.device_prompt.setTextFormat(Qt.TextFormat.PlainText)
            self.device_prompt.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
            layout.addWidget(self.device_prompt)
            self.open_sign_in = button("Open Microsoft sign-in", self.open_device_sign_in, layout)
            self.open_sign_in.hide()
            self.meeting_reference = QLineEdit()
            self.meeting_reference.setPlaceholderText("Teams meeting link or Graph meeting ID")
            self.meeting_reference.textChanged.connect(self.invalidate_sources)
            layout.addWidget(self.meeting_reference)
            self.owner = QLineEdit("me")
            self.owner.setPlaceholderText("Organizer's Graph user ID, or me")
            self.owner.textChanged.connect(self.invalidate_sources)
            self.owner.setToolTip(
                "Use me for your signed-in account, or the organizer's Graph user ID if needed."
            )
            layout.addWidget(label("Meeting owner"))
            layout.addWidget(self.owner)
            button("Find transcripts", self.load_teams_sources, layout)
            self.teams_sources = QComboBox()
            self.teams_sources.currentIndexChanged.connect(self.invalidate_preview)
            layout.addWidget(self.teams_sources)
            button("Preview selected transcript", self.preview_teams, layout)
            hint = label(
                "The connection's optional link-lookup permission is needed for meeting links. No calendar discovery is requested."
            )
        else:
            self.slack_connections = connections
            self.channel = QLineEdit()
            self.channel.setPlaceholderText("Channel ID (optional)")
            self.channel.textChanged.connect(self.invalidate_sources)
            layout.addWidget(self.channel)
            button("Find Huddle transcripts", self.load_slack_sources, layout)
            self.slack_sources = QComboBox()
            self.slack_sources.currentIndexChanged.connect(self.slack_source_changed)
            layout.addWidget(self.slack_sources)
            self.file_id = QLineEdit()
            self.file_id.setPlaceholderText("Or enter a Huddle file/canvas ID")
            self.file_id.textChanged.connect(self.invalidate_preview)
            layout.addWidget(self.file_id)
            button("Preview Huddle transcript", self.preview_slack, layout)
            hint = label(
                "Availability depends on workspace settings and file access. Notes-only files are not imported as transcripts."
            )
        hint.setWordWrap(True)
        layout.addWidget(hint)
        layout.addStretch()
        self.source_pages.addWidget(scroll_page(page))

    def selected_connection(self, provider: Provider) -> Connection | None:
        box = self.teams_connections if provider == "teams" else self.slack_connections
        selected: object = box.currentData()
        return selected if isinstance(selected, Connection) else None

    def selected_account(self) -> str | None:
        account: object = self.accounts.currentData()
        return account if isinstance(account, str) and account else None

    def refresh_connections(self, select_id: str | None = None) -> None:
        boxes: tuple[tuple[Provider, QComboBox], ...] = (
            ("teams", self.teams_connections),
            ("slack", self.slack_connections),
        )
        for provider, box in boxes:
            current = self.selected_connection(provider)
            selected = select_id or (current.id if current else None)
            box.blockSignals(True)
            box.clear()
            box.addItem("Choose a connection", None)
            for item in self.connections:
                if item.provider == provider:
                    box.addItem(item.label, item)
                    if item.id == selected:
                        box.setCurrentIndex(box.count() - 1)
            box.blockSignals(False)
        if self.source_type.currentIndex() == 1:
            self.connection_changed("teams")
        elif self.source_type.currentIndex() == 2:
            self.connection_changed("slack")

    def source_changed(self, index: int) -> None:
        if self.busy:
            return
        self.source_pages.setCurrentIndex(index)
        self.invalidate_sources()
        self.title.clear()
        if index == 1:
            self.connection_changed("teams")

    def invalidate_preview(self, *_args: object) -> None:
        if not hasattr(self, "import_button"):
            return
        self.prepared = None
        self.import_button.setEnabled(False)
        self.preview_stack.setCurrentIndex(0)
        self.passage.clear()
        self.summary.setText("Nothing is saved until you choose Import.")

    def invalidate_sources(self, *_args: object) -> None:
        self.invalidate_preview()
        self.meeting = None
        if hasattr(self, "teams_sources"):
            self.teams_sources.clear()
        if hasattr(self, "slack_sources"):
            self.slack_sources.clear()
        if hasattr(self, "file_id"):
            self.file_id.clear()

    def connection_changed(self, provider: Provider) -> None:
        if not hasattr(self, "import_button"):
            return
        self.invalidate_sources()
        if provider == "teams":
            self.accounts.clear()
            connection = self.selected_connection("teams")
            if connection:
                self.run(
                    lambda _cancel, _generation: ("accounts", self.service.accounts(connection))
                )

    def set_busy(self, busy: bool) -> None:
        self.busy = busy
        self.source_type.setEnabled(not busy)
        for control_type in (QPushButton, QComboBox, QLineEdit):
            for control in self.source_pages.findChildren(control_type):
                if control is not self.open_sign_in:
                    control.setEnabled(not busy)
        self.progress.setVisible(busy)
        self.cancel_request.setVisible(busy and not self.committing)
        self.close_button.setEnabled(not busy or not self.committing)
        self.import_button.setEnabled(not busy and self.prepared is not None)
        self.open_sign_in.setEnabled(True)

    def run(
        self, function: Callable[[threading.Event, int], ImportResult], *, committing: bool = False
    ) -> None:
        if self.busy:
            return
        self.generation += 1
        self.cancel_event = threading.Event()
        self.committing = committing
        self.set_busy(True)
        self.status.setText("Working…")
        generation, cancel = self.generation, self.cancel_event
        self.pool.start(ImportTask(generation, lambda: function(cancel, generation), self.signals))

    def cancel_request_now(self) -> None:
        if self.busy and self.committing:
            return
        self.cancel_event.set()
        self.generation += 1
        self.set_busy(False)
        self.clear_device_prompt()
        self.status.setText("Request canceled. Nothing was imported.")

    def open_file(self) -> None:
        path, _filter = QFileDialog.getOpenFileName(
            self,
            "Choose a meeting transcript",
            "",
            "Teams WebVTT (*.vtt);;Slack Huddle JSON (*.json)",
        )
        if not path:
            return
        source = Path(path)
        self.file_provider.setCurrentIndex(1 if source.suffix.lower() == ".json" else 0)
        self.file_label.setText(source.name)
        self.title.setText(source.stem)
        provider: Provider = "slack" if self.file_provider.currentIndex() == 1 else "teams"
        self.invalidate_preview()
        self.run(
            lambda _cancel, _generation: (
                "prepared",
                self.service.from_file(source, provider, source.stem),
            ),
        )

    def edit_connection(self, provider: Provider) -> None:
        current = self.selected_connection(provider)
        if current is None:
            self.status.setText("Choose a connection to edit.")
            return
        self.add_connection(provider, current)

    def add_connection(self, provider: Provider, existing: Connection | None = None) -> None:
        if self.connections_unavailable:
            self.status.setText("Fix access to connection settings before saving a connection.")
            return
        dialog = ConnectionDialog(provider, self, existing)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        if provider == "teams":
            value = Connection(
                existing.id if existing else uuid.uuid4().hex,
                "teams",
                dialog.label.text().strip(),
                client_id=dialog.client.text().strip(),
                tenant=dialog.tenant.text().strip(),
                meeting_links=dialog.option.isChecked(),
            )
            try:
                values = [item for item in self.connections if item.id != value.id] + [value]
                save_connections(self.connections_path, values)
                self.connections = values
                self.refresh_connections(value.id)
            except Exception as error:
                self.status.setText(str(error))
        else:
            token = dialog.token.text().strip()
            name, resolve = dialog.label.text().strip(), dialog.option.isChecked()
            dialog.token.clear()
            self.run(
                lambda _cancel, _generation: (
                    "slack_connected",
                    (
                        self.service.connect_slack(token),
                        name,
                        resolve,
                        existing.id if existing else None,
                    ),
                ),
            )

    def remove_connection(self, provider: Provider) -> None:
        connection = self.selected_connection(provider)
        if (
            connection
            and QMessageBox.question(
                self,
                "Remove connection",
                "Remove this connection and its stored sign-in credentials? Imported history will remain.",
            )
            == QMessageBox.StandardButton.Yes
        ):

            def disconnect(_cancel: threading.Event, _generation: int) -> ImportResult:
                self.service.disconnect(connection)
                return "disconnected", connection.id

            self.run(disconnect)

    def sign_in(self) -> None:
        connection = self.selected_connection("teams")
        if connection is None:
            self.status.setText("Add or choose a Teams connection first.")
            return
        self.invalidate_preview()
        # run() creates the cancellation event before executing this closure.
        self.run(
            lambda cancel, generation: (
                "accounts",
                self.service.sign_in(
                    connection,
                    lambda prompt: self.signals.send(generation, ("device_prompt", prompt)),
                    cancel,
                ),
            ),
        )

    def sign_out(self) -> None:
        connection, account = self.selected_connection("teams"), self.selected_account()
        if connection and account:
            self.run(
                lambda _cancel, _generation: (
                    "accounts",
                    self.service.sign_out(connection, account),
                )
            )

    def open_device_sign_in(self) -> None:
        if self.device_url:
            QDesktopServices.openUrl(QUrl(self.device_url))

    def clear_device_prompt(self) -> None:
        self.device_url = None
        self.device_prompt.clear()
        self.open_sign_in.hide()

    def load_teams_sources(self) -> None:
        connection = self.selected_connection("teams")
        if not connection:
            self.status.setText("Choose a Teams connection first.")
            return
        account, reference, owner = (
            self.selected_account(),
            self.meeting_reference.text().strip(),
            self.owner.text().strip() or "me",
        )
        if not account or not reference:
            self.status.setText("Choose a signed-in account and enter a meeting link or Graph ID.")
            return
        self.invalidate_sources()
        self.run(
            lambda cancel, _generation: (
                "teams_sources",
                self.service.teams_sources(connection, account, reference, owner, cancel),
            ),
        )

    def preview_teams(self) -> None:
        connection, account, meeting = (
            self.selected_connection("teams"),
            self.selected_account(),
            self.meeting,
        )
        source: object = self.teams_sources.currentData()
        if (
            not connection
            or not account
            or not isinstance(source, TranscriptSource)
            or meeting is None
        ):
            self.status.setText("Find and select a Teams transcript first.")
            return
        owner = self.owner.text().strip() or "me"
        title = self.title.text().strip() or meeting.title
        self.run(
            lambda cancel, _generation: (
                "prepared",
                self.service.from_teams(connection, account, meeting, source, owner, title, cancel),
            ),
        )

    def load_slack_sources(self) -> None:
        connection = self.selected_connection("slack")
        if not connection:
            self.status.setText("Connect a Slack workspace first.")
            return
        channel = self.channel.text().strip()
        self.invalidate_sources()
        self.run(
            lambda cancel, _generation: (
                "slack_sources",
                self.service.slack_sources(connection, channel, cancel),
            ),
        )

    def slack_source_changed(self, *_args: object) -> None:
        self.invalidate_preview()
        source: object = self.slack_sources.currentData()
        if isinstance(source, TranscriptSource):
            self.file_id.setText(source.id)
            self.title.setText(source.title)

    def preview_slack(self) -> None:
        connection, file_id = self.selected_connection("slack"), self.file_id.text().strip()
        if not connection or not file_id:
            self.status.setText("Choose a workspace and a Huddle transcript file.")
            return
        title = self.title.text().strip() or "Slack Huddle"
        self.run(
            lambda cancel, _generation: (
                "prepared",
                self.service.from_slack(connection, file_id, title, cancel),
            ),
        )

    def show_preview(self, prepared: PreparedTranscript) -> None:
        self.prepared = prepared
        self.title.setText(prepared.title)
        timed = sum(cue.start_secs is not None for cue in prepared.utterances)
        self.summary.setText(
            f"{len(prepared.utterances)} passages · {len(prepared.speakers)} source speaker labels · {timed} timed passages"
        )
        self.model = UtteranceModel(prepared, self.table)
        self.table.setModel(self.model)
        self.table.setColumnWidth(0, 74)
        self.table.setColumnWidth(1, 130)
        self.table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        self.table.selectionModel().currentRowChanged.connect(self.show_passage)
        self.preview_stack.setCurrentIndex(1)
        self.import_button.setEnabled(True)
        self.status.setText(
            "Review the source text, then choose Import. Nothing has been saved yet."
        )

    def show_passage(self, current: QModelIndex, _previous: QModelIndex) -> None:
        if self.prepared and current.isValid():
            self.passage.setPlainText(self.prepared.utterances[current.row()].text)

    def commit(self) -> None:
        if self.prepared is None or self.busy:
            return
        prepared, title = self.prepared, self.title.text().strip()
        self.run(
            lambda _cancel, _generation: ("committed", self.service.commit(prepared, title)),
            committing=True,
        )

    def on_result(self, generation: int, message: ImportMessage) -> None:
        try:
            self.apply_result(generation, message)
        except Exception as error:
            self.set_busy(False)
            self.status.setText(str(error))

    def apply_result(self, generation: int, message: ImportMessage) -> None:
        if generation != self.generation:
            return
        if message[0] == "device_prompt":
            value = message[1]
            self.device_prompt.setText(value.message)
            self.device_url = value.url
            self.open_sign_in.show()
            return
        self.set_busy(False)
        self.clear_device_prompt()
        if message[0] == "error":
            self.status.setText(message[1])
        elif message[0] == "prepared":
            self.show_preview(message[1])
        elif message[0] == "accounts":
            accounts = message[1]
            self.accounts.clear()
            self.accounts.addItem("Choose a work account", None)
            for account in accounts:
                self.accounts.addItem(account.label, account.id)
            if len(accounts) == 1:
                self.accounts.setCurrentIndex(1)
            self.status.setText(
                "Choose an account, then find a meeting's transcripts."
                if accounts
                else "Use Sign in to connect a work account."
            )
        elif message[0] == "teams_sources":
            self.meeting, sources = message[1]
            self.teams_sources.clear()
            for source in sources:
                self.teams_sources.addItem(source.created_at or source.title, source)
            self.title.setText(self.meeting.title)
            self.status.setText(
                f"{len(sources)} transcripts available."
                if sources
                else "No transcripts are available for this meeting and account."
            )
        elif message[0] == "slack_sources":
            sources = message[1]
            self.slack_sources.clear()
            for source in sources:
                self.slack_sources.addItem(source.title, source)
            self.status.setText(
                f"{len(sources)} Huddle transcripts found."
                if sources
                else "No accessible files advertised a Huddle transcript. Enter a known file ID or import an export."
            )
        elif message[0] == "slack_connected":
            identity, name, resolve, edit_id = message[1]
            existing = next(
                (
                    item
                    for item in self.connections
                    if item.provider == "slack" and item.workspace_id == identity.workspace_id
                ),
                None,
            )
            connection = Connection(
                existing.id if existing else edit_id or uuid.uuid4().hex,
                "slack",
                name,
                workspace_id=identity.workspace_id,
                resolve_names=resolve,
            )
            values = [item for item in self.connections if item.id != connection.id] + [connection]
            try:
                save_connections(self.connections_path, values)
                self.connections = values
                self.refresh_connections(connection.id)
                self.status.setText(f"Connected to {identity.workspace} as {identity.user}.")
            except Exception as error:
                self.status.setText(str(error))
        elif message[0] == "disconnected":
            connections = [item for item in self.connections if item.id != message[1]]
            save_connections(self.connections_path, connections)
            self.connections = connections
            self.refresh_connections()
            self.status.setText("Connection removed; imported history is unchanged.")
        elif message[0] == "committed":
            self.imported.emit(message[1])
            self.accept()

    @override
    def closeEvent(self, event: QCloseEvent) -> None:
        if self.busy and self.committing:
            event.ignore()
            return
        super().closeEvent(event)

    @override
    def reject(self) -> None:
        if self.busy and self.committing:
            return
        self.cancel_event.set()
        self.generation += 1
        super().reject()
