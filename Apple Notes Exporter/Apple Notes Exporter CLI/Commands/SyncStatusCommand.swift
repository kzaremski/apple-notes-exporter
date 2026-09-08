//
//  SyncStatusCommand.swift
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

// MARK: - sync-status

struct SyncStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-status",
        abstract: "Show the incremental sync state for an output directory.",
        discussion: """
        Reads AppleNotesExportSyncWatermark.json from the output directory and
        reports when the last sync ran, how many notes are tracked, and the
        recent file/folder-level history (added, updated, deleted paths).
        Does not open the Notes database.

        To reset sync state, delete the manifest file or use:
          notes-export export --output <dir> --incremental --reset-sync
        """
    )

    @Option(name: .shortAndLong, help: "Output directory to inspect.")
    var output: String

    func run() async throws {
        let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
        let manifestURL = outputURL.appendingPathComponent(SyncManifest.filename)

        struct NoManifestResponse: Encodable {
            let manifestFound: Bool
            let outputDirectory: String
            let manifestPath: String
        }

        struct HistoryItemDTO: Encodable {
            let noteId: String
            let path: String
        }
        struct RunDTO: Encodable {
            let timestamp: String
            let added: [HistoryItemDTO]
            let updated: [HistoryItemDTO]
            let deleted: [HistoryItemDTO]
            let addedCount: Int
            let updatedCount: Int
            let deletedCount: Int
        }
        struct ManifestResponse: Encodable {
            let manifestFound: Bool
            let lastSync: String
            let trackedNotes: Int
            let historyRuns: Int
            let history: [RunDTO]
            let manifestPath: String
        }

        guard let manifest = SyncManifest.load(from: outputURL) else {
            CLIOutput.writeJSON(NoManifestResponse(
                manifestFound: false,
                outputDirectory: outputURL.path,
                manifestPath: manifestURL.path
            ))
            return
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func items(_ list: [SyncManifest.HistoryItem]) -> [HistoryItemDTO] {
            list.map { HistoryItemDTO(noteId: $0.noteId, path: $0.path) }
        }
        let history = manifest.history.suffix(10).map { run in
            RunDTO(
                timestamp: isoFormatter.string(from: run.timestamp),
                added: items(run.added),
                updated: items(run.updated),
                deleted: items(run.deleted),
                addedCount: run.added.count,
                updatedCount: run.updated.count,
                deletedCount: run.deleted.count
            )
        }

        CLIOutput.writeJSON(ManifestResponse(
            manifestFound: true,
            lastSync: isoFormatter.string(from: manifest.lastSync),
            trackedNotes: manifest.notes.count,
            historyRuns: manifest.history.count,
            history: history,
            manifestPath: manifestURL.path
        ))
    }
}
