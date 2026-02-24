//
//  SyncManifest.swift
//  Apple Notes Exporter
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

import Foundation

// MARK: - Sync Manifest

struct SyncManifest: Codable {
    static let filename = "AppleNotesExportSyncWatermark.json"
    static let currentVersion = 1

    var version: Int = SyncManifest.currentVersion
    var lastSync: Date
    var notes: [String: SyncedNoteEntry]

    struct SyncedNoteEntry: Codable {
        var modificationDate: Date
        var exportedPath: String
        /// Relative paths to exported attachment files for this note
        var attachmentPaths: [String]
    }

    // MARK: - Factory

    static func empty() -> SyncManifest {
        SyncManifest(lastSync: Date(), notes: [:])
    }

    // MARK: - Persistence

    /// Load manifest from a directory, returns nil if not found or unreadable
    static func load(from directory: URL) -> SyncManifest? {
        let fileURL = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SyncManifest.self, from: data)
    }

    /// Save manifest to a directory (atomic write)
    func save(to directory: URL) throws {
        let fileURL = directory.appendingPathComponent(SyncManifest.filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Sync Logic

    /// Determine which notes need to be exported (new or modified since last sync)
    func notesNeedingExport(from notes: [NotesNote]) -> [NotesNote] {
        return notes.filter { note in
            guard let entry = self.notes[note.id] else {
                // Note not in manifest — it's new
                return true
            }
            // Note exists — check if it's been modified since last export
            // Use 0.001s tolerance to avoid floating-point precision false positives
            return note.modificationDate.timeIntervalSince1970 - entry.modificationDate.timeIntervalSince1970 > 0.001
        }
    }

    /// Get the previously exported path for a note (for overwrite-in-place)
    func existingPath(for noteId: String) -> String? {
        return notes[noteId]?.exportedPath
    }

    // MARK: - Mutation

    /// Record a successfully exported note
    mutating func recordExport(noteId: String, modificationDate: Date, exportedPath: String, attachmentPaths: [String] = []) {
        notes[noteId] = SyncedNoteEntry(
            modificationDate: modificationDate,
            exportedPath: exportedPath,
            attachmentPaths: attachmentPaths
        )
        lastSync = Date()
    }
}
