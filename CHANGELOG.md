# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Needs you**: sessions blocked on a permission prompt or a question (Claude Code's `waiting`
  status) get an amber dot with the reason, a section at the top of the list, an amber menu
  bar badge and a notification. Before, they looked idle.
- **Last turn** in the preview: duration, edits, tool errors and the turn's estimated cost.
  The "Claude finished" notification shows the same summary.
- An animated demo at the top of the README, rendered from demo data with `--gif`.

### Changed

- Estimated costs are marked `≈`. A figure without it is Claude Code's own recorded total.
- An idle session's status reads "Idle" instead of "Waiting for you", which now means a
  session that's blocked on you.

### Fixed

- When Claude Code had recorded its own total, subagent costs were added on top of it a second time.

## [1.1.0] - 2026-10-19

### Added

- A terminal setting beside **Open Sessions In**, with iTerm2 as the default and Ghostty 1.3+
  as an optional backend. Ghostty uses its configured shell for new tabs and windows.
- Focus, close and notification routing to each running session's original terminal,
  including manually started iTerm2 sessions and app-launched Ghostty sessions.

### Changed

- A running session whose terminal can't be found (for example tmux inside iTerm2, or VS Code's
  terminal) now shows an error instead of opening a second process in a new tab. Switch to it
  where it runs, or quit it first.
- "Show in iTerm2" is now **Switch to Tab**, since the session can be in either terminal.
- The Terminal setting marks terminals that aren't installed.

### Fixed

- Refuse to resume a duplicate process when a running conversation's terminal cannot be found.

## [1.0.0] - 2026-10-13

### Added

- Menu bar panel listing every Claude Code conversation from `~/.claude/projects`,
  grouped by date, project or cost.
- One-click resume in a new iTerm2 tab or window. A running session's existing tab is
  focused instead. Forking (`--fork-session`) and extra `claude` flags are supported.
- Live busy/idle status, an **All | Running** filter, and a menu bar dot while Claude is working.
- Notifications when a turn longer than 20 seconds finishes. Clicking one opens that tab.
- A preview pane with the recap, last prompt and reply, files changed, links, prompts, cost,
  tokens and models.
- Merge request, pull request and artifact chips on rows.
- Search with loose matching, highlighted matches, and accent- and Turkish-insensitive
  folding, plus a project filter.
- Pin, hide and rename (written as a `custom-title` line, like `/rename`).
- Quit sessions that have been idle for over 1, 3, 7 or 30 days, optionally closing their tabs.
- API-equivalent cost and token totals per session, subagents included.
- Global shortcut ⌃⌥R, full keyboard navigation, right-click menu, and launch at login.
