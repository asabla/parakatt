"""Shared desktop palette, typography, and widget treatments."""

from pathlib import Path

from PySide6.QtGui import QColor, QFont, QPalette
from PySide6.QtWidgets import QApplication, QLabel


def apply_appearance():
    app = QApplication.instance()
    if app.property("parakattAppearance"):
        return
    app.setProperty("parakattAppearance", True)
    app.setStyle("Fusion")
    app.setFont(QFont("DejaVu Sans", 10))
    palette = QPalette()
    for role, color in [
        (QPalette.ColorRole.Window, "#f7f8f5"),
        (QPalette.ColorRole.Base, "#ffffff"),
        (QPalette.ColorRole.Text, "#253a32"),
        (QPalette.ColorRole.WindowText, "#253a32"),
        (QPalette.ColorRole.ButtonText, "#253a32"),
        (QPalette.ColorRole.Highlight, "#dcebe0"),
        (QPalette.ColorRole.HighlightedText, "#1c503d"),
    ]:
        palette.setColor(role, QColor(color))
    app.setPalette(palette)
    app.setStyleSheet(STYLE.replace("@ASSETS@", str(Path(__file__).parent / "assets")))


def label(text, role="muted"):
    widget = QLabel(text)
    widget.setProperty("role", role)
    return widget


