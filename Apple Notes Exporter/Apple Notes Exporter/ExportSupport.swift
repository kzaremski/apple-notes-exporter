//
//  ExportSupport.swift
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
import OSLog

// MARK: - Logger Categories

extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier ?? "com.zaremski.AppleNotesExporter"
    static let noteQuery = Logger(subsystem: subsystem, category: "notequery")
    static let noteExport = Logger(subsystem: subsystem, category: "noteexport")
}

// MARK: - String Extensions for Escaping

extension String {
    var htmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    var rtfEscaped: String {
        self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
    }

    var texEscaped: String {
        self
            .replacingOccurrences(of: "\\", with: "\\textbackslash{}")
            .replacingOccurrences(of: "&", with: "\\&")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "~", with: "\\textasciitilde{}")
            .replacingOccurrences(of: "^", with: "\\textasciicircum{}")
    }
}

// MARK: - Sync Manifest Actor

/// Thread-safe wrapper for SyncManifest mutations during concurrent export
actor SyncManifestTracker {
    private var manifest: SyncManifest

    init(manifest: SyncManifest) {
        self.manifest = manifest
    }

    func recordExport(noteId: String, modificationDate: Date, exportedPath: String, attachmentPaths: [String] = []) {
        manifest.recordExport(noteId: noteId, modificationDate: modificationDate, exportedPath: exportedPath, attachmentPaths: attachmentPaths)
    }

    func getManifest() -> SyncManifest {
        return manifest
    }
}

// MARK: - Export Progress Tracker Actor

actor ExportProgressTracker {
    private var completedCount: Int = 0
    private var failedNotesCount: Int = 0
    private var failedAttachmentsCount: Int = 0

    func noteCompleted() -> Int {
        completedCount += 1
        return completedCount
    }

    func noteFailed() {
        failedNotesCount += 1
    }

    func attachmentFailed() {
        failedAttachmentsCount += 1
    }

    func getStats() -> (completed: Int, failedNotes: Int, failedAttachments: Int) {
        return (completedCount, failedNotesCount, failedAttachmentsCount)
    }
}

// MARK: - Shared Export Helpers

/// Detect file extension from magic bytes at the start of data.
func detectFileExtension(from data: Data) -> String? {
    guard data.count >= 4 else { return nil }
    let bytes = [UInt8](data.prefix(8))

    if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF { return "jpg" }
    if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 { return "png" }
    if bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46 { return "pdf" }
    if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 { return "gif" }
    if data.count >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 { return "heic" }

    return nil
}

/// Sanitize a string for use as a filename, replacing invalid characters with underscores.
func sanitizeExportFilename(_ name: String) -> String {
    let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        .union(.newlines)
        .union(.illegalCharacters)
        .union(.controlCharacters)
    return name.components(separatedBy: invalidCharacters).joined(separator: "_")
}

/// Build a relative folder path by walking up the parent folder chain.
func buildExportFolderPath(folderId: String, folderLookup: [String: NotesFolder]) -> String {
    guard let folder = folderLookup[folderId] else {
        return sanitizeExportFilename("Unknown Folder")
    }
    var components: [String] = [sanitizeExportFilename(folder.name)]
    var currentParentId = folder.parentId
    while let parentId = currentParentId, let parentFolder = folderLookup[parentId] {
        components.insert(sanitizeExportFilename(parentFolder.name), at: 0)
        currentParentId = parentFolder.parentId
    }
    return components.joined(separator: "/")
}

/// Generate a unique filename by appending a counter suffix if a collision exists.
func generateUniqueExportFilename(baseName: String, extension ext: String, inDirectory directory: URL) -> String {
    let initial = "\(baseName).\(ext)"
    if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(initial).path) {
        return initial
    }
    var counter = 2
    while counter <= 10000 {
        let candidate = "\(baseName) (\(counter)).\(ext)"
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            return candidate
        }
        counter += 1
    }
    return "\(baseName)_\(UUID().uuidString).\(ext)"
}

