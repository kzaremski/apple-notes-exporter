//
//  NotesExportCLI.swift
//  Apple Notes Exporter CLI
//
//  Copyright (C) 2026 Konstantin Zaremski
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import ArgumentParser
import Foundation

// MARK: - Entry Point
//
// We run ArgumentParser inside a detached Task and keep the main thread on
// RunLoop.main.run() so WebKit (used for PDF generation) can deliver its
// callbacks on the main run loop. AsyncParsableCommand's own @main would
// block the main thread on a dispatch semaphore, which deadlocks WKWebView.

@main
struct Main {
    static func main() {
        Task { @MainActor in
            do {
                var command = try NotesExportCLI.parseAsRoot()
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
                exit(0)
            } catch {
                NotesExportCLI.exit(withError: error)
            }
        }
        RunLoop.main.run()
    }
}

// MARK: - Root Command

struct NotesExportCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes-export",
        abstract: "Bulk export Apple Notes to 18 formats, from the terminal.",
        discussion: """
        Headless companion to the Apple Notes Exporter macOS app. Reads the
        local Notes database directly (no AppleScript, no UI), and supports
        filtering by account, folder, title, and modification date.

        Full Disk Access is required. In System Settings > Privacy & Security
        > Full Disk Access, add your Terminal app (Terminal.app, iTerm, etc.)
        and restart it.

        Conventions:
          - Structured data is written to stdout as JSON
          - Progress and errors go to stderr
          - Exit code 0 on success, 1 on partial failure, 2 on usage errors

        Examples:
          notes-export list-accounts
          notes-export list-folders --account iCloud
          notes-export list-notes --folder Recipes --title-contains soup
          notes-export export -o ~/Desktop/notes -f markdown --account iCloud
          notes-export export -o ~/backups/notes -f html --incremental
          notes-export sync-status -o ~/backups/notes
        """,
        version: {
            let marketing = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
            return "\(marketing).\(build)"
        }(),
        subcommands: [
            ListAccountsCommand.self,
            ListFoldersCommand.self,
            ListNotesCommand.self,
            ExportCommand.self,
            SyncStatusCommand.self,
        ]
    )
}

// MARK: - Shared Options

/// Options used by every subcommand for database path override.
struct DatabaseOptions: ParsableArguments {
    @Option(name: .long, help: "Path to NoteStore.sqlite (default: system Notes database).")
    var db: String = "\(NSHomeDirectory())/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
}

/// Options used by list commands for output format selection.
struct FormatOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Output format: json (default) or text.")
    var format: String = "json"

    var isJSON: Bool { format.lowercased() != "text" }
}