STYLE = """
QWidget { color: #253a32; font-size: 13px; }
QMainWindow, QDialog { background: #f7f8f5; }
QLabel { background: transparent; }
QLabel[role="muted"] { color: #7b8780; font-size: 12px; }
QLabel[role="eyebrow"] { color: #8b968e; font-size: 10px; font-weight: 600; letter-spacing: 1.5px; }
QLabel[role="heading"] { font-size: 27px; font-weight: 600; letter-spacing: -0.8px; }
QLabel[role="section"] { font-size: 18px; font-weight: 600; }
QLabel[role="badge"] { color: #377453; background: #e9f1e8; border-radius: 10px; padding: 5px 10px; font-size: 10px; }
QLabel#brandMark { background: #24664d; color: #ffffff; font-size: 27px; border-radius: 11px; }
QFrame#sidebar { background: #edf0e9; border-right: 1px solid #e0e5dc; }
QFrame#paper, QFrame#liveCard { background: #ffffff; border: 1px solid #e1e6df; border-radius: 14px; }
QFrame#captureHero { background: #edf3ec; border: 1px solid #dce7d9; border-radius: 16px; }
QListWidget#navigation { background: transparent; border: none; outline: none; }
QListWidget#navigation::item { height: 44px; padding-left: 14px; border-radius: 8px; margin-bottom: 5px; color: #6f7e73; }
QListWidget#navigation::item:selected { background: #dce6d8; color: #264f39; font-weight: 600; border: none; }
QListWidget#navigation::item:hover { background: #e3e9df; }
QTabWidget::pane { border: none; background: transparent; }
QTabBar::tab { background: transparent; padding: 11px 16px; color: #849087; border-bottom: 2px solid transparent; }
QTabBar::tab:selected { color: #24664d; border-bottom: 2px solid #24664d; }
QLineEdit, QComboBox, QSpinBox { background: #ffffff; border: 1px solid #dfe5dc; border-radius: 7px; padding: 9px 11px; min-height: 17px; selection-background-color: #dcebe0; }
QLineEdit:focus, QComboBox:focus, QSpinBox:focus { border-color: #72a78b; }
QComboBox::drop-down { border: none; width: 22px; }
QComboBox::down-arrow { image: url(@ASSETS@/down.svg); width: 12px; height: 12px; }
QSpinBox::up-button { subcontrol-origin: border; subcontrol-position: top right; width: 22px; border: none; }
QSpinBox::down-button { subcontrol-origin: border; subcontrol-position: bottom right; width: 22px; border: none; }
QSpinBox::up-arrow { image: url(@ASSETS@/up.svg); width: 10px; height: 10px; }
QSpinBox::down-arrow { image: url(@ASSETS@/down.svg); width: 10px; height: 10px; }
QComboBox QAbstractItemView { background: white; selection-background-color: #e3efe3; padding: 5px; }
QLineEdit#recordingTitle { border: none; font-size: 24px; font-weight: 600; padding: 2px 0 7px 0; background: transparent; }
QPushButton { background: #ffffff; border: 1px solid #dce3d9; border-radius: 7px; padding: 9px 14px; font-weight: 500; }
QPushButton:hover { background: #f0f4ed; border-color: #bdcdbd; }
QPushButton:pressed { background: #e2ebdf; }
QPushButton:disabled { color: #a3ada5; background: #f3f5f0; border-color: #e8ece5; }
QPushButton[role="primary"] { background: #24664d; border-color: #24664d; color: white; }
QPushButton[role="primary"]:hover { background: #1b533d; }
QPushButton[role="quiet"] { background: transparent; border-color: transparent; color: #6e8074; }
QPushButton[role="quiet"]:hover { background: #e9eee5; }
QPushButton[role="danger"] { color: #a3564d; }
QPushButton::menu-indicator { subcontrol-position: right center; right: 6px; }
QListWidget { background: white; border: 1px solid #e0e6dc; border-radius: 10px; outline: none; padding: 6px; }
QListWidget::item { padding: 12px 10px; border-radius: 7px; margin-bottom: 4px; }
QListWidget::item:selected { background: #e9f0e5; color: #264c37; }
QListWidget::item:hover { background: #f3f6ef; }
QListWidget#recordings { background: transparent; border: none; padding: 0; }
QListWidget#recordings::item { border: 1px solid transparent; }
QListWidget#recordings::item:selected { border-color: #d8e4d3; background: #e9f0e5; }
QTextEdit { background: white; border: 1px solid #e0e6dc; border-radius: 9px; padding: 12px; selection-background-color: #dcebe0; }
QTextEdit#transcript, QTextEdit#liveText { border: none; background: transparent; padding: 0; font-family: "DejaVu Serif"; font-size: 19px; color: #3e5145; }
QCheckBox { spacing: 9px; color: #758578; padding: 4px 0; }
QCheckBox::indicator { width: 15px; height: 15px; border: 1px solid #cbd7c7; border-radius: 4px; background: white; }
QCheckBox::indicator:checked { background: #438465; border-color: #438465; image: url(@ASSETS@/check.svg); }
QCheckBox::indicator:disabled { background: #d8e0d4; border-color: #d8e0d4; }
QCheckBox:disabled { color: #a7afa5; }
QTableWidget { background: white; border: 1px solid #dfe5dc; gridline-color: #edf0e9; border-radius: 8px; selection-background-color: #e4eedf; }
QHeaderView::section { background: #edf2e8; color: #6f8071; padding: 9px; border: none; border-bottom: 1px solid #dfe5dc; }
QSplitter::handle { background: transparent; width: 18px; }
QScrollBar:vertical { background: transparent; width: 7px; margin: 3px; }
QScrollBar::handle:vertical { background: #cdd8c8; border-radius: 3px; min-height: 30px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QSlider::groove:horizontal { height: 4px; background: #e3e9de; border-radius: 2px; }
QSlider::sub-page:horizontal { background: #6d9a7d; border-radius: 2px; }
QSlider::handle:horizontal { background: #24664d; width: 10px; margin: -3px 0; border-radius: 5px; }
QMenu { background: white; border: 1px solid #dfe5dc; padding: 6px; }
QMenu::item { padding: 9px 22px; border-radius: 4px; }
QMenu::item:selected { background: #e9f0e5; }
QStatusBar { background: #f7f8f5; color: #8c978d; font-size: 11px; padding: 5px 22px; border-top: 1px solid #e7ebe2; }
QToolTip { background: #253a32; color: white; border: none; padding: 7px; }
"""
