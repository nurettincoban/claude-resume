import AppKit
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if let path = Snapshot.outputPath {
            Snapshot.run(to: path)
            return
        }
        if arguments.contains("--dump") {
            Debug.dump()
            return
        }
        if let index = arguments.firstIndex(of: "--resume"), index + 1 < arguments.count {
            Debug.resume(arguments[index + 1])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var keyMonitor: Any?
    private var lastClose = Date.distantPast
    private let store = SessionStore.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.setAccessibilityLabel("Claude conversations")
        updateIcon()

        let host = NSHostingView(rootView: PanelView().environment(store))
        panel = FloatingPanel(content: host, size: panelSize)
        panel.onClose = { [weak self] in self?.lastClose = Date() }
        observePreview()
        NotificationCenter.default.addObserver(forName: .promptDidClose, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.panel.makeKeyAndOrderFront(nil)
            }
        }

        store.onLaunch = { [weak self] in self?.closePanel() }
        store.onError = { [weak self] in self?.showPanel() }
        store.start()
        observeBusyState()

        HotKey.shared.action = { [weak self] in self?.togglePanel() }
        HotKey.shared.setEnabled(UserDefaults.standard.bool(forKey: Prefs.hotKey))
        installKeyMonitor()

        Notifier.shared.start()
        Notifier.shared.onOpen = { [weak self] id in
            guard let self, let session = self.store.session(id) else { return }
            self.store.open(session)
        }
        if UserDefaults.standard.bool(forKey: Prefs.notifications) { Notifier.shared.requestPermission() }

        // Show the panel on first launch (and with --show) so it's clear where the app lives.
        if CommandLine.arguments.contains("--show") || !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showPanel() }
        }
    }

    // MARK: Status item

    private func observeBusyState() {
        withObservationTracking { _ = store.anyBusy } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateIcon()
                self?.observeBusyState()
            }
        }
    }

    private func updateIcon() {
        statusItem.button?.image = StatusIcon.render(badge: store.anyBusy)
        statusItem.button?.toolTip = store.anyBusy ? "Claude is working" : "Claude conversations"
    }

    // MARK: Panel

    private var panelSize: NSSize {
        NSSize(width: Theme.listWidth + (store.previewOpen ? Theme.previewWidth + 1 : 0), height: Theme.height)
    }

    /// Widens the panel for the preview pane, keeping the list where it was.
    private func observePreview() {
        withObservationTracking { _ = store.previewOpen } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                var frame = self.panel.frame
                frame.size = self.panelSize
                if let visible = self.panel.screen?.visibleFrame, frame.maxX > visible.maxX - 8 {
                    frame.origin.x = visible.maxX - 8 - frame.width
                }
                self.panel.setFrame(frame, display: true)
                self.observePreview()
            }
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else if Date().timeIntervalSince(lastClose) > 0.25 {
            // A click on the status item first resigns the panel; don't reopen it straight away.
            showPanel()
        }
    }

    private func showPanel() {
        store.refresh()
        KeyboardState.lastMoveWasKeyboard = false
        if store.query.isEmpty { store.selection = store.visible.first?.id }
        panel.setFrame(NSRect(origin: origin(for: panelSize), size: panelSize), display: false)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        NotificationCenter.default.post(name: .panelDidOpen, object: nil)
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        lastClose = Date()
    }

    /// Just under the status item, kept on screen; centred near the top when the item is hidden.
    private func origin(for size: NSSize) -> NSPoint {
        if let button = statusItem.button, let window = button.window,
           let screen = window.screen, window.frame.maxY > screen.visibleFrame.maxY - 1 {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = screen.visibleFrame
            // Centre the list (not the preview) under the icon.
            let x = min(max(frame.midX - Theme.listWidth / 2, visible.minX + 8), visible.maxX - size.width - 8)
            return NSPoint(x: x, y: frame.minY - size.height - 6)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        return NSPoint(x: visible.midX - Theme.listWidth / 2, y: visible.maxY - size.height - 80)
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 125: // ↓
            KeyboardState.lastMoveWasKeyboard = true
            store.moveSelection(by: 1)
        case 126: // ↑
            KeyboardState.lastMoveWasKeyboard = true
            store.moveSelection(by: -1)
        case 36, 76: // ↩, enter
            guard let session = store.selectedSession else { return true }
            if flags.contains(.option) {
                store.open(session, fork: true)
            } else if flags.contains(.command) {
                store.open(session, placement: .window)
            } else {
                store.open(session)
            }
        case 124 where flags.isDisjoint(with: [.command, .option, .shift]) && cursorAtEnd: // →
            store.previewOpen = true
        case 123 where store.previewOpen && flags.isDisjoint(with: [.command, .option, .shift]) && cursorAtStart: // ←
            store.previewOpen = false
        case 51 where flags == .command: // ⌘⌫
            if let session = store.selectedSession { store.toggleHidden(session) }
        case 48: // ⇥
            store.filter = store.filter == .all ? .running : .all
        case 53: // esc
            if !store.query.isEmpty {
                store.query = ""
            } else if store.previewOpen {
                store.previewOpen = false
            } else {
                closePanel()
            }
        default:
            guard flags == .command, let key = event.charactersIgnoringModifiers else { return false }
            switch key {
            case "q": NSApp.terminate(nil)
            case "w": closePanel()
            case "r": store.refresh()
            case "p": if let session = store.selectedSession { store.togglePin(session) }
            case "e": if let session = store.selectedSession { Prompts.rename(session, store: store) }
            case "1": store.grouping = .date
            case "2": store.grouping = .project
            case "3": store.grouping = .cost
            case "c" where (panel.firstResponder as? NSTextView)?.selectedRange().length ?? 0 == 0:
                guard let session = store.selectedSession else { return false }
                store.copyCommand(session)
            // An accessory app has no Edit menu, so route the standard editing shortcuts by hand.
            case "c": NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            case "v": NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            case "x": NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            case "a": NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            case "z": NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            default: return false
            }
        }
        return true
    }

    /// The search field's text cursor, so ←/→ still move it inside typed text.
    private var fieldEditor: NSTextView? { panel.firstResponder as? NSTextView }

    private var cursorAtEnd: Bool {
        guard let editor = fieldEditor else { return true }
        let range = editor.selectedRange()
        return range.length == 0 && range.location >= (editor.string as NSString).length
    }

    private var cursorAtStart: Bool {
        guard let editor = fieldEditor else { return true }
        let range = editor.selectedRange()
        return range.length == 0 && range.location == 0
    }
}

