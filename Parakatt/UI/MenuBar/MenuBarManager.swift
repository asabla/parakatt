import Cocoa
import Combine

/// Manages the menubar status item.
/// Click the icon to open the menu. Use "Start Recording" to record.
class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem
    private var appState: AppState
    private var cancellables = Set<AnyCancellable>()

    private var recordMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var lastTranscriptionMenuItem: NSMenuItem!
    private var modeMenuItems: [String: NSMenuItem] = [:]
    private var currentIconState: IconState = .idle

    private enum IconState: Equatable {
        case idle, loading, recording, processing
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

        menu.addItem(.separator())

        statusMenuItem = NSMenuItem(title: "Loading model...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        lastTranscriptionMenuItem = NSMenuItem(title: "No transcription yet", action: #selector(copyLastTranscription), keyEquivalent: "c")
        lastTranscriptionMenuItem.target = self
        lastTranscriptionMenuItem.isEnabled = false
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
            .removeDuplicates { a, b in a.0 == b.0 && a.1 == b.1 && a.2 == b.2 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isProcessing, isModelLoaded in
                guard let self else { return }

                let newState: IconState
                if isRecording { newState = .recording }
                else if isProcessing { newState = .processing }
                else if !isModelLoaded { newState = .loading }
                else { newState = .idle }

                if newState != self.currentIconState {
                    self.setIcon(newState)
                    self.currentIconState = newState
                }

                switch newState {
                case .recording:
                    self.statusMenuItem.title = "Recording..."
                    self.recordMenuItem.title = "Stop Recording"
                    self.recordMenuItem.isEnabled = true
                case .processing:
                    self.statusMenuItem.title = "Processing..."
                    self.recordMenuItem.title = "Processing..."
                    self.recordMenuItem.isEnabled = false
                case .loading:
                    self.statusMenuItem.title = "Loading model..."
                    self.recordMenuItem.title = "Start Recording"
                    self.recordMenuItem.isEnabled = false
                case .idle:
                    self.statusMenuItem.title = "Ready"
                    self.recordMenuItem.title = "Start Recording"
                    self.recordMenuItem.isEnabled = true
                }
            }
            .store(in: &cancellables)

        appState.$lastTranscription
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self, let text, !text.isEmpty else { return }
                let display = text.count > 50 ? String(text.prefix(47)) + "..." : text
                self.lastTranscriptionMenuItem.title = "Copy: \(display)"
                self.lastTranscriptionMenuItem.isEnabled = true
                self.lastTranscriptionMenuItem.toolTip = text
            }
            .store(in: &cancellables)
    }

    // MARK: - Icon

    private func setIcon(_ state: IconState) {
        guard let button = statusItem.button else { return }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setFill()

            switch state {
            case .idle, .loading:
                let mic = NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 6, height: 9), xRadius: 3, yRadius: 3)
                mic.fill()
                NSBezierPath(rect: NSRect(x: 8, y: 2, width: 2, height: 4)).fill()
                NSBezierPath(rect: NSRect(x: 5, y: 1, width: 8, height: 1.5)).fill()
                let arc = NSBezierPath()
                arc.lineWidth = 1.2
                arc.appendArc(withCenter: NSPoint(x: 9, y: 10), radius: 5.5, startAngle: 200, endAngle: 340)
                arc.stroke()

            case .recording:
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: 6.5, y: 6, width: 5, height: 8), xRadius: 2.5, yRadius: 2.5).fill()

            case .processing:
                let w: CGFloat = 2; let g: CGFloat = 1.5
                let heights: [CGFloat] = [6, 10, 14, 10, 6]
                var x: CGFloat = 2
                for h in heights {
                    NSBezierPath(roundedRect: NSRect(x: x, y: (18-h)/2, width: w, height: h), xRadius: 1, yRadius: 1).fill()
                    x += w + g
                }
            }
            return true
        }
        image.isTemplate = (state == .idle || state == .loading)
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

    @objc private func runDiagnostic() {
        appState.runDiagnostic()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
