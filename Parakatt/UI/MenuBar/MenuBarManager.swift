import Cocoa
import Combine
import SwiftUI

/// A menu-item view that adapts to the menu width without expanding it.
private class TranscriptionItemView: NSView {
    let label = NSTextField(labelWithString: "No transcription yet")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.font = .menuFont(ofSize: 0)
        label.textColor = .disabledControlTextColor
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, item.isEnabled,
              let action = item.action, let target = item.target else { return }
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: target, from: item)
    }
}

/// Manages the menubar status item.
/// Click the icon to open the menu. Use "Start Recording" to record.
class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem
    private var appState: AppState
    private var cancellables = Set<AnyCancellable>()

    private var recordMenuItem: NSMenuItem!
    private var meetingMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var lastTranscriptionMenuItem: NSMenuItem!
    private var modeMenuItems: [String: NSMenuItem] = [:]
    private var currentIconState: IconState = .idle
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    private enum IconState: Equatable {
        case idle, loading, recording, processing, meeting
    }

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        setupStatusItem()
        observeState()
    }

    private func setupStatusItem() {
        setIcon(.idle)

        let menu = NSMenu()

        recordMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        recordMenuItem.target = self
        menu.addItem(recordMenuItem)

        meetingMenuItem = NSMenuItem(title: "Start Meeting Transcription", action: #selector(toggleMeeting), keyEquivalent: "m")
        meetingMenuItem.target = self
        menu.addItem(meetingMenuItem)

        menu.addItem(.separator())

        statusMenuItem = NSMenuItem(title: "Loading model...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        lastTranscriptionMenuItem = NSMenuItem(title: "", action: #selector(copyLastTranscription), keyEquivalent: "c")
        lastTranscriptionMenuItem.target = self
        lastTranscriptionMenuItem.isEnabled = false
        lastTranscriptionMenuItem.view = TranscriptionItemView()
        menu.addItem(lastTranscriptionMenuItem)

        menu.addItem(.separator())

        // Mode submenu
        let modeMenu = NSMenu()
        for mode in ["Dictation", "Clean", "Email", "Code"] {
            let item = NSMenuItem(title: mode, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.lowercased()
            modeMenuItems[mode.lowercased()] = item
            modeMenu.addItem(item)
        }
        modeMenuItems["dictation"]?.state = .on
        let modeMenuItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeMenuItem.submenu = modeMenu
        menu.addItem(modeMenuItem)

        // Input device submenu
        let deviceMenu = NSMenu()
        let devices = AudioCaptureService.listInputDevices()
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectInputDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            if device.uid.contains("BuiltIn") { item.state = .on } // default to built-in
            deviceMenu.addItem(item)
        }
        let deviceMenuItem = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        deviceMenuItem.submenu = deviceMenu
        menu.addItem(deviceMenuItem)

        menu.addItem(.separator())

        let historyItem = NSMenuItem(title: "Transcription History...", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let diagItem = NSMenuItem(title: "Run Diagnostic", action: #selector(runDiagnostic), keyEquivalent: "d")
        diagItem.target = self
        menu.addItem(diagItem)

        let quitItem = NSMenuItem(title: "Quit Parakatt", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - State observation

    private func observeState() {
        appState.$isRecording
            .combineLatest(appState.$isProcessing, appState.$isModelLoaded)
            .combineLatest(appState.$isMeetingActive)
            .removeDuplicates { a, b in a.0.0 == b.0.0 && a.0.1 == b.0.1 && a.0.2 == b.0.2 && a.1 == b.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] combined, isMeetingActive in
                let (isRecording, isProcessing, isModelLoaded) = combined
                guard let self else { return }

                let newState: IconState
                if isMeetingActive { newState = .meeting }
                else if isRecording { newState = .recording }
                else if isProcessing { newState = .processing }
                else if !isModelLoaded { newState = .loading }
                else { newState = .idle }

                if newState != self.currentIconState {
                    self.setIcon(newState)
                    self.currentIconState = newState
                }

                switch newState {
                case .meeting:
                    self.statusMenuItem.title = "Meeting in progress..."
                    self.recordMenuItem.isEnabled = false
                    self.meetingMenuItem.title = "Stop Meeting"
                    self.meetingMenuItem.isEnabled = true
                case .recording:
                    self.statusMenuItem.title = "Recording..."
                    self.recordMenuItem.title = "Stop Recording"
                    self.recordMenuItem.isEnabled = true
                    self.meetingMenuItem.isEnabled = false
                case .processing:
                    self.statusMenuItem.title = "Processing..."
                    self.recordMenuItem.title = "Processing..."
                    self.recordMenuItem.isEnabled = false
                    self.meetingMenuItem.isEnabled = false
                case .loading:
                    self.statusMenuItem.title = "Loading model..."
                    self.recordMenuItem.title = "Start Recording"
                    self.recordMenuItem.isEnabled = false
                    self.meetingMenuItem.isEnabled = false
                case .idle:
                    self.statusMenuItem.title = "Ready"
                    self.recordMenuItem.title = "Start Recording"
                    self.recordMenuItem.isEnabled = true
                    self.meetingMenuItem.title = "Start Meeting Transcription"
                    self.meetingMenuItem.isEnabled = true
                }
            }
            .store(in: &cancellables)

        appState.$lastTranscription
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self, let text, !text.isEmpty else { return }
                if let view = self.lastTranscriptionMenuItem.view as? TranscriptionItemView {
                    view.label.stringValue = "Copy: \(text)"
                    view.label.textColor = .controlTextColor
                    view.toolTip = text
                }
                self.lastTranscriptionMenuItem.isEnabled = true
            }
            .store(in: &cancellables)
    }

    // MARK: - Icon

    private func setIcon(_ state: IconState) {
        guard let button = statusItem.button else { return }

        let name: String
        switch state {
        case .idle, .loading:
            name = "MenuBarIdle"
        case .recording, .meeting:
            name = "MenuBarRecording"
        case .processing:
            name = "MenuBarProcessing"
        }

        let bundle = Bundle(for: MenuBarManager.self)
        guard let image = bundle.image(forResource: name) else {
            assertionFailure("Missing menu bar icon: \(name)")
            return
        }

        image.isTemplate = (state == .idle || state == .loading)
        image.size = NSSize(width: 22, height: 22)
        button.image = image
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        NSLog("[Parakatt] Menu: toggleRecording (isRecording=%d)", appState.isRecording ? 1 : 0)
        if appState.isRecording {
            appState.stopRecording()
        } else {
            appState.startRecording()
        }
    }

    @objc private func toggleMeeting() {
        if #available(macOS 14.2, *) {
            if appState.isMeetingActive {
                appState.stopMeeting()
            } else {
                appState.startMeeting()
            }
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        for (key, item) in modeMenuItems { item.state = (key == mode) ? .on : .off }
        appState.activeMode = mode
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        if let menu = sender.menu {
            for item in menu.items { item.state = (item == sender) ? .on : .off }
        }
        appState.setInputDevice(uid: uid)
    }

    @objc private func copyLastTranscription() {
        if let text = appState.lastTranscription {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            NSLog("[Parakatt] Copied transcription to clipboard")
        }
    }

    @objc private func openHistory() {
        if let w = historyWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = TranscriptionHistoryView().environmentObject(appState)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcription History"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = window
    }

    @objc private func openSettings() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView().environmentObject(appState)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Parakatt Settings"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func runDiagnostic() {
        appState.runDiagnostic()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
