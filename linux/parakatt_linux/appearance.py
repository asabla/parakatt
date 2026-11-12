"""Shared desktop appearance, aligned with the macOS application's dark UI."""

from pathlib import Path

from PySide6.QtGui import QColor, QFont, QPalette
from PySide6.QtWidgets import QApplication, QLabel


def apply_appearance():
    app = QApplication.instance()
    if app.property("parakattAppearance"):
        return
    app.setProperty("parakattAppearance", True)
    app.setStyle("Fusion")
    app.setFont(QFont("Sans Serif", 10))
    palette = QPalette()
    for role, color in [
        (QPalette.ColorRole.Window, "#303030"),
        (QPalette.ColorRole.Base, "#1e1e1e"),
        (QPalette.ColorRole.AlternateBase, "#282828"),
        (QPalette.ColorRole.Text, "#dddddd"),
        (QPalette.ColorRole.WindowText, "#dddddd"),
        (QPalette.ColorRole.Button, "#575757"),
        (QPalette.ColorRole.ButtonText, "#eeeeee"),
        (QPalette.ColorRole.Highlight, "#075cdb"),
        (QPalette.ColorRole.HighlightedText, "#ffffff"),
        (QPalette.ColorRole.PlaceholderText, "#818181"),
    ]:
        palette.setColor(role, QColor(color))
    palette.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Text, QColor("#777777"))
    app.setPalette(palette)
    app.setStyleSheet(STYLE.replace("@ASSETS@", str(Path(__file__).parent / "assets")))


def label(text, role="muted"):
    widget = QLabel(text)
    widget.setProperty("role", role)
    return widget


