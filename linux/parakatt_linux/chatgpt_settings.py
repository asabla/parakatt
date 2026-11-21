"""ChatGPT account controls backed by the shared native account service."""

from __future__ import annotations

from collections.abc import Callable
from typing import TYPE_CHECKING, cast

from PySide6.QtCore import QObject, QRunnable, QThreadPool, QUrl, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import QComboBox, QFrame, QHBoxLayout, QLabel, QPushButton, QVBoxLayout

from .backend import Backend
from .chatgpt import AccountService, SignInRequest, account_name, account_status

if TYPE_CHECKING:
    from ._native.parakatt_core import (
        ChatGptAccount,
        ChatGptModelChoice,
        ChatGptSignIn,
        ChatGptSignOut,
    )


class AccountSignals(QObject):
    result = Signal(int, str, object)


class AccountTask(QRunnable):
    def __init__(
        self, revision: int, kind: str, function: Callable[[], object], signals: AccountSignals
    ) -> None:
        super().__init__()
        self.revision, self.kind, self.function, self.signals = (
            revision,
            kind,
            function,
            signals,
        )

    def run(self) -> None:
        try:
            result = self.function()
            self.signals.result.emit(self.revision, self.kind, result)
        except Exception as error:
            self.signals.result.emit(self.revision, "error_" + self.kind, str(error))


