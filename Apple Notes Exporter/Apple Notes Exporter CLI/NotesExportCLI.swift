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

// MARK: - Root Command

@main
struct NotesExportCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes-export",
        abstract: "Export and query Apple Notes from the terminal.",
        discussion: """
        Requires Full Disk Access for the terminal process.
        Grant it in System Settings → Privacy & Security → Full Disk Access.

        All output is JSON on stdout; progress and errors go to stderr.
        """,
        version: "1.1.0",
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
