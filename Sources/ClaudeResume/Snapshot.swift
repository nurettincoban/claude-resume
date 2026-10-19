import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Renders the panel without a menu bar, for README screenshots and layout checks:
/// `ClaudeResume --snapshot out.png [--demo] [--dark] [--query text] [--group date|project|cost]
/// [--filter running] [--project name] [--select n | --select-id id] [--preview]`, or an animated demo
/// with `ClaudeResume --gif out.gif [--dark]`.
enum Snapshot {
    static let outputPath = argument("--snapshot")
    static let gifPath = argument("--gif")

    static var isActive: Bool { outputPath != nil || gifPath != nil }

    private static func argument(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @MainActor static func run(to path: String) {
        let arguments = CommandLine.arguments
        let dark = arguments.contains("--dark")
        let store: SessionStore
        if arguments.contains("--demo") {
            store = SessionStore(demo: Demo.sessions, live: Demo.live, pinned: ["a9"])
        } else {
            let profiles = ProfilePreferences.load()
            store = SessionStore(demo: ProfileScanner().scan(profiles), live: LiveSessions.scan(profiles: profiles))
        }
        if let index = arguments.firstIndex(of: "--query"), index + 1 < arguments.count {
            store.query = arguments[index + 1]
        }
        if let index = arguments.firstIndex(of: "--select"), index + 1 < arguments.count, let n = Int(arguments[index + 1]) {
            store.moveSelection(by: n)
        }
        if let index = arguments.firstIndex(of: "--group"), index + 1 < arguments.count,
           let grouping = Grouping(rawValue: arguments[index + 1]) {
            store.grouping = grouping
        }
        if argument("--filter") == "running" { store.filter = .running }
        if let name = argument("--project") {
            store.project = store.projects.first { ($0.path as NSString).lastPathComponent == name }?.path
        }
        if let id = argument("--select-id") { store.selection = id }
        store.previewOpen = arguments.contains("--preview")

        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let renderer = ImageRenderer(content: framed(store, dark: dark))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("Couldn't render the panel"); exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("Wrote \(path)")
        } catch {
            print("Couldn't write \(path): \(error.localizedDescription)"); exit(1)
        }
    }