STYLE = """
QWidget { color: #dddddd; font-size: 13px; }
QMainWindow, QDialog { background: #303030; }
QDialog#recordingWindow { background: #242526; }
QLabel { background: transparent; }
QLabel[role="muted"] { color: #999999; font-size: 12px; }
QLabel[role="eyebrow"] { color: #a2a2a2; font-size: 12px; font-weight: 600; }
QLabel[role="heading"] { font-size: 22px; font-weight: 600; }
QLabel[role="section"] { font-size: 16px; font-weight: 600; }
QLabel[role="badge"] { color: #ff9f32; background: #413328; border-radius: 13px; padding: 6px 12px; }
QLabel[role="stat"] { font-size: 24px; font-weight: 600; }
QFrame#toolbar, QFrame#detailHeader { background: #303030; border-bottom: 1px solid #444444; }
QFrame#paper, QFrame#settingsGroup { background: #1e1e1e; border: none; border-radius: 10px; }
QWidget#transcriptBody, QWidget#historyPane { background: #1e1e1e; }
QFrame#filterBar { border-bottom: 1px solid #444444; background: #303030; }
QTabWidget::pane { border: none; }
QTabBar::tab { background: #393939; padding: 7px 15px; color: #aaaaaa; border: none; }
QTabBar::tab:selected { background: #5a5a5a; color: #eeeeee; border-radius: 5px; }
QTabBar::tab:hover { color: white; }
QTabWidget#settingsTabs::tab-bar { alignment: center; }
QLineEdit, QComboBox, QSpinBox { background: #272727; border: 1px solid #494949; border-radius: 5px; padding: 5px 9px; min-height: 18px; selection-background-color: #075cdb; }
QLineEdit:focus, QComboBox:focus, QSpinBox:focus { border-color: #0a84ff; }
QLineEdit#historySearch { background: #1e1e1e; border: none; padding: 11px 12px; font-size: 14px; }
QComboBox::drop-down { border: none; width: 22px; }
QComboBox::down-arrow { image: url(@ASSETS@/down.svg); width: 12px; height: 12px; }
QSpinBox::up-button { subcontrol-origin: border; subcontrol-position: top right; width: 20px; border: none; }
QSpinBox::down-button { subcontrol-origin: border; subcontrol-position: bottom right; width: 20px; border: none; }
QSpinBox::up-arrow { image: url(@ASSETS@/up.svg); width: 10px; height: 10px; }
QSpinBox::down-arrow { image: url(@ASSETS@/down.svg); width: 10px; height: 10px; }
QComboBox QAbstractItemView { background: #303030; selection-background-color: #075cdb; }
QLineEdit#recordingTitle { border: none; font-size: 20px; font-weight: 600; padding: 0; background: transparent; }
QPushButton { background: #595959; border: 1px solid #666666; border-radius: 5px; padding: 4px 12px; min-height: 18px; }
QPushButton:hover { background: #686868; }
QPushButton:pressed { background: #737373; }
QPushButton:disabled { color: #777777; background: #3b3b3b; border-color: #444444; }
QPushButton[role="primary"] { background: #0968d7; border-color: #147ae7; color: white; }
QPushButton[role="quiet"] { background: transparent; border-color: transparent; color: #aaaaaa; }
QPushButton[role="quiet"]:hover { background: #414141; color: white; }
QPushButton[role="danger"] { background: #b63128; color: white; border-color: #c54439; }
QPushButton::menu-indicator { subcontrol-position: right center; right: 5px; }
QPushButton[segmented="true"] { background: transparent; border: none; padding: 3px 10px; color: #cccccc; }
QPushButton[segmented="true"]:checked { background: #686868; color: white; }
QFrame#segmented { background: #393939; border: 1px solid #4c4c4c; border-radius: 6px; }
QListWidget { background: #1e1e1e; border: 1px solid #444444; outline: none; padding: 4px; }
QListWidget::item { padding: 10px; border-radius: 5px; }
QListWidget::item:selected { background: #075cdb; color: white; }
QListWidget#recordings, QListWidget#timeline { border: none; padding: 0; }
QListWidget#recordings::item, QListWidget#timeline::item { padding: 0; }
QTextEdit { background: #1e1e1e; border: 1px solid #444444; border-radius: 5px; padding: 10px; selection-background-color: #075cdb; }
QTextEdit#transcript, QTextEdit#liveText { border: none; border-radius: 0; padding: 0; font-size: 15px; }
QCheckBox { spacing: 9px; padding: 5px 0; }
QCheckBox::indicator { width: 15px; height: 15px; border: 1px solid #777777; border-radius: 3px; background: #383838; }
QCheckBox::indicator:checked { background: #0879ef; border-color: #0879ef; image: url(@ASSETS@/check.svg); }
QCheckBox:disabled { color: #777777; }
QTableWidget { background: #1e1e1e; border: 1px solid #444444; gridline-color: #393939; selection-background-color: #075cdb; }
QHeaderView::section { background: #383838; color: #bbbbbb; padding: 8px; border: none; }
QSplitter::handle { background: #444444; width: 1px; }
QScrollArea { background: transparent; border: none; }
QScrollBar:vertical { background: transparent; width: 9px; margin: 2px; }
QScrollBar::handle:vertical { background: #6b6b6b; border-radius: 3px; min-height: 30px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical { background: transparent; }
QSlider::groove:horizontal { height: 5px; background: #444444; border-radius: 2px; }
QSlider::sub-page:horizontal { background: #147bea; border-radius: 2px; }
QSlider::handle:horizontal { background: #bbbbbb; width: 12px; margin: -4px 0; border-radius: 6px; }
QProgressBar { background: #404040; border: none; border-radius: 3px; height: 6px; }
QProgressBar::chunk { background: #147bea; border-radius: 3px; }
QMenuBar { background: #303030; }
QMenuBar::item:selected { background: #505050; }
QMenu { background: #303030; border: 1px solid #555555; padding: 5px; }
QMenu::item { padding: 7px 24px; border-radius: 4px; }
QMenu::item:selected { background: #075cdb; }
QStatusBar { background: #303030; color: #999999; font-size: 11px; border-top: 1px solid #444444; }
QToolTip { background: #484848; color: white; border: 1px solid #666666; padding: 6px; }
"""
