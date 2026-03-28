//
//  ListNotesCommand.swift
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

// MARK: - list-notes

struct ListNotesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-notes",
        abstract: "List Notes with optional filtering."
    )

    @Option(name: .long, help: "Filter by account name (partial match, case-insensitive).")
    var account: String?

    @Option(name: .long, help: "Filter by folder name (partial match, case-insensitive).")
    var folder: String?

    @Option(name: .long, help: "Filter notes whose title contains this string (case-insensitive).")
    var titleContains: String?

    @Option(name: .long, help: "Include notes modified after this ISO 8601 date (e.g. 2025-01-01 or 2025-01-01T00:00:00Z).")
    var modifiedAfter: String?

    @Option(name: .long, help: "Include notes modified before this ISO 8601 date.")
    var modifiedBefore: String?

    @Option(name: .long, help: "Include notes created after this ISO 8601 date.")
    var createdAfter: String?

    @Option(name: .long, help: "Include notes created before this ISO 8601 date.")
    var createdBefore: String?

    @Option(name: .shortAndLong, help: "Sort order: name, date-modified (default), date-created.")
    var sort: String = "date-modified"

    @Flag(name: .long, help: "Include plaintext content of each note in the output (may be large).")
    var includeContent: Bool = false

    @OptionGroup var dbOptions: DatabaseOptions
    @OptionGroup var formatOptions: FormatOptions

    func run() async throws {
        let engine = CLIExportEngine(databasePath: dbOptions.db)

        let (accounts, folders, notes): ([NotesAccount], [NotesFolder], [NotesNote])
        do {
            async let a = engine.fetchAccounts()
            async let f = engine.fetchFolders()
            async let n = engine.fetchNotes()
            (accounts, folders, notes) = try await (a, f, n)
        } catch {
            CLIOutput.writeError(.databaseUnavailable)
            throw ExitCode(CLIError.databaseUnavailable.exitCode)
        }

        var accountLookup: [String: String] = [:]
        for acct in accounts { accountLookup[acct.id] = acct.name }

        var folderLookup: [String: NotesFolder] = [:]
        for fld in folders { folderLookup[fld.id] = fld }

        // Apply filters
        var filtered = notes

        if let accountFilter = account?.lowercased() {
            let matchingIds = accounts.filter { $0.name.lowercased().contains(accountFilter) }.map { $0.id }
            filtered = filtered.filter { matchingIds.contains($0.accountId) }
        }

        if let folderFilter = folder?.lowercased() {
            let matchingIds = folders.filter { $0.name.lowercased().contains(folderFilter) }.map { $0.id }
            filtered = filtered.filter { matchingIds.contains($0.folderId) }
        }

        if let tc = titleContains?.lowercased() {
            filtered = filtered.filter { $0.title.lowercased().contains(tc) }
        }

        if let dateStr = modifiedAfter, let date = parseDate(dateStr) {
            filtered = filtered.filter { $0.modificationDate > date }
        }
        if let dateStr = modifiedBefore, let date = parseDate(dateStr) {
            filtered = filtered.filter { $0.modificationDate < date }
        }
        if let dateStr = createdAfter, let date = parseDate(dateStr) {
            filtered = filtered.filter { $0.creationDate > date }
        }
        if let dateStr = createdBefore, let date = parseDate(dateStr) {
            filtered = filtered.filter { $0.creationDate < date }
        }

        // Apply sort
        switch sort.lowercased() {
        case "name":
            filtered.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "date-created":
            filtered.sort { $0.creationDate > $1.creationDate }
        default: // date-modified
            filtered.sort { $0.modificationDate > $1.modificationDate }
        }

        if formatOptions.isJSON {
            struct NoteJSON: Encodable {
                let id: String
                let title: String
                let folderId: String
                let folderName: String
                let accountId: String
                let accountName: String
                let creationDate: Date
                let modificationDate: Date
                let attachmentCount: Int
                let plaintext: String?
            }
            struct Output: Encodable {
                let notes: [NoteJSON]
                let count: Int
            }
            let output = Output(
                notes: filtered.map { note in
                    NoteJSON(
                        id: note.id,
                        title: note.title,
                        folderId: note.folderId,
                        folderName: folderLookup[note.folderId]?.name ?? "Unknown",
                        accountId: note.accountId,
                        accountName: accountLookup[note.accountId] ?? "Unknown",
                        creationDate: note.creationDate,
                        modificationDate: note.modificationDate,
                        attachmentCount: note.attachments.count,
                        plaintext: includeContent ? note.plaintext : nil
                    )
                },
                count: filtered.count
            )
            CLIOutput.writeJSON(output)
        } else {
            for note in filtered {
                let accountName = accountLookup[note.accountId] ?? "Unknown"
                let folderName = folderLookup[note.folderId]?.name ?? "Unknown"
                print("\(note.id)\t\(note.title)\t[\(accountName)/\(folderName)]")
                if includeContent {
                    print(note.plaintext)
                    print("---")
                }
            }
            print("Total: \(filtered.count)")
        }
    }

    // MARK: - Date Parsing

    private func parseDate(_ string: String) -> Date? {
        // Try full ISO 8601 with time first
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFull.date(from: string) { return date }

        let isoBasic = ISO8601DateFormatter()
        if let date = isoBasic.date(from: string) { return date }

        // Try date-only (yyyy-MM-dd) — interpret as start of day UTC
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = TimeZone(identifier: "UTC")
        return dateOnly.date(from: string)
    }
}
