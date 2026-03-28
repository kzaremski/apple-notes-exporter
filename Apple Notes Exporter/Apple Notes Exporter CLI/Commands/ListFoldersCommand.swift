//
//  ListFoldersCommand.swift
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

// MARK: - list-folders

struct ListFoldersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-folders",
        abstract: "List all Notes folders."
    )

    @Option(name: .long, help: "Filter folders by account name (partial match, case-insensitive).")
    var account: String?

    @OptionGroup var dbOptions: DatabaseOptions
    @OptionGroup var formatOptions: FormatOptions

    func run() async throws {
        let engine = CLIExportEngine(databasePath: dbOptions.db)

        let (accounts, folders): ([NotesAccount], [NotesFolder])
        do {
            async let a = engine.fetchAccounts()
            async let f = engine.fetchFolders()
            (accounts, folders) = try await (a, f)
        } catch {
            CLIOutput.writeError(.databaseUnavailable)
            throw ExitCode(CLIError.databaseUnavailable.exitCode)
        }

        // Build account lookup
        var accountLookup: [String: String] = [:]
        for acct in accounts { accountLookup[acct.id] = acct.name }

        // Filter by account if requested
        let filtered: [NotesFolder]
        if let accountFilter = account?.lowercased() {
            let matchingAccountIds = accounts
                .filter { $0.name.lowercased().contains(accountFilter) }
                .map { $0.id }
            filtered = folders.filter { matchingAccountIds.contains($0.accountId) }
        } else {
            filtered = folders
        }

        if formatOptions.isJSON {
            struct FolderJSON: Encodable {
                let id: String
                let name: String
                let parentId: String?
                let accountId: String
                let accountName: String
            }
            struct Output: Encodable {
                let folders: [FolderJSON]
                let count: Int
            }
            let output = Output(
                folders: filtered.map { folder in
                    FolderJSON(
                        id: folder.id,
                        name: folder.name,
                        parentId: folder.parentId,
                        accountId: folder.accountId,
                        accountName: accountLookup[folder.accountId] ?? "Unknown"
                    )
                },
                count: filtered.count
            )
            CLIOutput.writeJSON(output)
        } else {
            for folder in filtered {
                let accountName = accountLookup[folder.accountId] ?? "Unknown"
                let parentInfo = folder.parentId.map { " (parent: \($0))" } ?? ""
                print("\(folder.id)\t\(folder.name)\t[\(accountName)]\(parentInfo)")
            }
            print("Total: \(filtered.count)")
        }
    }
}
