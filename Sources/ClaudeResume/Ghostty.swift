import AppKit
import Foundation

/// Ghostty 1.3+ native automation, using the user's configured shell.
enum Ghostty {
    static let bundleId = "com.mitchellh.ghostty"
    static let mappingsKey = "ghosttyTerminals"
    static let maximumMappings = 256

    static func launchScript(command: String, placement: Terminal.Placement, cwd: String? = nil, marker: String) -> String {
        """
        tell application id "\(bundleId)"
            set cfg to new surface configuration
            \(cwd.map { "set initial working directory of cfg to \(ITerm.appleScriptString($0))" } ?? "")
            set environment variables of cfg to {\(ITerm.appleScriptString("CLAUDE_RESUME_TERMINAL=" + marker))}
            set initial input of cfg to \(ITerm.appleScriptString(command)) & return
            if \(placement == .window ? "true" : "false") or (count of windows) is 0 then
                set win to new window with configuration cfg
                set targetTerminal to focused terminal of selected tab of win
            else
                set targetTab to new tab in front window with configuration cfg
                set targetTerminal to focused terminal of targetTab
            end if
            set terminalID to id of targetTerminal
            focus targetTerminal
            activate
            return {terminalID, (get id of every terminal)}
        end tell
        """
    }

    static func run(_ command: String, placement: Terminal.Placement, cwd: String? = nil) throws {
        let marker = UUID().uuidString
        let result = try execute(launchScript(command: command, placement: placement, cwd: cwd, marker: marker))
        guard let terminalID = result?.atIndex(1)?.stringValue, !terminalID.isEmpty,
              let terminals = result?.atIndex(2) else {
            throw Terminal.Failure(message: "Ghostty did not return the new terminal's ID. Ghostty 1.3 or later is required.")
        }
        var ids = Set<String>()
        for index in 0..<terminals.numberOfItems {
            if let id = terminals.atIndex(index + 1)?.stringValue { ids.insert(id) }
        }
        remember(marker: marker, terminalID: terminalID, existingIDs: ids)
    }

    static func terminalID(for marker: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: mappingsKey) as? [String: String])?[marker]
    }

    /// Prune closed surfaces on every launch and bound storage even for long-running terminals.
    static func remember(marker: String, terminalID: String, existingIDs: Set<String>, defaults: UserDefaults = .standard) {
        let saved = defaults.dictionary(forKey: mappingsKey) as? [String: String] ?? [:]
        var mappings = saved.filter { existingIDs.contains($0.value) }
        while mappings.count >= maximumMappings, let key = mappings.keys.sorted().first {
            mappings.removeValue(forKey: key)
        }
        mappings[marker] = terminalID
        defaults.set(mappings, forKey: mappingsKey)
    }

    static func focus(terminalID: String) throws -> Bool {
        try execute("""
        tell application id "\(bundleId)"
            repeat with t in terminals
                if id of t is \(ITerm.appleScriptString(terminalID)) then
                    focus t
                    activate
                    return true
                end if
            end repeat
            return false
        end tell
        """)?.booleanValue ?? false
    }

    static func frontmostTerminalID() -> String? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId else { return nil }
        return (try? execute("""
        tell application id "\(bundleId)"
            if (count of windows) is 0 then return ""
            return id of focused terminal of selected tab of front window
        end tell
        """))?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    static func close(terminalID: String) throws -> Bool {
        let closed = try execute("""
        tell application id "\(bundleId)"
            repeat with t in terminals
                if id of t is \(ITerm.appleScriptString(terminalID)) then
                    close t
                    return true
                end if
            end repeat
            return false
        end tell
        """)?.booleanValue ?? false
        forget(terminalID: terminalID)
        return closed
    }

    static func forget(terminalID: String, defaults: UserDefaults = .standard) {
        let saved = defaults.dictionary(forKey: mappingsKey) as? [String: String] ?? [:]
        defaults.set(saved.filter { $0.value != terminalID }, forKey: mappingsKey)
    }

    private static func execute(_ source: String) throws -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw Terminal.Failure(message: "Couldn't build the Ghostty AppleScript. Ghostty 1.3 or later is required.")
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == -1743 {
                throw Terminal.Failure(message: "Allow ClaudeResume to control Ghostty in System Settings › Privacy & Security › Automation.")
            }
            throw Terminal.Failure(message: error[NSAppleScript.errorMessage] as? String ?? "Ghostty didn't respond. Check that Ghostty 1.3+ is installed and macos-applescript is enabled.")
        }
        return result
    }
}