/// A borderless panel that can take keyboard focus and closes when it loses it.
final class FloatingPanel: NSPanel {
    var onClose: (() -> Void)?

    init(content: NSView, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        effect.maskImage = .roundedMask(radius: 14)
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        contentView = effect

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: self,
                                               queue: .main) { [weak self] _ in
            guard let self, self.isVisible, NSApp.modalWindow == nil, !Prompts.isShowing else { return }
            self.orderOut(nil)
            self.onClose?()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension NSImage {
    /// A stretchable rounded-rect mask so the vibrancy material gets smooth corners.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The menu bar glyph: a speech bubble with a back arrow, plus a dot while a session is working.
enum StatusIcon {
    static func render(badge: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let symbol = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let s = symbol.size
            let origin = NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2)
            symbol.draw(in: NSRect(origin: origin, size: s))
            if badge {
                let dot = NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Command-line helpers for checking the parser and launcher without the UI.
@MainActor
enum Debug {
    static func dump() {
        let sessions = SessionScanner().scan()
        let live = LiveSessions.scan()
        for session in sessions {
            let status = live[session.id].map { "[\($0.status.rawValue)]" } ?? ""
            print("\(Fmt.age(session.lastActivity).padding(toLength: 7, withPad: " ", startingAt: 0)) \(session.id.prefix(8)) \(session.folderName) · \(session.branch ?? "-") · \(session.promptCount)p \(status)")
            print("        \(session.title)")
            let cost = session.cost.map(Fmt.usd) ?? "-"
            print("        \(cost) · \(Fmt.compact(session.tokens)) tokens · \(session.models.joined(separator: ", ")) · \(session.filesChanged.count) files · \(session.links.map(\.detail).joined(separator: ", "))")
            if let recap = session.recap { print("        recap: \(recap.prefix(110))") }
        }
        print("\(sessions.count) sessions, \(live.count) running")
    }

    static func resume(_ id: String) {
        guard let session = SessionScanner().scan().first(where: { $0.id.hasPrefix(id) }) else {
            print("No session matching \(id)"); exit(1)
        }
        do {
            let running = LiveSessions.scan()[session.id]
            let terminal = Terminal.selected()
            try Terminal.open(Terminal.resumeCommand(for: session), live: running, in: terminal,
                              placement: Prefs.currentPlacement, cwd: session.cwd)
            print(running == nil ? "Resumed \(session.id) in \(terminal.title)" : "Focused running session \(session.id)")
        } catch {
            print("Failed: \(error.localizedDescription)"); exit(1)
        }
    }
}
