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
    /// Keep the last N incremental runs so the file cannot grow without bound.
    static let maxHistoryRuns = 50

    var version: Int = SyncManifest.currentVersion
    var lastSync: Date
    var notes: [String: SyncedNoteEntry]
    /// File/folder-level diffs of each incremental run (not note contents).
    var history: [SyncRun] = []

    struct SyncedNoteEntry: Codable {
        var modificationDate: Date
        var exportedPath: String
        /// Relative paths to exported attachment files for this note
        var attachmentPaths: [String]
    }

    /// One exported note as it appears on disk, for run history.
    struct HistoryItem: Codable, Equatable {
        var noteId: String
        var path: String
    }

    /// One incremental run: when it ran and which files were added, updated, or removed.
    struct SyncRun: Codable, Equatable {
        var timestamp: Date
        var added: [HistoryItem]
        var updated: [HistoryItem]
        var deleted: [HistoryItem]
    }

    struct PrunedNote {
        let noteId: String
        let entry: SyncedNoteEntry
    }

    enum CodingKeys: String, CodingKey {
        case version, lastSync, notes, history
    }

    init(lastSync: Date, notes: [String: SyncedNoteEntry], history: [SyncRun] = []) {
        self.lastSync = lastSync
        self.notes = notes
        self.history = history
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? SyncManifest.currentVersion
        lastSync = try c.decode(Date.self, forKey: .lastSync)
        notes = try c.decode([String: SyncedNoteEntry].self, forKey: .notes)
        history = try c.decodeIfPresent([SyncRun].self, forKey: .history) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(lastSync, forKey: .lastSync)
        try c.encode(notes, forKey: .notes)
        try c.encode(history, forKey: .history)
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

    /// Remove manifest entries whose note ID is not in the given set, and return
    /// the removed entries so the caller can delete the corresponding files.
    mutating func pruneDeleted(presentNoteIds: Set<String>) -> [PrunedNote] {
        let deletedIds = Set(notes.keys).subtracting(presentNoteIds)
        var removed: [PrunedNote] = []
        for id in deletedIds {
            if let entry = notes.removeValue(forKey: id) {
                removed.append(PrunedNote(noteId: id, entry: entry))
            }
        }
        return removed
    }

    /// Append one run to history, dropping the oldest if over the cap.
    mutating func appendRun(_ run: SyncRun) {
        history.append(run)
        if history.count > Self.maxHistoryRuns {
            history.removeFirst(history.count - Self.maxHistoryRuns)
        }
        lastSync = run.timestamp
    }
}
