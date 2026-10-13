import AppKit
import SwiftUI

/// Renders the panel to a PNG without a menu bar, for README screenshots and layout checks:
/// `ClaudeResume --snapshot out.png [--demo] [--dark] [--query text]`
enum Snapshot {
    static let outputPath: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    static var isActive: Bool { outputPath != nil }

    @MainActor static func run(to path: String) {
        let arguments = CommandLine.arguments
        let dark = arguments.contains("--dark")
        let store: SessionStore
        if arguments.contains("--demo") {
            store = SessionStore(demo: Demo.sessions, live: Demo.live, pinned: ["a9"])
        } else {
            let sessions = SessionScanner().scan()
            store = SessionStore(demo: sessions, live: LiveSessions.scan())
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
        store.previewOpen = arguments.contains("--preview")

        let view = PanelView()
            .environment(store)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .compositingGroup()
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(32)
            .environment(\.colorScheme, dark ? .dark : .light)

        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let renderer = ImageRenderer(content: view)
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
                            tokens: Int(cost * 520_000), outputTokens: Int(cost * 9_000), cost: cost,
                            models: ["Opus 5.5"])
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
            session("a3", "Add dark mode to the settings screen", "mobile-app", "main", 15, 2 * 3600, cost: 3.06),
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
        ]
    }
}
