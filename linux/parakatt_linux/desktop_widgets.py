"""Small Qt controls shared by the history, settings, and recording windows."""

import math
from datetime import datetime

from PySide6.QtCore import QRect, QRectF, QSize, Qt, Signal
from PySide6.QtGui import QColor, QFont, QIcon, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtWidgets import (
    QButtonGroup,
    QCheckBox,
    QDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QStackedWidget,
    QStyle,
    QStyledItemDelegate,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from .appearance import label


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


ROW_DATA = Qt.ItemDataRole.UserRole + 1


def duration(seconds):
    seconds = max(0, int(seconds))
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    return (
        f"{hours}h {minutes}m" if hours else f"{minutes}m {seconds}s" if minutes else f"{seconds}s"
    )


def timestamp(seconds):
    seconds = max(0, int(seconds))
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours:02}:{minutes:02}:{seconds:02}" if hours else f"{minutes:02}:{seconds:02}"


def category(row):
    if row.source == "meeting" or row.audio_source in ("teams", "slack"):
        return "Meetings"
    return "Videos" if row.source == "import" else "Notes"


def source_label(row):
    if row.audio_source in ("teams", "slack"):
        return "Teams meeting" if row.audio_source == "teams" else "Slack Huddle"
    return {"Notes": "Voice Note", "Meetings": "Meeting", "Videos": "Video import"}[category(row)]


