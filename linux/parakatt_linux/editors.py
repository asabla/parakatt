"""Focused editors for dictionary rules and processing modes."""

from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QLabel,
    QLineEdit,
    QTextEdit,
    QVBoxLayout,
)

from .appearance import label


class RuleEditor(QDialog):
    def __init__(
        self, parent, pattern="", replacement="", context="always", value="", enabled=True
    ):
        super().__init__(parent)
        self.setWindowTitle("Dictionary rule")
        self.resize(560, 370)
        layout = QVBoxLayout(self)
        layout.addWidget(
            label("Edit dictionary rule" if pattern else "Add dictionary rule", "heading")
        )
        helper = label(
            "Correct recurring recognition errors without changing the original transcript. Prefix regular expressions with re:."
        )
        helper.setWordWrap(True)
        layout.addWidget(helper)
        form = QFormLayout()
        self.pattern = QLineEdit(pattern)
        self.pattern.setPlaceholderText("A name or phrase; prefix regular expressions with re:")
        self.replacement = QLineEdit(replacement)
        self.context = QComboBox()
        for title, data in [
            ("Always", "always"),
            ("In an application", "in_app"),
            ("In a processing mode", "when_mode"),
        ]:
            self.context.addItem(title, data)
        self.context.setCurrentIndex(max(0, self.context.findData(context)))
        self.value = QLineEdit(value)
        self.value.setPlaceholderText("Application identifier or processing mode")
        self.enabled = QCheckBox("Enable this rule")
        self.enabled.setChecked(enabled)
        form.addRow("Pattern", self.pattern)
        form.addRow("Replacement", self.replacement)
        form.addRow("Apply", self.context)
        form.addRow("Context", self.value)
        form.addRow(self.enabled)
        layout.addLayout(form)
        self.error = label("")
        self.error.setWordWrap(True)
        layout.addWidget(self.error)
        self.context.currentIndexChanged.connect(self.scope_changed)
        self.scope_changed()
        self.core = parent.core
        actions = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        actions.accepted.connect(self.validate)
        actions.rejected.connect(self.reject)
        actions.button(QDialogButtonBox.StandardButton.Save).setProperty("role", "primary")
        layout.addWidget(actions)

    def scope_changed(self, _index=0):
        self.value.setEnabled(self.context.currentData() != "always")
        self.error.setText(
            "Application rules require focused-app context, which this Linux frontend does not currently supply."
            if self.context.currentData() == "in_app"
            else ""
        )

    def validate(self):
        if not self.pattern.text():
            self.error.setText("Enter a pattern.")
            return
        error = self.core.validate_dictionary_pattern(self.pattern.text())
        if error:
            self.error.setText(error)
            return
        if self.context.currentData() != "always" and not self.value.text().strip():
            self.error.setText("Enter the application identifier or processing mode.")
            return
        self.accept()


class ModeEditor(QDialog):
    def __init__(self, parent, name="", provider="", prompt="", dictionary=True):
        super().__init__(parent)
        self.setWindowTitle("Processing mode")
        self.resize(620, 490)
        self.original_name = name
        layout = QVBoxLayout(self)
        layout.addWidget(
            label("Edit processing mode" if name else "New processing mode", "heading")
        )
        form = QFormLayout()
        self.name = QLineEdit(name)
        self.name.setPlaceholderText("e.g. Meeting minutes")
        self.name.setReadOnly(
            name.lower() in ("dictation", "punctuation", "clean", "email", "code")
        )
        self.provider = QComboBox()
        self.provider.addItem("Default provider", "")
        for value in ["ollama", "lmstudio", "chatgpt", "openai", "anthropic"]:
            self.provider.addItem(value, value)
        if provider and self.provider.findData(provider) < 0:
            self.provider.addItem(provider, provider)
        self.provider.setCurrentIndex(max(0, self.provider.findData(provider)))
        form.addRow("Name", self.name)
        form.addRow("Provider override", self.provider)
        layout.addLayout(form)
        layout.addWidget(QLabel("Instructions"))
        self.prompt = QTextEdit()
        self.prompt.setPlaceholderText("Describe how this mode should process recognized speech.")
        self.prompt.setPlainText(prompt)
        layout.addWidget(self.prompt, 1)
        self.dictionary = QCheckBox("Apply dictionary rules")
        self.dictionary.setChecked(dictionary)
        layout.addWidget(self.dictionary)
        helper = label(
            "Remote providers receive the recognized text when this mode uses them. Changes apply to future recordings."
        )
        helper.setWordWrap(True)
        layout.addWidget(helper)
        self.error = label("")
        layout.addWidget(self.error)
        self.parent_settings = parent
        actions = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        actions.accepted.connect(self.validate)
        actions.rejected.connect(self.reject)
        actions.button(QDialogButtonBox.StandardButton.Save).setProperty("role", "primary")
        layout.addWidget(actions)

    def validate(self):
        name = self.name.text().strip()
        existing = {
            self.parent_settings.modes.item(index, 0).text().casefold()
            for index in range(self.parent_settings.modes.rowCount())
        }
        if not name or (
            name.casefold() != self.original_name.casefold() and name.casefold() in existing
        ):
            self.error.setText("Choose a unique, non-empty mode name.")
            return
        if name.casefold() != self.original_name.casefold() and name.casefold() in (
            "off",
            "grammar + punctuation",
        ):
            self.error.setText("That name is reserved for a built-in cleanup choice.")
            return
        self.accept()