    /// The panel with its rounded corners and shadow. With a `canvas`, it sits top-left on a solid
    /// background of that size, so every GIF frame has the same dimensions.
    @MainActor private static func framed(_ store: SessionStore, dark: Bool, canvas: CGSize? = nil) -> some View {
        let panel = PanelView()
            .environment(store)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .compositingGroup()
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(32)
        return Group {
            if let canvas {
                // GitHub's page colours, so the GIF blends into the README.
                let page = dark ? Color(red: 0.051, green: 0.067, blue: 0.090) : .white
                ZStack(alignment: .topLeading) {
                    page
                    panel
                }
                .frame(width: canvas.width, height: canvas.height)
            } else {
                panel
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    // MARK: GIF

    /// One step of the demo: what changes, and how long the result stays on screen.
    private struct Step {
        let hold: Double
        let change: @MainActor (SessionStore) -> Void
    }

    @MainActor static func gif(to path: String) {
        let dark = CommandLine.arguments.contains("--dark")
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let store = SessionStore(demo: Demo.sessions, live: Demo.live, pinned: ["a9"])
        let canvas = CGSize(width: Theme.listWidth + Theme.previewWidth + 1 + 64, height: Theme.height + 64)

        var steps: [Step] = [
            Step(hold: 1.8) { _ in },
            Step(hold: 0.5) { $0.moveSelection(by: 1) },
            Step(hold: 0.5) { $0.moveSelection(by: 1) },
            Step(hold: 2.6) { $0.previewOpen = true },
            Step(hold: 1.8) { $0.moveSelection(by: 1) },
            Step(hold: 0.6) { $0.previewOpen = false },
        ]
        let query = "chkout flw"
        for index in query.indices {
            let typed = String(query[...index])
            steps.append(Step(hold: 0.11) { $0.query = typed })
        }
        steps[steps.count - 1] = Step(hold: 2.4) { $0.query = query }
        steps += [
            Step(hold: 2.0) { $0.query = ""; $0.grouping = .project },
            Step(hold: 2.0) { $0.grouping = .date; $0.filter = .running },
            Step(hold: 0.4) { $0.filter = .all },
        ]

        let url = URL(fileURLWithPath: path) as CFURL
        guard let destination = CGImageDestinationCreateWithURL(url, UTType.gif.identifier as CFString, steps.count, nil) else {
            print("Couldn't create \(path)"); exit(1)
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for step in steps {
            step.change(store)
            let renderer = ImageRenderer(content: framed(store, dark: dark, canvas: canvas))
            renderer.scale = 2
            guard let frame = renderer.cgImage else { print("Couldn't render a frame"); exit(1) }
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: step.hold,
                    kCGImagePropertyGIFUnclampedDelayTime: step.hold,
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { print("Couldn't write \(path)"); exit(1) }
        print("Wrote \(path) (\(steps.count) frames)")
    }
}

/// Made-up sessions for screenshots, so real conversation titles never end up in the README.
enum Demo {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static var sessions: [Session] {
        let now = Date()
        func session(_ id: String, _ title: String, _ folder: String, _ branch: String?, _ prompts: Int,
                     _ ago: TimeInterval, cost: Double, recap: String? = nil, reply: String? = nil,
                     files: [String] = [], links: [SessionLink] = []) -> Session {
            var s = Session(id: id, title: title, firstPrompt: title, lastPrompt: title, cwd: home,
                            branch: branch, promptCount: prompts, startedAt: now.addingTimeInterval(-ago - 5400),
                            lastActivity: now.addingTimeInterval(-ago),
                            transcriptURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
                            recap: recap, lastReply: reply, filesChanged: files.map { "\(home)/\($0)" }, links: links,
                            tokens: Int(cost * 520_000), outputTokens: Int(cost * 9_000), estimatedCost: cost,
                            models: ["Opus 5.5"],
                            lastTurn: TurnSummary(duration: 252, edits: files.count + 1, errors: id == "a1" ? 1 : 0,
                                                  cost: cost / 9))
            s.displayPath = "~/code/\(folder)"
            return s
        }
        func mr(_ number: Int, _ repo: String) -> SessionLink {
            SessionLink(kind: .pullRequest, url: URL(string: "https://example.com/\(repo)/-/merge_requests/\(number)")!,
                        label: "!\(number)", detail: "Merge request !\(number) · \(repo)")
        }
        let artifact = SessionLink(kind: .artifact, url: URL(string: "https://example.com/artifact")!,
                                   label: "Checkout flow", detail: "Artifact · Checkout flow diagram")
        return [
            session("a1", "Refactor checkout flow into composable steps", "storefront", "feat/checkout-steps", 24, 40,
                    cost: 7.84,
                    recap: "You're splitting checkout into Address, Shipping and Payment steps. Address and Shipping are done and tested; Payment is next, after deciding where the saved-card logic lives.",
                    reply: "Address and Shipping are now separate step components, each with its own validation.\nAll 48 checkout tests pass. Next I'd move the saved-card lookup into PaymentStep so the parent no longer needs to know about cards. Want me to go ahead?",
                    files: ["src/checkout/AddressStep.tsx", "src/checkout/ShippingStep.tsx", "src/checkout/CheckoutFlow.tsx",
                            "src/checkout/steps.ts", "tests/checkout.test.ts"],
                    links: [mr(812, "storefront"), artifact]),
            session("a2", "Investigate flaky integration test in CI", "api-gateway", "fix/flaky-auth-test", 9, 600, cost: 2.31,
                    recap: "The auth test fails when two runs share a Redis key; I proposed per-run key prefixes.",
                    links: [mr(455, "api-gateway")]),
            session("a3", "Add dark mode to the settings screen", "mobile-app", "main", 15, 2 * 3600, cost: 3.06,
                    recap: "Dark mode colours are in place for Settings and Profile. Claude wants to rebuild the theme tokens before checking contrast on the remaining screens.",
                    reply: "The new colour tokens are wired into SettingsView and ProfileView.\nTo check they compile and meet contrast, I need to run `npm run build:tokens`. OK to run it?",
                    files: ["src/theme/tokens.ts", "src/screens/SettingsView.tsx", "src/screens/ProfileView.tsx"]),
            session("a4", "Write migration for the orders table", "storefront", "chore/orders-index", 6, 5 * 3600, cost: 0.92),
            session("a5", "Explain how the rate limiter works", "api-gateway", nil, 3, 26 * 3600, cost: 0.41),
            session("a6", "Design a plugin system for the CLI", "devtools", "spike/plugins", 31, 30 * 3600, cost: 11.2),
            session("a7", "Speed up the image pipeline", "media-service", "perf/thumbnails", 18, 3 * 86400, cost: 5.47),
            session("a8", "Draft the README for the open-source release", "devtools", "docs/readme", 7, 4 * 86400, cost: 1.18),
            session("a9", "Port the analytics dashboard to Swift Charts", "insights", "main", 42, 12 * 86400, cost: 18.6),
            session("b1", "Set up Playwright end-to-end tests", "storefront", "test/e2e", 12, 20 * 86400, cost: 4.02),
        ]
    }

    static var live: [String: LiveSession] {
        [
            "a1": LiveSession(sessionId: "a1", pid: 1, status: .idle, cwd: nil),
            "a2": LiveSession(sessionId: "a2", pid: 2, status: .busy, cwd: nil),
            "a3": LiveSession(sessionId: "a3", pid: 3, status: .waiting, cwd: nil, waitingFor: "permission to run Bash"),
        ]
    }
}
