# Contributing

Thanks for helping out! ClaudeResume is a small app and aims to stay that way: one panel,
no dependencies, no network access, and nothing written to your transcripts unless you ask.

## Getting started

Requirements: macOS 15+, Xcode 16+ (or the matching Swift toolchain) and iTerm2.

```sh
make test      # run the test suite
make run       # run from the terminal
make dump      # print the sessions the app would list
make install   # build the .app, copy it to ~/Applications and launch it
```

## Before opening a pull request

- `make test` passes. Add a test when you change transcript parsing, search, grouping or the
  resume command. They're pure functions and easy to test with small JSONL fixtures.
- Transcript fixtures in tests are made up. Never commit a real transcript or a piece of one.
- UI changes come with fresh screenshots. `make screenshots` renders the panel from demo data,
  so no real session titles end up in the repository.
- Price changes cite the [pricing page](https://platform.claude.com/docs/en/about-claude/pricing)
  and update the date in `Pricing.swift`.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/),
  e.g. `feat: group sessions by branch` or `fix(parser): skip truncated lines`.
- Keep the scope tight. A feature belongs here if it helps you find a conversation or get back
  into one.

## How the code is organised

| File | Responsibility |
| --- | --- |
| `SessionScanner.swift` | Finds transcripts, caches them by size and date, and parses titles, prompts, recaps, links, files and usage from raw bytes |
| `LiveSessions.swift` | Reads `~/.claude/sessions/*.json` for running sessions and finds each process's terminal |
| `Search.swift` | Folding, scoring and highlight ranges for the search field |
| `SessionStore.swift` | Observable app state: listing, grouping, pins, hidden sessions, renames, notifications, quitting sessions, actions |
| `ITerm.swift` | AppleScript for opening, focusing and closing iTerm2 tabs, and shell quoting |
| `Notifier.swift` | "Claude finished" notifications |
| `TranscriptWriter.swift` | The one write to a transcript: the `custom-title` line used for renames |
| `Pricing.swift` | Model names and API list prices for the cost estimate |
| `PanelView.swift` | The list, rows, menus and dialogs |
| `PreviewPane.swift` | The preview pane |
| `HotKey.swift` | The global ⌃⌥R shortcut |
| `ClaudeResumeApp.swift` | Entry point, status item, panel window, keyboard handling and debug flags |
| `Snapshot.swift` | `--snapshot` rendering and the demo data used for screenshots |

## Transcript format

Claude Code's JSONL format is undocumented and changes between versions. When a field moves,
keep the parser tolerant: missing data should hide a detail, never drop a session or crash.
Mention the Claude Code version (`claude --version`) you tested against in the pull request.

## Reporting bugs

Please include your macOS, Claude Code and iTerm2 versions, how you installed ClaudeResume,
and any error banner text. Please don't paste transcript contents. They can contain code,
credentials or other private data.