class ChatGptSettings(QFrame):
    """Only the GUI thread updates widgets; account and HTTP work use the pool."""

    busy_changed = Signal(bool)

    def __init__(
        self, backend: Backend, pool: QThreadPool, service: AccountService | None = None
    ) -> None:
        super().__init__()
        self.backend, self.pool = backend, pool
        self.service: AccountService = (
            service if service is not None else backend.api.ChatGptAccounts()
        )
        self.signals = AccountSignals()
        self.signals.result.connect(self.on_result)
        self.revision, self.busy, self.active = 0, False, False
        self.request: SignInRequest | None = None
        self.accounts: list[ChatGptAccount] = []
        self.models: list[ChatGptModelChoice] = []
        self.selected = backend.engine.get_chatgpt_account()
        self.saved_model = backend.engine.get_provider_settings("chatgpt").model
        self.setObjectName("settingsGroup")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(12)
        row = QHBoxLayout()
        title = QLabel("Connection")
        title.setProperty("role", "section")
        row.addWidget(title, 1)
        self.status = QLabel("Not connected")
        row.addWidget(self.status)
        layout.addLayout(row)
        self.account = QComboBox()
        self.account.setAccessibleName("ChatGPT account")
        self.account.currentIndexChanged.connect(self.select_account)
        layout.addWidget(self.account)
        helper = QLabel(
            "Use your ChatGPT plan or available credits. Speech recognition stays local."
        )
        helper.setWordWrap(True)
        layout.addWidget(helper)
        row = QHBoxLayout()
        self.sign_in = QPushButton("Continue with ChatGPT")
        self.sign_in.setProperty("role", "primary")
        self.sign_in.clicked.connect(lambda: self.start_sign_in(False))
        self.add_account = QPushButton("Add account…")
        self.add_account.clicked.connect(lambda: self.start_sign_in(True))
        self.sign_out = QPushButton("Sign out")
        self.sign_out.clicked.connect(self.disconnect_account)
        self.cancel = QPushButton("Cancel sign-in")
        self.cancel.clicked.connect(self.cancel_sign_in)
        for control in (self.sign_in, self.add_account, self.sign_out, self.cancel):
            row.addWidget(control)
        row.addStretch()
        layout.addLayout(row)
        self.notice = QLabel("")
        self.notice.setWordWrap(True)
        self.notice.hide()
        layout.addWidget(self.notice)
        self.message = QLabel("")
        self.message.setWordWrap(True)
        layout.addWidget(self.message)
        row = QHBoxLayout()
        self.retry = QPushButton("Retry ChatGPT plan")
        self.retry.clicked.connect(lambda: self.fetch_models(retry=True))
        row.addWidget(self.retry)
        row.addStretch()
        usage = QPushButton("Manage usage ↗")
        usage.clicked.connect(
            lambda: QDesktopServices.openUrl(QUrl("https://chatgpt.com/settings/usage"))
        )
        row.addWidget(usage)
        layout.addLayout(row)
        layout.addWidget(QLabel("Model"))
        row = QHBoxLayout()
        self.model = QComboBox()
        self.model.setAccessibleName("ChatGPT model")
        row.addWidget(self.model, 1)
        self.refresh = QPushButton("Refresh models")
        self.refresh.clicked.connect(self.fetch_models)
        row.addWidget(self.refresh)
        layout.addLayout(row)
        row = QHBoxLayout()
        self.test = QPushButton("Test connection")
        self.test.setToolTip(
            "Apply the account and model, then send a short synthetic text request. "
            "No recording is sent; ChatGPT usage may apply."
        )
        self.test.clicked.connect(self.test_connection)
        row.addStretch()
        row.addWidget(self.test)
        layout.addLayout(row)
        self.model.currentIndexChanged.connect(self.update_controls)
        self.update_controls()

    def task(self, kind: str, function: Callable[[], object]) -> None:
        self.busy = True
        self.busy_changed.emit(True)
        self.update_controls()
        self.pool.start(AccountTask(self.revision, kind, function, self.signals))

    def activate(self, active: bool) -> None:
        self.active = active
        if active:
            self.reload()
        else:
            self.cancel_sign_in()
            self.notice.clear()
            self.notice.hide()

    def reload(self) -> None:
        if self.busy or not self.active:
            return
        self.task("accounts", self.service.list)

    def selected_account(self) -> ChatGptAccount | None:
        return next((account for account in self.accounts if account.id == self.selected), None)

    def ready(self) -> bool:
        account = self.selected_account()
        return bool(account and account.signed_in and account.plan_enabled and not account.paused)

    def update_controls(self, *_: object) -> None:
        account = self.selected_account()
        self.status.setText(account_status(account))
        self.account.setEnabled(not self.busy and bool(self.accounts))
        self.sign_in.setEnabled(not self.busy)
        self.add_account.setEnabled(not self.busy)
        self.add_account.setVisible(bool(self.accounts))
        self.sign_out.setEnabled(not self.busy and bool(account and account.signed_in))
        self.sign_out.setVisible(bool(self.accounts))
        self.cancel.setVisible(self.request is not None)
        self.retry.setVisible(bool(account and account.paused))
        self.retry.setEnabled(not self.busy)
        self.model.setEnabled(not self.busy and self.ready())
        self.refresh.setEnabled(not self.busy and self.ready())
        self.test.setEnabled(not self.busy and self.valid_model())

    def valid_model(self) -> bool:
        return self.ready() and self.model.currentData() in [model.slug for model in self.models]

    def require_model(self) -> str:
        if self.busy or not self.valid_model():
            raise ValueError("Connect a ChatGPT account and select one of its available models.")
        value: object = self.model.currentData()
        if not isinstance(value, str):
            raise ValueError("Select an available ChatGPT model.")
        return value

    def select_account(self, *_: object) -> None:
        selected: object = self.account.currentData()
        if self.busy or not isinstance(selected, str) or selected == self.selected:
            return
        self.selected = selected
        self.notice.clear()
        self.notice.hide()
        self.saved_model = ""
        self.models = []
        self.model.clear()
        self.revision += 1

        def select() -> list[ChatGptAccount]:
            self.service.select(selected)
            self.backend.engine.set_chatgpt_account(selected)
            return self.service.list()

        self.task("accounts", select)

    def start_sign_in(self, add: bool = False) -> None:
        if self.busy:
            return
        self.revision += 1
        self.request = SignInRequest(self.service, None if add else self.selected)
        self.notice.clear()
        self.notice.hide()
        self.message.setText("Preparing browser sign-in…")
        self.task("begin", self.request.begin)

    def cancel_sign_in(self) -> None:
        self.revision += 1
        if self.request is not None:
            self.request.cancel()
        self.request = None
        self.busy = False
        self.busy_changed.emit(False)
        self.models = []
        self.model.clear()
        self.message.setText("Sign-in cancelled.")
        self.update_controls()

    def disconnect_account(self) -> None:
        if not self.busy and self.selected:
            selected = self.selected
            self.models = []
            self.model.clear()
            self.task("signed_out", lambda: self.service.sign_out(selected))

    def fetch_models(self, _checked: bool = False, *, retry: bool = False) -> None:
        account = self.selected_account()
        if self.busy or not account or not account.signed_in or not account.plan_enabled:
            return
        if account.paused and not retry:
            return
        selected = self.selected
        self.message.setText("Loading available models…")

        def fetch() -> tuple[list[ChatGptModelChoice], list[ChatGptAccount]]:
            if retry:
                self.service.retry(selected)
            return self.service.models(selected), self.service.list()

        self.task("models", fetch)

    def test_connection(self) -> None:
        model = self.require_model()
        selected = self.selected
        self.message.setText("Testing with a short synthetic text request…")

        def test() -> str:
            self.backend.engine.set_chatgpt_account(selected)
            self.backend.configure_llm("chatgpt", "", model, None)
            report = self.backend.engine.test_llm_pipeline()
            return "\n".join(
                (
                    f"Connection: {report.connection}",
                    f"Account: {report.authentication}",
                    f"Model: {report.model}",
                    f"Completion: {report.completion}",
                )
            )

        self.task("tested", test)

    def on_result(self, revision: int, kind: str, value: object) -> None:
        if revision != self.revision or not self.active:
            return
        self.busy = False
        if kind.startswith("error_"):
            if self.request is not None:
                self.request.cancel()
            self.request = None
            self.message.setText(str(value))
            if kind in ("error_models", "error_tested"):
                self.task("status", self.service.list)
        elif kind == "begin":
            value = cast("ChatGptSignIn | None", value)
            if value is None or self.request is None:
                return
            if not QDesktopServices.openUrl(QUrl(value.authorization_url)):
                self.cancel_sign_in()
                self.message.setText(
                    "Cannot open your browser. Retry after setting a default browser."
                )
                return
            self.message.setText("Complete sign-in in your browser.")
            request = self.request

            def complete() -> tuple[ChatGptAccount, bool]:
                account = request.complete()
                return account, self.service.take_plan_confirmation(account.id)

            self.task("signed_in", complete)
        elif kind == "signed_in":
            account, confirmation = cast("tuple[ChatGptAccount, bool]", value)
            self.request = None
            # Only apply a completed sign-in after checking this dialog's
            # revision. Closing/cancelling can leave a late worker response.
            try:
                self.backend.engine.set_chatgpt_account(account.id)
            except Exception as error:
                self.message.setText(str(error))
                self.update_controls()
                self.busy_changed.emit(False)
                return
            self.selected = account.id
            self.saved_model = ""
            self.notice.setText(
                "You’re using your ChatGPT plan. Manage usage in your ChatGPT settings."
                if confirmation
                else "ChatGPT plan connected."
                if account.plan_enabled
                else "Plan access is disabled. Continue with ChatGPT to grant permission."
            )
            self.notice.show()
            self.reload()
        elif kind == "signed_out":
            value = cast("ChatGptSignOut", value)
            self.notice.setText(value.message)
            self.notice.show()
            self.reload()
        elif kind in ("accounts", "status"):
            value = cast("list[ChatGptAccount]", value)
            self.accounts = value
            ids = [account.id for account in value]
            if self.selected not in ids:
                self.selected = next((account.id for account in value if account.active), None)
            self.account.blockSignals(True)
            self.account.clear()
            if not value:
                self.account.addItem("Sign in to ChatGPT", None)
            for account in value:
                self.account.addItem(account_name(account, value), account.id)
            self.account.setCurrentIndex(max(0, self.account.findData(self.selected)))
            self.account.blockSignals(False)
            if kind == "accounts":
                self.fetch_models()
        elif kind == "models":
            self.models, self.accounts = cast(
                "tuple[list[ChatGptModelChoice], list[ChatGptAccount]]", value
            )
            selected = self.model.currentData() or self.saved_model
            self.model.clear()
            self.model.addItem("Select a model…", None)
            for model in self.models:
                self.model.addItem(model.display_name, model.slug)
            self.model.setCurrentIndex(max(0, self.model.findData(selected)))
            self.message.setText("" if self.models else "No models are available for this account.")
        elif kind == "tested":
            self.message.setText(str(value))
            # Refresh status after a test; a usage-limit response may pause it.
            self.task("status", self.service.list)
        self.update_controls()
        self.busy_changed.emit(self.busy)
