import AppKit
import Foundation

/// Opens and focuses Claude Code sessions in iTerm2 through AppleScript.
enum ITerm {
    enum Placement: String, CaseIterable, Identifiable {
        case tab, window
        var id: String { rawValue }
        var title: String { self == .tab ? "New tab" : "New window" }
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let bundleId = "com.googlecode.iterm2"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    /// The shell command that resumes a session in its own folder.
    static func resumeCommand(for session: Session, fork: Bool = false, extraFlags: String = "") -> String {
        var parts = ["claude", "--resume", session.id]
        if fork { parts.append("--fork-session") }
        let flags = extraFlags.trimmingCharacters(in: .whitespaces)
        if !flags.isEmpty { parts.append(flags) }
        let claude = parts.joined(separator: " ")
        guard let cwd = session.cwd else { return claude }
        return "cd \(shellQuote(cwd)) && \(claude)"
    }

    /// POSIX single-quote escaping: `it's` becomes `'it'\''s'`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// AppleScript string literal.
    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs `command` in a fresh iTerm2 tab or window. When iTerm2 wasn't running, the window it
    /// opens at launch is used, so no empty tab is left behind.
    static func run(_ command: String, placement: Placement) throws {
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
        let open = placement == .window
            ? "set targetWindow to (create window with default profile)"
            : """
              if (count of windows) is 0 then
                  set targetWindow to (create window with default profile)
              else
                  set targetWindow to current window
                  tell targetWindow to create tab with default profile
              end if
              """
        let script = """
        tell application id "\(bundleId)"
            activate
            \(wasRunning ? "" : """
            repeat 50 times
                if (count of windows) > 0 then exit repeat
                delay 0.1
            end repeat
            """)
            \(wasRunning ? open : """
            if (count of windows) is 0 then
                set targetWindow to (create window with default profile)
            else
                set targetWindow to current window
            end if
            """)
            tell current session of targetWindow to write text \(appleScriptString(command))
        end tell
        """
        try execute(script)
    }

    /// Brings the iTerm2 session attached to `tty` to the front. Returns false if no tab has it.
    static func focus(tty: String) throws -> Bool {
        let script = """
        tell application id "\(bundleId)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is \(appleScriptString(tty)) then
                            select w
                            tell t to select
                            tell s to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """
        return try execute(script)?.booleanValue ?? false
    }

    /// The terminal of the session in iTerm2's front tab, or nil when iTerm2 isn't frontmost.
    static func frontmostTTY() -> String? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId else { return nil }
        let script = """
        tell application id "\(bundleId)"
            if (count of windows) is 0 then return ""
            return tty of current session of current window
        end tell
        """
        return (try? execute(script))?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Closes the iTerm2 session attached to `tty`. Returns false if no tab has it.
    @discardableResult
    static func close(tty: String) throws -> Bool {
        let script = """
        tell application id "\(bundleId)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is \(appleScriptString(tty)) then
                            tell s to close
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """
        return try execute(script)?.booleanValue ?? false
    }

    @discardableResult
    private static func execute(_ source: String) throws -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw Failure(message: "Couldn't build the AppleScript.") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int
            if number == -1743 {
                throw Failure(message: "Allow ClaudeResume to control iTerm2 in System Settings › Privacy & Security › Automation.")
            }
            throw Failure(message: error[NSAppleScript.errorMessage] as? String ?? "iTerm2 didn't respond.")
        }
        return result
    }
}
