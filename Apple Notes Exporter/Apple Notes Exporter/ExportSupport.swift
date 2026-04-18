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

    func pruneDeleted(presentNoteIds: Set<String>) -> [SyncManifest.SyncedNoteEntry] {
        manifest.pruneDeleted(presentNoteIds: presentNoteIds)
    }

    func getManifest() -> SyncManifest {
        return manifest
    }
}

// MARK: - Shared Deletion Helper

/// Delete a previously-exported note file and its attachment files.
/// Also deletes any resulting empty `(Attachments)` or ancestor folders up to (but not including) the output root.
func deleteExportedNoteFiles(
    outputRoot: URL,
    entry: SyncManifest.SyncedNoteEntry
) {
    let fm = FileManager.default

    // Collect all files to delete: the note plus its attachments
    var allPaths: [String] = [entry.exportedPath]
    allPaths.append(contentsOf: entry.attachmentPaths)

    // Track parent directories for cleanup pass
    var touchedDirs: Set<URL> = []

    for relPath in allPaths {
        let fileURL = outputRoot.appendingPathComponent(relPath)
        try? fm.removeItem(at: fileURL)
        touchedDirs.insert(fileURL.deletingLastPathComponent())
    }

    // Bottom-up cleanup: remove now-empty folders (Attachments, then account/folder hierarchy),
    // stopping at outputRoot.
    let rootPath = outputRoot.standardizedFileURL.path
    // Sort by depth descending so children are processed before parents.
    let sortedDirs = touchedDirs.sorted { $0.path.count > $1.path.count }
    var dirsToCheck = Set(sortedDirs)
    for dir in sortedDirs {
        var current = dir.standardizedFileURL
        while current.path.count > rootPath.count && current.path.hasPrefix(rootPath) {
            let contents = (try? fm.contentsOfDirectory(atPath: current.path)) ?? []
            if contents.isEmpty {
                try? fm.removeItem(at: current)
                dirsToCheck.insert(current.deletingLastPathComponent())
            } else {
                break
            }
            current = current.deletingLastPathComponent()
        }
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

// MARK: - Internal Link Rewriting

/// Pre-allocate a unique filename for each note, honoring the sync manifest's existing paths.
/// Returns `[note.id: <relative path from output root, including extension>]`.
///
/// Output filenames match what exportNote will produce later, so we can rewrite
/// applenotes:note/UUID links to real file paths before the notes are rendered.
func buildInternalLinkPathMap(
    allNotes: [NotesNote],
    notesWithPaths: [(note: NotesNote, folderURL: URL)],
    outputRoot: URL,
    format: ExportFormat,
    addDatePrefix: Bool,
    dateFormat: String,
    existingManifest: SyncManifest?
) -> [String: String] {
    var map: [String: String] = [:]

    // Start with any paths already recorded from previous sync runs.
    if let manifest = existingManifest {
        for (id, entry) in manifest.notes {
            map[id] = entry.exportedPath
        }
    }

    // Pre-allocate filenames for notes being exported this run.
    var reservedByFolder: [String: Set<String>] = [:]
    let rootPath = outputRoot.standardizedFileURL.path

    for pair in notesWithPaths {
        let note = pair.note
        let folderURL = pair.folderURL

        let baseName: String
        if addDatePrefix {
            let formatter = DateFormatter()
            formatter.dateFormat = dateFormat
            baseName = "\(formatter.string(from: note.creationDate)) \(note.sanitizedFileName)"
        } else {
            baseName = note.sanitizedFileName
        }

        let folderKey = folderURL.standardizedFileURL.path
        var used = reservedByFolder[folderKey] ?? []

        var filename = "\(baseName).\(format.fileExtension)"
        var counter = 2
        while used.contains(filename) && counter <= 10000 {
            filename = "\(baseName) (\(counter)).\(format.fileExtension)"
            counter += 1
        }
        used.insert(filename)
        reservedByFolder[folderKey] = used

        let fullPath = folderURL.appendingPathComponent(filename).standardizedFileURL.path
        if fullPath.hasPrefix(rootPath + "/") {
            map[note.id] = String(fullPath.dropFirst(rootPath.count + 1))
        } else if fullPath == rootPath {
            map[note.id] = filename
        } else {
            map[note.id] = folderURL.appendingPathComponent(filename).path
        }
    }

    return map
}

/// Rewrite `applenotes:note/UUID?...` links in HTML to relative paths to the target note's exported file.
/// - currentNoteRelativePath: path of the note whose HTML we are rewriting, relative to the output root.
/// - noteIdToRelativePath: map from note ID to target file path, relative to the output root.
func rewriteInternalLinks(
    html: String,
    currentNoteRelativePath: String,
    noteIdToRelativePath: [String: String]
) -> String {
    guard !noteIdToRelativePath.isEmpty,
          html.contains("applenotes:note/") else { return html }

    // Match applenotes:note/UUID, stopping at the first non-UUID character (?, ", ', >, space, etc.)
    let pattern = #"applenotes:note/([A-Fa-f0-9][A-Fa-f0-9\-]{7,})(\?[^"'<>\s]*)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

    let nsHtml = html as NSString
    let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))

    guard !matches.isEmpty else { return html }

    var result = html
    // Process matches in reverse so NSRange offsets stay valid.
    for match in matches.reversed() {
        let fullRange = match.range
        let uuidRange = match.range(at: 1)
        guard uuidRange.location != NSNotFound else { continue }

        let uuid = nsHtml.substring(with: uuidRange)
        guard let targetRelPath = noteIdToRelativePath[uuid] else { continue }

        let relativeLink = relativePathFromSource(currentNoteRelativePath, toTarget: targetRelPath)
        let encoded = relativeLink.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativeLink

        // Replace the matched substring using Range<String.Index>
        if let range = Range(fullRange, in: result) {
            result.replaceSubrange(range, with: encoded)
        }
    }

    return result
}

/// Compute a relative file path from `source` to `target`, both relative to a common root.
/// Example: source="iCloud/Work/A.md", target="iCloud/Personal/B.md" -> "../Personal/B.md".
func relativePathFromSource(_ source: String, toTarget target: String) -> String {
    let sourceComponents = source.split(separator: "/").map(String.init)
    let targetComponents = target.split(separator: "/").map(String.init)
    guard !sourceComponents.isEmpty else { return target }

    // Source's directory is sourceComponents without the last element (filename).
    let sourceDir = Array(sourceComponents.dropLast())

    // Find common prefix length
    var common = 0
    while common < sourceDir.count && common < targetComponents.count
          && sourceDir[common] == targetComponents[common] {
        common += 1
    }

    var parts: [String] = []
    parts.append(contentsOf: Array(repeating: "..", count: sourceDir.count - common))
    parts.append(contentsOf: targetComponents.dropFirst(common))
    return parts.isEmpty ? targetComponents.last ?? "" : parts.joined(separator: "/")
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