/// Split a filename into name and extension at the last dot.
func splitExportFilename(_ filename: String) -> (name: String, ext: String) {
    if let lastDot = filename.lastIndex(of: "."), lastDot != filename.startIndex {
        return (String(filename[..<lastDot]), String(filename[filename.index(after: lastDot)...]))
    }
    return (filename, "")
}

/// Set file creation and modification timestamps.
func setExportFileTimestamps(_ fileURL: URL, creationDate: Date, modificationDate: Date) throws {
    try FileManager.default.setAttributes([
        .creationDate: creationDate,
        .modificationDate: modificationDate
    ], ofItemAtPath: fileURL.path)
}

/// Set folder timestamps based on the oldest creation and latest modification dates of notes within.
func setExportFolderTimestamps(hierarchy: [String: [String: [NotesNote]]], outputURL: URL) throws {
    for (accountName, folders) in hierarchy {
        let accountURL = outputURL.appendingPathComponent(sanitizeExportFilename(accountName))
        var accountOldest: Date?
        var accountLatest: Date?

        for (folderPath, notes) in folders {
            guard !notes.isEmpty else { continue }
            let folderURL = accountURL.appendingPathComponent(folderPath)
            let oldest = notes.map { $0.creationDate }.min() ?? Date()
            let latest = notes.map { $0.modificationDate }.max() ?? Date()
            try setExportFileTimestamps(folderURL, creationDate: oldest, modificationDate: latest)
            if accountOldest == nil || oldest < accountOldest! { accountOldest = oldest }
            if accountLatest == nil || latest > accountLatest! { accountLatest = latest }
        }
        if let o = accountOldest, let l = accountLatest {
            try setExportFileTimestamps(accountURL, creationDate: o, modificationDate: l)
        }
    }
}

/// Attachment UTI prefixes that represent inline/non-file content (not exported as files).
let nonFileAttachmentPrefixes: [String] = [
    "com.apple.notes.table",
    "com.apple.notes.inlinetextattachment",
    "com.apple.notes.inlinehashtagattachment",
    "com.apple.notes.inlinementionattachment",
    "public.url"
]

/// Filter attachments to only include exportable file attachments.
func filterFileAttachments(_ attachments: [NotesAttachment]) -> [NotesAttachment] {
    attachments.filter { attachment in
        !nonFileAttachmentPrefixes.contains { attachment.typeUTI.hasPrefix($0) }
    }
}

/// Create a copy of a NotesNote with a replaced htmlBody.
func noteWithHTML(_ note: NotesNote, html: String) -> NotesNote {
    NotesNote(
        id: note.id, title: note.title, plaintext: note.plaintext,
        htmlBody: html, creationDate: note.creationDate,
        modificationDate: note.modificationDate, folderId: note.folderId,
        accountId: note.accountId, attachments: note.attachments
    )
}

/// Generate text content for a note in the given format.
func generateExportTextContent(for note: NotesNote, format: ExportFormat, folderName: String?, accountName: String?) -> String {
    switch format {
    case .html:     return note.htmlBody ?? ""
    case .txt:      return note.toPlainText()
    case .markdown: return note.toMarkdown()
    case .rtf:      return note.toRTF(fontFamily: "Helvetica", fontSize: 12)
    case .tex:      return note.toLatex(template: LaTeXConfiguration.defaultTemplate)
    case .json:     return note.toJSON(folderName: folderName, accountName: accountName)
    case .jsonl:    return note.toJSONL(folderName: folderName, accountName: accountName)
    case .xml:      return note.toXML(folderName: folderName, accountName: accountName)
    case .csv:      return note.toCSV(folderName: folderName, accountName: accountName)
    case .opml:     return note.toOPML()
    case .org:      return note.toOrg()
    case .rst:      return note.toRST()
    case .adoc:     return note.toAsciiDoc()
    case .enex:     return note.toENEX()
    case .pdf, .docx, .odt, .epub:
        fatalError("Format \(format.rawValue) should not use generateExportTextContent()")
    }
}
