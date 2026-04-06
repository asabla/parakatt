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
@MainActor
class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem
    private var appState: AppState
    private var cancellables = Set<AnyCancellable>()

    private var recordMenuItem: NSMenuItem!
    private var meetingMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var lastTranscriptionMenuItem: NSMenuItem!
    private var modeMenuItems: [String: NSMenuItem] = [:]
    private var deviceMenu: NSMenu?
    private var selectedDeviceUID: String?  // nil = system default
    private var audioSourceMenu: NSMenu?
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

        // Input device submenu (rebuilt dynamically when opened)
        let devMenu = NSMenu()
        devMenu.delegate = self
        deviceMenu = devMenu
        rebuildDeviceMenu()

        let deviceMenuItem = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        deviceMenuItem.submenu = devMenu
        menu.addItem(deviceMenuItem)

        // Audio source submenu (for meeting system audio capture)
        if #available(macOS 14.2, *) {
            let srcMenu = NSMenu()
            srcMenu.delegate = self
            audioSourceMenu = srcMenu
            rebuildAudioSourceMenu()

            let srcMenuItem = NSMenuItem(title: "Meeting Audio Source", action: nil, keyEquivalent: "")
            srcMenuItem.submenu = srcMenu
            menu.addItem(srcMenuItem)
        }

        menu.addItem(.separator())

        let historyItem = NSMenuItem(title: "Transcription History...", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Help & Diagnostics submenu
        let helpMenu = NSMenu()

        let diagItem = NSMenuItem(title: "Run Audio Diagnostic", action: #selector(runDiagnostic), keyEquivalent: "")
        diagItem.target = self
        helpMenu.addItem(diagItem)

        if #available(macOS 14.2, *) {
            let sysDiagItem = NSMenuItem(title: "Run System Audio Diagnostic", action: #selector(runSystemAudioDiagnostic), keyEquivalent: "")
            sysDiagItem.target = self
            helpMenu.addItem(sysDiagItem)
        }

        helpMenu.addItem(.separator())

        let openLogsItem = NSMenuItem(title: "Open Log File", action: #selector(openLogFile), keyEquivalent: "")
        openLogsItem.target = self
        helpMenu.addItem(openLogsItem)

        let helpMenuItem = NSMenuItem(title: "Help & Diagnostics", action: nil, keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        menu.addItem(helpMenuItem)

        menu.addItem(.separator())

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
            .combineLatest(appState.$isDownloading)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nested, isDownloading in
                let (inner, isMeetingActive) = nested
                let (isRecording, isProcessing, isModelLoaded) = inner
                guard let self else { return }

                let newState: IconState
                if isMeetingActive { newState = .meeting }
                else if isRecording { newState = .recording }
                else if isProcessing { newState = .processing }
                else if isDownloading { newState = .loading }
                else if !isModelLoaded { newState = .loading }
                else { newState = .idle }

                if newState != self.currentIconState {
                    self.setIcon(newState)
                    self.currentIconState = newState
                }

                switch newState {
                case .meeting:
                    if let sourceName = self.appState.selectedAudioSourceName {
                        self.statusMenuItem.title = "Meeting in progress (\(sourceName))..."
                    } else {
                        self.statusMenuItem.title = "Meeting in progress..."
                    }
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
                    if isDownloading, let progress = self.appState.downloadProgress,
                       progress.bytesTotal > 0 {
                        let pct = Int(Double(progress.bytesDownloaded) / Double(progress.bytesTotal) * 100)
                        self.statusMenuItem.title = "Downloading model... \(pct)%"
                    } else if isDownloading {
                        self.statusMenuItem.title = "Downloading model..."
                    } else {
                        self.statusMenuItem.title = "Loading model..."
                    }
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
        let uid = sender.representedObject as? String
        selectedDeviceUID = uid
        appState.setInputDevice(uid: uid)
        rebuildDeviceMenu()
    }

    @objc private func selectAudioSource(_ sender: NSMenuItem) {
        if sender.tag == 0 {
            // "All System Audio"
            appState.selectedAudioSourcePID = nil
            appState.selectedAudioSourceName = nil
            appState.setPreferredAudioSource(bundleId: nil)
        } else {
            appState.selectedAudioSourcePID = pid_t(sender.tag)
            appState.selectedAudioSourceName = sender.title
            // Persist the bundle ID (look it up from running apps)
            let apps = AudioSourceService.listRunningAudioApps()
            if let app = apps.first(where: { $0.id == pid_t(sender.tag) }) {
                appState.setPreferredAudioSource(bundleId: app.bundleIdentifier)
            }
        }
        rebuildAudioSourceMenu()
    }

    private func rebuildAudioSourceMenu() {
        guard let menu = audioSourceMenu else { return }
        menu.removeAllItems()

        // "All System Audio" option
        let allItem = NSMenuItem(title: "All System Audio", action: #selector(selectAudioSource(_:)), keyEquivalent: "")
        allItem.target = self
        allItem.tag = 0
        allItem.state = appState.selectedAudioSourcePID == nil ? .on : .off
        menu.addItem(allItem)

        menu.addItem(.separator())

        // Running audio apps
        let apps = AudioSourceService.listRunningAudioApps()
        if apps.isEmpty {
            let emptyItem = NSMenuItem(title: "No audio apps running", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for app in apps {
                let item = NSMenuItem(title: app.name, action: #selector(selectAudioSource(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(app.id)
                item.state = appState.selectedAudioSourcePID == app.id ? .on : .off
                if let icon = app.icon {
                    let resized = NSImage(size: NSSize(width: 16, height: 16))
                    resized.lockFocus()
                    icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                    resized.unlockFocus()
                    item.image = resized
                }
                menu.addItem(item)
            }
        }
    }

    private func rebuildDeviceMenu() {
        guard let menu = deviceMenu else { return }
        menu.removeAllItems()

        // System Default option
        let defaultItem = NSMenuItem(title: "System Default", action: #selector(selectInputDevice(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = nil as String?
        defaultItem.state = selectedDeviceUID == nil ? .on : .off
        menu.addItem(defaultItem)
        menu.addItem(.separator())

        let devices = AudioCaptureService.listInputDevices()
        for device in devices {
            let label = device.isDefault ? "\(device.name) (current default)" : device.name
            let item = NSMenuItem(title: label, action: #selector(selectInputDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = selectedDeviceUID == device.uid ? .on : .off
            menu.addItem(item)
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
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

    @available(macOS 14.2, *)
    @objc private func runSystemAudioDiagnostic() {
        appState.runSystemAudioDiagnostic()
    }

    @objc private func openLogFile() {
        let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Parakatt/logs")
        if let logDir {
            // Open the log directory in Finder
            NSWorkspace.shared.open(logDir)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension MenuBarManager: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === deviceMenu {
            rebuildDeviceMenu()
        } else if menu === audioSourceMenu {
            rebuildAudioSourceMenu()
        }
    }
}
