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
        reports when the last sync ran and how many notes are tracked.
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

        struct ManifestResponse: Encodable {
            let manifestFound: Bool
            let lastSync: String
            let trackedNotes: Int
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

        CLIOutput.writeJSON(ManifestResponse(
            manifestFound: true,
            lastSync: isoFormatter.string(from: manifest.lastSync),
            trackedNotes: manifest.notes.count,
            manifestPath: manifestURL.path
        ))
    }
}