def draw_symbol(painter, rect, name, color):
    painter.save()
    painter.translate(rect.x(), rect.y())
    painter.scale(rect.width() / 24, rect.height() / 24)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    painter.setPen(
        QPen(
            QColor(color),
            1.7,
            Qt.PenStyle.SolidLine,
            Qt.PenCapStyle.RoundCap,
            Qt.PenJoinStyle.RoundJoin,
        )
    )
    painter.setBrush(Qt.BrushStyle.NoBrush)
    if name == "mic":
        painter.drawRoundedRect(QRectF(9, 3, 6, 12), 3, 3)
        path = QPainterPath()
        path.moveTo(6, 11)
        path.cubicTo(6, 21, 18, 21, 18, 11)
        painter.drawPath(path)
        painter.drawLine(12, 19, 12, 22)
        painter.drawLine(9, 22, 15, 22)
    elif name == "search":
        painter.drawEllipse(QRectF(3, 3, 13, 13))
        painter.drawLine(15, 15, 22, 22)
    elif name == "sidebar":
        painter.drawRoundedRect(QRectF(2, 4, 20, 16), 2, 2)
        painter.drawLine(9, 4, 9, 20)
        painter.drawLine(5, 8, 6, 8)
        painter.drawLine(5, 11, 6, 11)
    elif name == "document":
        painter.drawRoundedRect(QRectF(4, 2, 14, 19), 2, 2)
        painter.drawLine(7, 6, 15, 6)
        painter.drawLine(7, 10, 15, 10)
        painter.drawEllipse(QRectF(13, 14, 7, 7))
        painter.drawLine(19, 20, 23, 24)
    elif name == "people":
        painter.drawEllipse(QRectF(6, 3, 7, 7))
        path = QPainterPath()
        path.moveTo(2, 21)
        path.cubicTo(2, 10, 18, 10, 18, 21)
        path.closeSubpath()
        painter.drawPath(path)
        painter.drawArc(QRectF(12, 3, 7, 7), -80 * 16, 200 * 16)
        painter.drawArc(QRectF(13, 13, 9, 15), 0, 80 * 16)
    elif name == "video":
        painter.drawRoundedRect(QRectF(2, 5, 14, 14), 2, 2)
        path = QPainterPath()
        path.moveTo(16, 10)
        path.lineTo(22, 6)
        path.lineTo(22, 18)
        path.lineTo(16, 14)
        painter.drawPath(path)
    elif name == "edit":
        painter.drawLine(5, 19, 18, 6)
        painter.drawLine(17, 5, 20, 8)
        painter.drawLine(4, 20, 8, 19)
    elif name == "wave":
        for x, height in ((3, 5), (7, 13), (11, 23), (15, 15), (19, 8)):
            painter.drawLine(x, 12 - height // 2, x, 12 + height // 2)
    elif name == "copy":
        painter.drawRoundedRect(QRectF(8, 6, 12, 16), 2, 2)
        painter.drawRoundedRect(QRectF(3, 2, 12, 16), 2, 2)
    elif name == "trash":
        painter.drawLine(3, 6, 21, 6)
        painter.drawRoundedRect(QRectF(6, 6, 12, 16), 2, 2)
        painter.drawLine(10, 10, 10, 18)
        painter.drawLine(14, 10, 14, 18)
        painter.drawLine(9, 2, 15, 2)
        painter.drawLine(9, 2, 9, 6)
        painter.drawLine(15, 2, 15, 6)
    elif name == "check":
        painter.drawEllipse(QRectF(2, 2, 20, 20))
        painter.drawLine(7, 12, 11, 16)
        painter.drawLine(11, 16, 17, 8)
    painter.restore()


def icon(name, color="#b8b8b8", size=24):
    pixmap = QPixmap(size * 2, size * 2)
    pixmap.fill(Qt.GlobalColor.transparent)
    painter = QPainter(pixmap)
    draw_symbol(painter, QRectF(0, 0, size * 2, size * 2), name, color)
    painter.end()
    pixmap.setDevicePixelRatio(2)
    return QIcon(pixmap)


class SegmentedControl(QFrame):
    changed = Signal(int)

    def __init__(self, titles, parent=None):
        super().__init__(parent)
        self.setObjectName("segmented")
        self.group = QButtonGroup(self)
        self.buttons = []
        layout = QHBoxLayout(self)
        layout.setContentsMargins(1, 1, 1, 1)
        layout.setSpacing(1)
        for index, title in enumerate(titles):
            button = QPushButton(title)
            button.setProperty("segmented", True)
            button.setCheckable(True)
            self.group.addButton(button, index)
            layout.addWidget(button, 1)
            self.buttons.append(button)
        self.buttons[0].setChecked(True)
        self.group.idClicked.connect(self.changed)

    def setCurrentIndex(self, index):
        self.buttons[index].setChecked(True)
        self.changed.emit(index)

    def currentIndex(self):
        return self.group.checkedId()


class Switch(QCheckBox):
    def __init__(self, accessible_name):
        super().__init__()
        self.setAccessibleName(accessible_name)
        self.setFixedSize(44, 28)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def hitButton(self, pos):
        return self.rect().contains(pos)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(QPen(QColor("#666666"), 1))
        painter.setBrush(QColor("#137ae5" if self.isChecked() and self.isEnabled() else "#414141"))
        painter.drawRoundedRect(QRectF(1, 3, 42, 22), 11, 11)
        painter.setBrush(QColor("#c7c7c7" if self.isEnabled() else "#777777"))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.drawEllipse(QRectF(23 if self.isChecked() else 3, 5, 18, 18))
        if self.hasFocus():
            painter.setPen(QPen(QColor("#0a84ff"), 1))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawRoundedRect(QRectF(0.5, 1, 43, 26), 12, 12)


class HistoryDelegate(QStyledItemDelegate):
    def paint(self, painter, option, index):
        row = index.data(ROW_DATA)
        if row is None:
            return super().paint(painter, option, index)
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        rect = option.rect.adjusted(10, 4, -10, -4)
        selected = bool(option.state & QStyle.StateFlag.State_Selected)
        painter.setPen(Qt.PenStyle.NoPen)
        if selected:
            painter.setBrush(QColor("#075cdb"))
            painter.drawRoundedRect(QRectF(rect), 6, 6)
        elif option.state & QStyle.StateFlag.State_MouseOver:
            painter.setBrush(QColor("#292929"))
            painter.drawRoundedRect(QRectF(rect), 6, 6)
        x, y = rect.x() + 18, rect.y() + 13
        kind = category(row)
        color = "#ff9f32" if kind == "Meetings" else "#0a9dff"
        painter.setBrush(QColor("#1d303f" if kind != "Meetings" else "#3e3023"))
        painter.drawRoundedRect(QRectF(x, y, 24, 24), 6, 6)
        draw_symbol(
            painter,
            QRectF(x + 5, y + 4, 14, 16),
            {"Notes": "mic", "Meetings": "people", "Videos": "video"}[kind],
            color,
        )
        font = QFont(option.font)
        font.setPixelSize(14)
        font.setBold(True)
        painter.setFont(font)
        painter.setPen(QColor("#ffffff" if selected else "#dddddd"))
        title = row.title or row.text[:60] or "Untitled"
        text_rect = QRect(x + 32, y, rect.width() - 68, 24)
        painter.drawText(
            text_rect,
            Qt.AlignmentFlag.AlignVCenter,
            painter.fontMetrics().elidedText(title, Qt.TextElideMode.ElideRight, text_rect.width()),
        )
        font.setBold(False)
        font.setPixelSize(12)
        painter.setFont(font)
        painter.setPen(QColor("#c1d7fc" if selected else "#999999"))
        date = datetime.fromisoformat(row.created_at.replace("Z", "+00:00")).astimezone()
        painter.drawText(
            QRect(x, y + 29, rect.width() - 36, 19),
            f"{date:%a %d %b, %H:%M}   ·   {duration(row.duration_secs)}",
        )
        excerpt = " ".join(row.text.split()) or "Transcription in progress…"
        metrics = painter.fontMetrics()
        width = rect.width() - 36
        first = metrics.elidedText(excerpt, Qt.TextElideMode.ElideRight, width)
        if first.endswith("…"):
            # Wrap at a word boundary and reserve the second line for the remainder.
            cut = max(1, len(first) - 1)
            word_boundary = excerpt.rfind(" ", 0, cut)
            if word_boundary > 0:
                cut = word_boundary
            first, rest = excerpt[:cut], excerpt[cut:].strip()
            painter.drawText(QRect(x, y + 51, width, 18), first)
            painter.drawText(
                QRect(x, y + 68, width, 18),
                metrics.elidedText(rest, Qt.TextElideMode.ElideRight, width),
            )
        else:
            painter.drawText(QRect(x, y + 51, width, 18), excerpt)
        painter.restore()

    def sizeHint(self, option, index):
        return QSize(280, 116)


class TimelineDelegate(QStyledItemDelegate):
    def sizeHint(self, option, index):
        width = max(150, option.widget.viewport().width() - 124)
        font = QFont(option.font)
        font.setPixelSize(15)
        from PySide6.QtGui import QFontMetrics

        height = (
            QFontMetrics(font)
            .boundingRect(
                QRect(0, 0, width, 10000), Qt.TextFlag.TextWordWrap, index.data(ROW_DATA) or ""
            )
            .height()
        )
        return QSize(250, max(43, height + 22))

    def paint(self, painter, option, index):
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        rect = option.rect
        if option.state & QStyle.StateFlag.State_Selected:
            painter.fillRect(rect, QColor("#263b55"))
        painter.setPen(QPen(QColor("#34516d"), 1))
        painter.drawLine(rect.x() + 83, rect.top(), rect.x() + 83, rect.bottom())
        painter.setBrush(QColor("#187ce9"))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.drawEllipse(QRectF(rect.x() + 79, rect.y() + 18, 8, 8))
        font = QFont("monospace")
        font.setPixelSize(12)
        painter.setFont(font)
        painter.setPen(QColor("#999999"))
        painter.drawText(
            QRect(rect.x() + 5, rect.y() + 12, 65, 22),
            Qt.AlignmentFlag.AlignRight,
            timestamp(index.data(Qt.ItemDataRole.UserRole) or 0),
        )
        font = QFont(option.font)
        font.setPixelSize(15)
        painter.setFont(font)
        painter.setPen(QColor("#dddddd"))
        painter.drawText(
            rect.adjusted(102, 12, -20, -6), Qt.TextFlag.TextWordWrap, index.data(ROW_DATA) or ""
        )
        if option.state & QStyle.StateFlag.State_HasFocus:
            painter.setPen(QPen(QColor("#0a84ff"), 1))
            painter.drawRect(rect.adjusted(1, 1, -1, -1))
        painter.restore()


def add_segment(widget, start, text):
    item = QListWidgetItem(text)
    item.setData(Qt.ItemDataRole.UserRole, start)
    item.setData(ROW_DATA, text)
    item.setToolTip("Activate to seek to this sentence in the source media")
    index = 0
    while (
        index < widget.count() and (widget.item(index).data(Qt.ItemDataRole.UserRole) or 0) <= start
    ):
        index += 1
    widget.insertItem(index, item)
    return item


def empty_state(title, description, symbol="document"):
    widget = QWidget()
    layout = QVBoxLayout(widget)
    layout.addStretch()
    image = QLabel()
    image.setPixmap(icon(symbol, "#515151", 58).pixmap(58, 58))
    image.setAlignment(Qt.AlignmentFlag.AlignCenter)
    layout.addWidget(image)
    layout.addSpacing(15)
    heading = label(title, "section")
    heading.setAlignment(Qt.AlignmentFlag.AlignCenter)
    heading.setStyleSheet("color: #999999;")
    layout.addWidget(heading)
    text = label(description)
    text.setWordWrap(True)
    text.setAlignment(Qt.AlignmentFlag.AlignCenter)
    layout.addWidget(text)
    layout.addStretch()
    return widget


class LevelMeter(QWidget):
    """Displays measured microphone RMS; it never animates invented activity."""

    def __init__(self):
        super().__init__()
        self.level = 0.0
        self.setFixedSize(36, 20)
        self.setAccessibleName("Microphone level")

    def set_level(self, level):
        self.level = max(0, min(1, level)) if math.isfinite(level) else 0
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(Qt.PenStyle.NoPen)
        for index in range(5):
            height = 3 + self.level * (16 - abs(index - 2) * 4)
            painter.setBrush(QColor("#ff494c"))
            painter.drawRoundedRect(QRectF(index * 7, (20 - height) / 2, 3, height), 1.5, 1.5)


class RecordingOverlay(QWidget):
    stop_requested = Signal()
    open_requested = Signal()

    def __init__(self, parent):
        super().__init__(
            parent,
            Qt.WindowType.Tool
            | Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.WindowDoesNotAcceptFocus,
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setWindowTitle("Parakatt recording")
        self.setFixedSize(530, 114)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(22, 17, 22, 14)
        top = QHBoxLayout()
        dot = QLabel("●")
        dot.setStyleSheet("color: #ff494c; font-size: 23px;")
        top.addWidget(dot)
        self.meter = LevelMeter()
        top.addWidget(self.meter)
        self.state = label("Preparing…", "section")
        top.addWidget(self.state)
        top.addStretch()
        self.stop = QPushButton("■  Stop")
        self.stop.clicked.connect(self.stop_requested)
        top.addWidget(self.stop)
        layout.addLayout(top)
        self.help = label("Press shortcut to stop · Click to open transcript")
        layout.addWidget(self.help)
        bottom = QHBoxLayout()
        self.device = label("System default microphone")
        bottom.addWidget(self.device)
        bottom.addStretch()
        self.model = label("Loading speech model…")
        bottom.addWidget(self.model)
        layout.addLayout(bottom)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(QPen(QColor("#494949"), 1))
        painter.setBrush(QColor("#252627"))
        painter.drawRoundedRect(QRectF(0.5, 0.5, self.width() - 1, self.height() - 1), 18, 18)
        from PySide6.QtGui import QLinearGradient

        gradient = QLinearGradient(0, 0, self.width(), 0)
        gradient.setColorAt(0, QColor("#ff494c"))
        gradient.setColorAt(1, QColor("#bd7a28"))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(gradient)
        painter.drawRoundedRect(QRectF(12, 0, self.width() - 24, 3), 1, 1)

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.open_requested.emit()


class RecordingWindow(QDialog):
    stop_requested = Signal()
    pause_requested = Signal()
    discard_requested = Signal()

    def __init__(self, parent):
        super().__init__(parent, Qt.WindowType.Window)
        self.setWindowTitle("Meeting Transcription")
        self.setObjectName("recordingWindow")
        self.resize(880, 690)
        self.setMinimumSize(640, 480)
        self.active = False
        self.paused = False
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        header = QFrame()
        header.setObjectName("detailHeader")
        row = QHBoxLayout(header)
        row.setContentsMargins(20, 18, 20, 18)
        dot = QLabel("●")
        dot.setStyleSheet("color: #ff494c; font-size: 24px;")
        row.addWidget(dot)
        text = QVBoxLayout()
        self.state = label("Preparing…", "section")
        self.status = label("Loading speech model…")
        text.addWidget(self.state)
        text.addWidget(self.status)
        row.addLayout(text)
        row.addStretch()
        self.source = label("Mic + system audio", "badge")
        row.addWidget(self.source)
        layout.addWidget(header)
        tabs = QHBoxLayout()
        tabs.setContentsMargins(20, 12, 20, 12)
        tabs.addWidget(QLabel("Text"))
        self.view = SegmentedControl(["Processed text", "Recognized timeline"])
        tabs.addWidget(self.view, 1)
        layout.addLayout(tabs)
        self.pages = QStackedWidget()
        waiting = empty_state("Listening…", "Text will appear after the first audio batch.", "wave")
        self.wait_description = waiting.findChildren(QLabel)[-1]
        wait_layout = waiting.layout()
        progress_group = QWidget()
        group = QVBoxLayout(progress_group)
        group.setContentsMargins(100, 0, 100, 60)
        self.batch_label = label("First batch")
        group.addWidget(self.batch_label)
        self.progress = QProgressBar()
        self.progress.setTextVisible(False)
        group.addWidget(self.progress)
        wait_layout.insertWidget(wait_layout.count() - 1, progress_group)
        self.pages.addWidget(waiting)
        self.text = QTextEdit()
        self.text.setObjectName("liveText")
        self.text.setReadOnly(True)
        self.text.document().setDocumentMargin(24)
        self.pages.addWidget(self.text)
        self.timeline = QListWidget()
        self.timeline.setObjectName("timeline")
        self.timeline.setItemDelegate(TimelineDelegate(self.timeline))
        self.pages.addWidget(self.timeline)
        self.view.changed.connect(self.update_view)
        layout.addWidget(self.pages, 1)
        self.preview = label("")
        self.preview.setWordWrap(True)
        self.preview.setContentsMargins(20, 0, 20, 6)
        layout.addWidget(self.preview)
        self.preview.hide()
        footer = QFrame()
        footer.setObjectName("toolbar")
        row = QHBoxLayout(footer)
        row.setContentsMargins(20, 12, 20, 12)
        self.pause = QPushButton("Ⅱ  Pause")
        self.pause.clicked.connect(self.pause_requested)
        row.addWidget(self.pause)
        self.stop = QPushButton("■  Stop")
        self.stop.setProperty("role", "danger")
        self.stop.clicked.connect(self.stop_requested)
        row.addWidget(self.stop)
        row.addStretch()
        self.discard = QPushButton("Discard")
        self.discard.setIcon(icon("trash"))
        self.discard.clicked.connect(self.discard_requested)
        row.addWidget(self.discard)
        layout.addWidget(footer)

    def update_view(self, _index=0):
        has_text = bool(self.text.toPlainText())
        self.pages.setCurrentIndex((2 if self.view.currentIndex() else 1) if has_text else 0)

    def reset(self, meeting):
        self.active = True
        self.paused = False
        self.setWindowTitle("Meeting Transcription" if meeting else "Voice Note")
        self.text.clear()
        self.timeline.clear()
        self.preview.clear()
        self.preview.hide()
        self.state.setText("Preparing…")
        self.wait_description.setText("Loading speech model…")
        self.pause.setText("Ⅱ  Pause")
        self.source.setText("Mic + system audio" if meeting else "Mic only")
        self.progress.setRange(0, 0)
        self.batch_label.setText("Preparing audio capture")
        self.pause.setEnabled(False)
        self.stop.setEnabled(True)
        self.discard.setEnabled(True)
        self.update_view()

    def update_clock(self, elapsed, chunk, ready):
        if ready:
            self.state.setText("Paused" if self.paused else "Recording")
            self.status.setText(f"{timestamp(elapsed)} · {self.mode_name}")
            self.pause.setEnabled(True)
            self.wait_description.setText(
                f"Parakatt transcribes in {chunk}s batches. You'll see text here shortly."
            )
            self.progress.setRange(0, chunk)
            self.progress.setValue(min(chunk, int(elapsed)))
            self.batch_label.setText(
                f"First batch · {max(0, chunk - int(elapsed))}s until processing"
                if elapsed < chunk
                else "Processing first batch…"
            )

    def closeEvent(self, event):
        # Closing this window leaves capture under the tray/shortcut's control.
        if self.active:
            self.hide()
            event.ignore()
        else:
            super().closeEvent(event)
