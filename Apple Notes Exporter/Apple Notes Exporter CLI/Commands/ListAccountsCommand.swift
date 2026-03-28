//
//  ListAccountsCommand.swift
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

// MARK: - list-accounts

struct ListAccountsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-accounts",
        abstract: "List all Notes accounts."
    )

    @OptionGroup var dbOptions: DatabaseOptions
    @OptionGroup var formatOptions: FormatOptions

    func run() async throws {
        let engine = CLIExportEngine(databasePath: dbOptions.db)

        let accounts: [NotesAccount]
        do {
            accounts = try await engine.fetchAccounts()
        } catch {
            CLIOutput.writeError(.databaseUnavailable)
            throw ExitCode(CLIError.databaseUnavailable.exitCode)
        }

        if formatOptions.isJSON {
            struct AccountJSON: Encodable {
                let id: String
                let name: String
                let type: String
            }
            struct Output: Encodable {
                let accounts: [AccountJSON]
                let count: Int
            }
            let output = Output(
                accounts: accounts.map { AccountJSON(id: $0.id, name: $0.name, type: $0.accountType.displayName) },
                count: accounts.count
            )
            CLIOutput.writeJSON(output)
        } else {
            for account in accounts {
                print("\(account.id)\t\(account.name)\t(\(account.accountType.displayName))")
            }
            print("Total: \(accounts.count)")
        }
    }
}
