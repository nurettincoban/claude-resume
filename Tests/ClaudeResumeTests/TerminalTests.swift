import AppKit
import Foundation
import Testing
@testable import ClaudeResume

@Suite("Terminal selection and routing")
struct TerminalTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "ClaudeResumeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func terminalPreferenceDefaultsToITermAndKeepsPlacement() {
        withDefaults { defaults in
            defaults.set("window", forKey: Prefs.placement)
            #expect(Terminal.selected(in: defaults) == .iterm)
            defaults.set("ghostty", forKey: Prefs.terminal)
            #expect(Terminal.selected(in: defaults) == .ghostty)
            #expect(defaults.string(forKey: Prefs.placement) == "window")
            defaults.set("unknown", forKey: Prefs.terminal)
            #expect(Terminal.selected(in: defaults) == .iterm)
        }
    }

    @Test func commandsPreserveCredentialsAndForkFlags() {
        let session = Session(id: "abc-123", title: "Example", firstPrompt: nil, lastPrompt: nil,
                              cwd: "/tmp/it's here", branch: nil, promptCount: 1, startedAt: nil,
                              lastActivity: Date(), transcriptURL: URL(fileURLWithPath: "/tmp/example.jsonl"))
        #expect(Terminal.resumeCommand(for: session) == "cd '/tmp/it'\\''s here' && claude --resume abc-123")
        #expect(Terminal.resumeCommand(for: session, fork: true, extraFlags: " --model opus ")
                == "cd '/tmp/it'\\''s here' && claude --resume abc-123 --fork-session --model opus")
        #expect(Terminal.resumeCommand(for: session) == ITerm.resumeCommand(for: session))
        #expect(!Terminal.resumeCommand(for: session).contains("env "))
    }

    @Test func manuallyStartedITermSessionsRetainTTYRouting() {
        #expect(Terminal.id(tty: "/dev/ttys012", terminalProgram: "iTerm.app", ghosttyID: nil)
                == .iterm(tty: "/dev/ttys012"))
        #expect(Terminal.id(tty: "/dev/ttys012", terminalProgram: nil, ghosttyID: nil)
                == .iterm(tty: "/dev/ttys012"))
    }

    @Test func inheritedGhosttyMarkersDoNotOverrideITerm() {
        #expect(Terminal.id(tty: "/dev/ttys012", terminalProgram: "iTerm.app", ghosttyID: "stale")
                == .iterm(tty: "/dev/ttys012"))
        #expect(Terminal.id(tty: "/dev/ttys012", terminalProgram: nil, ghosttyID: "stale")
                == .iterm(tty: "/dev/ttys012"))
    }

    @Test func ghosttyIDsCannotBeConfusedWithTTYs() {
        let id = Terminal.id(tty: "/dev/ttys012", terminalProgram: "ghostty", ghosttyID: "surface-1")
        #expect(id == .ghostty(terminalID: "surface-1"))
        #expect(id?.kind == .ghostty)
        #expect(id != .iterm(tty: "surface-1"))
        #expect(Terminal.id(tty: "/dev/ttys012", terminalProgram: "ghostty", ghosttyID: nil) == nil)
    }

    @Test func changingLaunchPreferenceDoesNotRetargetRunningSessions() {
        withDefaults { defaults in
            defaults.set("ghostty", forKey: Prefs.terminal)
            #expect(Terminal.selected(in: defaults) == .ghostty)
            #expect(Terminal.id(tty: "/dev/ttys012", terminalProgram: "iTerm.app", ghosttyID: nil)?.kind == .iterm)
            defaults.set("iterm", forKey: Prefs.terminal)
            #expect(Terminal.id(tty: "/dev/ttys012", terminalProgram: "ghostty", ghosttyID: "surface-1")?.kind == .ghostty)
        }
    }

    @Test func unlocatableRunningConversationNeverLaunchesADuplicate() {
        let live = LiveSession(sessionId: "example", pid: -1, status: .idle, cwd: nil)
        // An invalid pid has no terminal; the launch command must never be executed.
        #expect(throws: Terminal.Failure.self) {
            try Terminal.open("false", live: live, in: .ghostty, placement: .tab)
        }
    }

    @Test func ghosttyUsesConfiguredShellAndNativeInitialInput() {
        for placement in Terminal.Placement.allCases {
            let command = "cd '/tmp/space here' && claude --resume abc-123"
            let script = Ghostty.launchScript(command: command, placement: placement,
                                             cwd: "/tmp/space here", marker: "launch-marker")
            #expect(script.contains("set initial input of cfg to \(ITerm.appleScriptString(command)) & return"))
            #expect(script.contains("set environment variables of cfg to {\"CLAUDE_RESUME_TERMINAL=launch-marker\"}"))
            #expect(script.contains("set initial working directory of cfg to \"/tmp/space here\""))
            #expect(!script.contains("set command of cfg"))
            #expect(!script.contains("/bin/zsh"))
            #expect(!script.contains("env -u"))
            #expect(script.contains("if \(placement == .window ? "true" : "false") or (count of windows) is 0 then"))
        }
        #expect(!Ghostty.launchScript(command: "claude", placement: .tab, marker: "test")
            .contains("set initial working directory"))
    }

    @Test func ghosttyScriptEscapesQuotedPathsAndCommands() {
        let command = #"printf '%s' 'say "hi" \ bye'"#
        let cwd = #"/tmp/a "quoted" \ path"#
        let script = Ghostty.launchScript(command: command, placement: .window, cwd: cwd, marker: "test")
        #expect(script.contains(ITerm.appleScriptString(command)))
        #expect(script.contains(ITerm.appleScriptString(cwd)))
    }

    @Test(.enabled(if: NSWorkspace.shared.urlForApplication(withBundleIdentifier: Ghostty.bundleId) != nil,
                   "Compiling Ghostty AppleScript requires its installed scripting dictionary"))
    func ghosttyScriptsCompileWithoutExecuting() throws {
        for placement in Terminal.Placement.allCases {
            let source = Ghostty.launchScript(command: #"cd '/tmp/a' && claude --resume example --model "opus""#,
                                             placement: placement, cwd: #"/tmp/quoted "path""#, marker: "test-marker")
            let script = try #require(NSAppleScript(source: source))
            var error: NSDictionary?
            let compiled = script.compileAndReturnError(&error)
            #expect(compiled, "\(String(describing: error))")
        }
    }

    @Test func ghosttyPrunesClosedTerminalsAndRemovesClosedMappings() {
        withDefaults { defaults in
            defaults.set(["old": "closed", "keep": "open"], forKey: Ghostty.mappingsKey)
            Ghostty.remember(marker: "new", terminalID: "new-id", existingIDs: ["open", "new-id"], defaults: defaults)
            #expect(Ghostty.terminalID(for: "old", defaults: defaults) == nil)
            #expect(Ghostty.terminalID(for: "keep", defaults: defaults) == "open")
            #expect(Ghostty.terminalID(for: "new", defaults: defaults) == "new-id")
            Ghostty.forget(terminalID: "new-id", defaults: defaults)
            #expect(Ghostty.terminalID(for: "new", defaults: defaults) == nil)
            #expect(Ghostty.terminalID(for: "keep", defaults: defaults) == "open")
        }
    }

    @Test func ghosttyMappingStorageIsBounded() {
        withDefaults { defaults in
            let ids = Set((0..<300).map { "surface-\($0)" })
            for index in 0..<300 {
                Ghostty.remember(marker: "marker-\(index)", terminalID: "surface-\(index)", existingIDs: ids, defaults: defaults)
            }
            #expect(defaults.dictionary(forKey: Ghostty.mappingsKey)?.count == Ghostty.maximumMappings)
            #expect(Ghostty.terminalID(for: "marker-299", defaults: defaults) == "surface-299")
            #expect(Ghostty.terminalID(for: "unknown", defaults: defaults) == nil)
        }
    }

    private func processBytes(arguments: [String], environment: [String]) -> [UInt8] {
        var argc = Int32(arguments.count).littleEndian
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/usr/local/bin/claude".utf8) + [0, 0, 0]
        for string in arguments + environment { bytes += Array(string.utf8) + [0] }
        return bytes + [0]
    }

    @Test func environmentParsingSkipsArgumentsAndMatchesWholeNames() {
        let bytes = processBytes(arguments: ["claude", "CLAUDE_RESUME_TERMINAL=argument-is-not-env", ""],
                                 environment: ["CLAUDE_RESUME_TERMINAL_EXTRA=wrong", "TERM_PROGRAM=ghostty",
                                               "CLAUDE_RESUME_TERMINAL=correct=marker", "EMPTY="])
        #expect(LiveSessions.environmentValue("CLAUDE_RESUME_TERMINAL", in: bytes) == "correct=marker")
        #expect(LiveSessions.environmentValue("TERM_PROGRAM", in: bytes) == "ghostty")
        #expect(LiveSessions.environmentValue("EMPTY", in: bytes) == "")
        #expect(LiveSessions.environmentValue("MISSING", in: bytes) == nil)
    }

    @Test func malformedProcessDataDoesNotYieldMarkersOrCrash() {
        for bytes: [UInt8] in [[], [1], [0, 0, 0, 0, 0], [255, 255, 255, 255, 0],
                               [1, 0, 0, 0, 65], [1, 0, 0, 0, 0, 0]] {
            #expect(LiveSessions.environmentValue("CLAUDE_RESUME_TERMINAL", in: bytes) == nil)
        }
        let valid = processBytes(arguments: ["claude"], environment: ["CLAUDE_RESUME_TERMINAL=test"])
        #expect(LiveSessions.environmentValue("CLAUDE_RESUME_TERMINAL", in: Array(valid.dropLast(2))) == nil)
    }
}
