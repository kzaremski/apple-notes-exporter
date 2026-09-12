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
import Darwin

// MARK: - Logger Categories

extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier ?? "com.zaremski.AppleNotesExporter"
    static let noteQuery = Logger(subsystem: subsystem, category: "notequery")
    static let noteExport = Logger(subsystem: subsystem, category: "noteexport")
}

// MARK: - Notes database paths and TCC probe

/// Login-user home directory. `NSHomeDirectory()` can point at a container
/// in helper or sandbox contexts, which then fails to match the path TCC uses
/// for Full Disk Access.
func userHomeDirectoryPath() -> String {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return URL(fileURLWithFileSystemRepresentation: dir, isDirectory: true, relativeTo: nil)
            .standardizedFileURL.path
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
}

/// Expand tildes and standardize so TCC and sqlite see a canonical absolute path.
func resolvedFilePath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}

/// Absolute path to the live Apple Notes store.
func defaultNotesDatabasePath() -> String {
    resolvedFilePath(
        userHomeDirectoryPath() + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    )
}

/// List the Notes group container using an absolute path.
/// That I/O is what registers this process with TCC; `isReadableFile` is not enough,
/// and there is no public API to grant Full Disk Access.
func hasNotesDatabaseAccess(at databasePath: String = defaultNotesDatabasePath()) -> Bool {
    let absoluteDB = resolvedFilePath(databasePath)
    let container = URL(fileURLWithPath: absoluteDB).deletingLastPathComponent().path
    do {
        _ = try FileManager.default.contentsOfDirectory(atPath: container)
        return true
    } catch {
        return false
    }
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

    /// Decode common HTML entities to their character equivalents
    var htmlDecoded: String {
        var result = self
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")

        // Decode numeric HTML entities (&#NNN; and &#xHHH;)
        // Decimal entities
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            // Process in reverse to preserve string indices
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[codeRange]),
                   let scalar = Unicode.Scalar(codePoint) {
                    let replacement = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: replacement)
                    }
                }
            }
        }

        // Hex entities
        if let regex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);", options: []) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[codeRange], radix: 16),
                   let scalar = Unicode.Scalar(codePoint) {
                    let replacement = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: replacement)
                    }
                }
            }
        }

        return result
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
    private var currentAdded: [SyncManifest.HistoryItem] = []
    private var currentUpdated: [SyncManifest.HistoryItem] = []

    init(manifest: SyncManifest) {
        self.manifest = manifest
    }

    func recordExport(noteId: String, modificationDate: Date, exportedPath: String, attachmentPaths: [String] = []) {
        let item = SyncManifest.HistoryItem(noteId: noteId, path: exportedPath)
        if manifest.notes[noteId] != nil {
            currentUpdated.append(item)
        } else {
            currentAdded.append(item)
        }
        manifest.recordExport(noteId: noteId, modificationDate: modificationDate, exportedPath: exportedPath, attachmentPaths: attachmentPaths)
    }

    func pruneDeleted(presentNoteIds: Set<String>) -> [SyncManifest.PrunedNote] {
        manifest.pruneDeleted(presentNoteIds: presentNoteIds)
    }

    /// Close out this incremental run with a file/folder-level diff.
    func finishRun(pruned: [SyncManifest.PrunedNote]) {
        let deleted = pruned.map { SyncManifest.HistoryItem(noteId: $0.noteId, path: $0.entry.exportedPath) }
        manifest.appendRun(SyncManifest.SyncRun(
            timestamp: Date(),
            added: currentAdded,
            updated: currentUpdated,
            deleted: deleted
        ))
        currentAdded = []
        currentUpdated = []
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
        // HTML exports write index.html as a folder listing; never let a note claim that name.
        if format == .html {
            used.insert("index.html")
        }

        var filename = "\(baseName).\(format.fileExtension)"
        var counter = 2
        while used.contains(filename) && counter <= 10000 {
            filename = "\(baseName) (\(counter)).\(format.fileExtension)"
            counter += 1
        }
        used.insert(filename)
        reservedByFolder[folderKey] = used

        let fullPath = folderURL.appendingPathComponent(filename).standardizedFileURL.path
        let rel: String
        if fullPath.hasPrefix(rootPath + "/") {
            rel = String(fullPath.dropFirst(rootPath.count + 1))
        } else if fullPath == rootPath {
            rel = filename
        } else {
            rel = folderURL.appendingPathComponent(filename).path
        }
        // Links in note bodies use ZIDENTIFIER (UUID), not the Core Data PK.
        map[note.id] = rel
        if !note.identifier.isEmpty {
            map[note.identifier] = rel
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
    // The query class must exclude ] and ) as well: Apple renders an inline
    // link as "alt [url]", and swallowing the bracket leaves it unbalanced.
    let pattern = #"applenotes:note/([A-Fa-f0-9][A-Fa-f0-9\-]{7,})(\?[^"'<>\s\]\)]*)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

    // Apple stores ZIDENTIFIER uppercase but writes the UUID lowercase into
    // applenotes: links, so a case-sensitive lookup never matches on real
    // data. Normalize here rather than relying on how the caller keyed it.
    var loweredIndex: [String: String] = [:]
    loweredIndex.reserveCapacity(noteIdToRelativePath.count)
    for (key, value) in noteIdToRelativePath {
        let lowered = key.lowercased()
        if loweredIndex[lowered] == nil { loweredIndex[lowered] = value }
    }

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
        guard let targetRelPath = noteIdToRelativePath[uuid]
                ?? loweredIndex[uuid.lowercased()] else { continue }

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

/// Last-resort name when an account exposes no default folder at all. Only
/// reached on libraries with no ZIDENTIFIER column and no folder named "Notes".
let fallbackNotesFolderName = "Notes"

/// The folder Apple Notes files an account's loose notes into: its default
/// folder. Prefers Apple's "DefaultFolder" ZIDENTIFIER marker so this keeps
/// working on localized libraries where the folder is called "Notizen" or
/// "\u{5907}\u{5FD8}\u{5F55}", and falls back to a root folder literally named
/// "Notes" for older schemas that carry no identifier.
///
/// Candidates are sorted by id so a library with more than one marked folder
/// still resolves to the same folder on every run; export paths and the sync
/// manifest both depend on this being stable.
func defaultNotesFolder(forAccount accountId: String?, in folderLookup: [String: NotesFolder]) -> NotesFolder? {
    guard let accountId, !accountId.isEmpty else { return nil }
    let inAccount = folderLookup.values
        .filter { $0.accountId == accountId }
        .sorted { $0.id < $1.id }

    if let marked = inAccount.first(where: { $0.isDefaultFolder }) {
        return marked
    }
    return inAccount.first { folder in
        folder.name.compare(fallbackNotesFolderName, options: .caseInsensitive) == .orderedSame
            && (folder.parentId == nil || folder.parentId == accountId)
    }
}

/// Join a folder to its ancestors, innermost last. Bounded so a self-parenting
/// or cyclic ZPARENT chain cannot spin forever.
private func folderPath(for folder: NotesFolder, in folderLookup: [String: NotesFolder]) -> String {
    var components: [String] = [sanitizeExportFilename(folder.name)]
    var currentParentId = folder.parentId
    var depth = 0
    while let parentId = currentParentId, let parentFolder = folderLookup[parentId], depth < 64 {
        components.insert(sanitizeExportFilename(parentFolder.name), at: 0)
        currentParentId = parentFolder.parentId
        depth += 1
    }
    return components.joined(separator: "/")
}

/// Build a relative folder path by walking up the parent folder chain.
func buildExportFolderPath(folderId: String, folderLookup: [String: NotesFolder], accountId: String? = nil, isDeleted: Bool = false) -> String {
    if isDeleted {
        return sanitizeExportFilename("Recently Deleted")
    }
    if let folder = folderLookup[folderId] {
        return folderPath(for: folder, in: folderLookup)
    }

    // Unfiled / epoch notes often have a missing or dangling ZFOLDER. Apple
    // Notes shows them in the account's default folder; full and incremental
    // export both do the same rather than inventing an "Unknown Folder".
    if let fallback = defaultNotesFolder(forAccount: accountId, in: folderLookup) {
        return folderPath(for: fallback, in: folderLookup)
    }
    return sanitizeExportFilename(fallbackNotesFolderName)
}

/// Relative directory (account plus folder path) a note belongs in.
func expectedExportDirectory(
    for note: NotesNote,
    accountLookup: [String: String],
    folderLookup: [String: NotesFolder]
) -> String {
    let accountKey = sanitizeExportFilename(accountLookup[note.accountId] ?? "Unknown Account")
    let folderPath = buildExportFolderPath(
        folderId: note.folderId,
        folderLookup: folderLookup,
        accountId: note.accountId,
        isDeleted: note.isDeleted
    )
    return "\(accountKey)/\(folderPath)"
}

/// Drop manifest entries whose files no longer sit where the current resolver
/// would put them, deleting the stale files so the next pass re-exports them in
/// the right place.
///
/// This repairs sync directories written by older versions, which parked
/// unresolvable notes in "Unknown Folder" and then kept overwriting them there
/// forever, and it also picks up notes the user has since moved between folders
/// in Apple Notes. Only the directory is compared: the filename can legitimately
/// differ by a collision suffix such as "Title (2).md".
@discardableResult
func healManifestPaths(
    manifest: inout SyncManifest,
    notes: [NotesNote],
    accountLookup: [String: String],
    folderLookup: [String: NotesFolder],
    outputRoot: URL
) -> [SyncManifest.PrunedNote] {
    var healed: [SyncManifest.PrunedNote] = []
    for note in notes {
        guard let entry = manifest.notes[note.id] else { continue }
        let storedDirectory = (entry.exportedPath as NSString).deletingLastPathComponent
        let expectedDirectory = expectedExportDirectory(
            for: note,
            accountLookup: accountLookup,
            folderLookup: folderLookup
        )
        guard storedDirectory != expectedDirectory else { continue }

        deleteExportedNoteFiles(outputRoot: outputRoot, entry: entry)
        manifest.notes.removeValue(forKey: note.id)
        healed.append(SyncManifest.PrunedNote(noteId: note.id, entry: entry))
    }
    return healed
}

// MARK: - Evernote Limits

/// Evernote's documented ceilings, from Limits.thrift in the EDAM SDK.
enum ENEXLimits {
    /// EDAM_NOTE_CONTENT_LEN_MAX: the ENML content of a single note.
    static let noteContentMax = 5_242_880
    /// EDAM_NOTE_SIZE_MAX_FREE: a whole note including its resources.
    static let noteSizeFreeMax = 26_214_400
    /// EDAM_NOTE_SIZE_MAX_PREMIUM: the same ceiling on a paid plan.
    static let noteSizePaidMax = 209_715_200

    /// A message for a note Evernote may refuse, or nil when it is within the
    /// free-account ceiling. Whether it imports depends on the destination
    /// account, which the exporter cannot know, so this is a warning and not
    /// an error: the file is still written.
    static func oversizeWarning(title: String, byteCount: Int) -> String? {
        guard byteCount > noteSizeFreeMax else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: Int64(noteSizeFreeMax), countStyle: .file)
        let paid = ByteCountFormatter.string(fromByteCount: Int64(noteSizePaidMax), countStyle: .file)
        if byteCount > noteSizePaidMax {
            return "'\(title)' is \(size), over Evernote's \(paid) per-note limit even on a paid plan. Evernote will refuse it."
        }
        return "'\(title)' is \(size), over Evernote's \(free) per-note limit for free accounts. It needs a paid Evernote plan, which raises the limit to \(paid)."
    }
}

// MARK: - Archive Output

/// Default base name for a single-file (concatenated) export.
let concatenatedFileBaseName = "Exported Notes"

/// Where a single-file export should write.
///
/// `destination` is either the file the user named or a directory to put one
/// in, mirroring how a zip destination is resolved.
func concatenatedExportURL(destination: URL, format: ExportFormat) -> URL {
    destination.pathExtension.lowercased() == format.fileExtension
        ? destination
        : destination.appendingPathComponent("\(concatenatedFileBaseName).\(format.fileExtension)")
}

/// Default root name for a zip export: both the folder inside the archive and
/// the archive itself when the user has not named one.
let exportArchiveRootName = "Apple Notes Export"

/// Zip `sourceURL` (a directory) to `destinationURL`.
///
/// NSFileCoordinator's .forUploading intent is what Finder's "Compress" uses,
/// so the archive matches what a user would produce by hand. Synchronous and
/// throwing: the caller needs to know whether the artifact was actually
/// written before it reports success and deletes the staging directory.
func zipDirectory(at sourceURL: URL, to destinationURL: URL) throws {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var writeError: Error?

    coordinator.coordinate(readingItemAt: sourceURL, options: [.forUploading], error: &coordinationError) { zippedURL in
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: zippedURL, to: destinationURL)
        } catch {
            writeError = error
        }
    }

    if let coordinationError { throw coordinationError }
    if let writeError { throw writeError }
}

/// A path in `directory` that collides with nothing already there.
func uniqueExportURL(in directory: URL, baseName: String, extension ext: String?) -> URL {
    func candidate(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        return ext.map { url.appendingPathExtension($0) } ?? url
    }
    var url = candidate(baseName)
    var counter = 2
    while FileManager.default.fileExists(atPath: url.path), counter <= 1000 {
        url = candidate("\(baseName) (\(counter))")
        counter += 1
    }
    return url
}

/// Resolve where a zip export should stage its files and write its archive.
///
/// `destination` is either the archive the user named or a folder to put one
/// in. The archive's own name becomes the root folder inside it.
func archiveExportLocations(destination: URL) -> (staging: URL, archive: URL) {
    let archive = destination.pathExtension.lowercased() == "zip"
        ? destination
        : uniqueExportURL(in: destination, baseName: exportArchiveRootName, extension: "zip")
    let rootName = archive.deletingPathExtension().lastPathComponent
    let staging = uniqueExportURL(
        in: archive.deletingLastPathComponent(), baseName: rootName, extension: nil
    )
    return (staging, archive)
}

/// Generate a unique filename by appending a counter suffix if a collision exists.
func generateUniqueExportFilename(baseName: String, extension ext: String, inDirectory directory: URL) -> String {
    let initial = "\(baseName).\(ext)"
    // HTML exports write index.html as a folder listing; never let a note claim that name.
    let reserved = ext.lowercased() == "html" && initial.lowercased() == "index.html"
    if !reserved && !FileManager.default.fileExists(atPath: directory.appendingPathComponent(initial).path) {
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

/// Split comma-separated CLI tokens, also flattening repeated --folder values.
func parseListArgument(_ values: [String]) -> [String] {
    values.flatMap { raw in
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }.filter { !$0.isEmpty }
}

func parseListArgument(_ value: String?) -> [String] {
    guard let value else { return [] }
    return parseListArgument([value])
}

/// True when a filter refers to Apple Notes' Recently Deleted smart folder.
func isRecentlyDeletedFolderName(_ name: String) -> Bool {
    name.compare("Recently Deleted", options: .caseInsensitive) == .orderedSame
}

/// Folder IDs matching `filters` (comma-separated or repeated).
/// Default match is exact folder id or case-insensitive exact name.
/// `matchContains` restores substring matching. Descendants are included unless disabled.
func matchingFolderIds(
    filters: [String],
    folders: [NotesFolder],
    matchContains: Bool = false,
    includeDescendants: Bool = true
) -> Set<String> {
    let tokens = parseListArgument(filters)
    guard !tokens.isEmpty else { return [] }

    var matched: Set<String> = []
    for token in tokens {
        if isRecentlyDeletedFolderName(token) { continue }
        let lowered = token.lowercased()
        let hits = folders.filter { folder in
            folder.id.caseInsensitiveCompare(token) == .orderedSame
                || folder.name.compare(token, options: .caseInsensitive) == .orderedSame
                || (matchContains && folder.name.lowercased().contains(lowered))
        }
        for folder in hits { matched.insert(folder.id) }
    }

    guard !matched.isEmpty else { return matched }
    guard includeDescendants else { return matched }

    var childrenByParent: [String: [String]] = [:]
    for folder in folders {
        if let parent = folder.parentId {
            childrenByParent[parent, default: []].append(folder.id)
        }
    }

    var stack = Array(matched)
    while let current = stack.popLast() {
        for child in childrenByParent[current] ?? [] {
            if matched.insert(child).inserted {
                stack.append(child)
            }
        }
    }
    return matched
}

func matchingFolderIds(filter: String, folders: [NotesFolder]) -> Set<String> {
    matchingFolderIds(filters: [filter], folders: folders, matchContains: false, includeDescendants: true)
}

/// Folder filters the user asked for that match no folder in the library.
///
/// An empty match set is indistinguishable from "no filter requested" once it
/// reaches `selectedNotes`, so a mistyped `--folder` would otherwise select the
/// whole library instead of nothing. Callers use this to fail loudly instead.
/// The Recently Deleted smart folder is not a real folder row, so it never
/// counts as unmatched.
func unmatchedFolderFilters(
    filters: [String],
    folders: [NotesFolder],
    matchContains: Bool = false
) -> [String] {
    parseListArgument(filters).filter { token in
        if isRecentlyDeletedFolderName(token) { return false }
        let lowered = token.lowercased()
        return !folders.contains { folder in
            folder.id.caseInsensitiveCompare(token) == .orderedSame
                || folder.name.compare(token, options: .caseInsensitive) == .orderedSame
                || (matchContains && folder.name.lowercased().contains(lowered))
        }
    }
}

func applyNoteSelection(
    notes: [NotesNote],
    folders: [NotesFolder],
    folderFilters: [String],
    matchContains: Bool,
    includeSubfolders: Bool,
    includeDeleted: Bool,
    noteIds: [String]
) -> [NotesNote] {
    let tokens = parseListArgument(folderFilters)
    let wantsTrash = tokens.contains { isRecentlyDeletedFolderName($0) }
    let keepDeleted = includeDeleted || wantsTrash
    let folderIds = matchingFolderIds(
        filters: tokens,
        folders: folders,
        matchContains: matchContains,
        includeDescendants: includeSubfolders
    )
    return selectedNotes(
        from: notes,
        folderIds: folderIds,
        noteIds: Set(parseListArgument(noteIds)),
        includeDeleted: keepDeleted,
        selectAllTrash: wantsTrash
    )
}

/// Apply CLI/MCP note selection: listed note ids UNION notes in matching folders.
/// `includeDeleted` keeps Recently Deleted notes in the pool.
/// `selectAllTrash` is set when a filter is the Recently Deleted smart folder.
func selectedNotes(
    from notes: [NotesNote],
    folderIds: Set<String>,
    noteIds: Set<String>,
    includeDeleted: Bool,
    selectAllTrash: Bool
) -> [NotesNote] {
    if selectAllTrash && folderIds.isEmpty && noteIds.isEmpty {
        return notes.filter(\.isDeleted)
    }

    return notes.filter { note in
        if !includeDeleted && note.isDeleted { return false }

        if folderIds.isEmpty && noteIds.isEmpty {
            return true
        }
        if !noteIds.isEmpty && noteIds.contains(note.id) {
            return true
        }
        if note.isDeleted {
            if selectAllTrash { return true }
            return !folderIds.isEmpty && folderIds.contains(note.folderId)
        }
        return !folderIds.isEmpty && folderIds.contains(note.folderId)
    }
}

/// Directory and HTML-relative prefix for a note's attachments.
func attachmentExportLocation(
    sharedDump: Bool,
    outputRoot: URL,
    noteDirectory: URL,
    noteBaseName: String,
    filename: String
) -> (directory: URL, relativePath: String) {
    if !sharedDump {
        let dir = noteDirectory.appendingPathComponent("\(noteBaseName) (Attachments)")
        return (dir, "\(noteBaseName) (Attachments)/\(filename)")
    }

    let rootPath = outputRoot.standardizedFileURL.path
    let dirPath = noteDirectory.standardizedFileURL.path
    let relDir: String
    if dirPath == rootPath {
        relDir = ""
    } else if dirPath.hasPrefix(rootPath + "/") {
        relDir = String(dirPath.dropFirst(rootPath.count + 1))
    } else {
        relDir = ""
    }

    var attRel = "Attachments"
    if !relDir.isEmpty { attRel += "/\(relDir)" }
    attRel += "/\(noteBaseName)/\(filename)"

    let noteRel = relDir.isEmpty ? "note.ext" : "\(relDir)/note.ext"
    let href = relativePathFromSource(noteRel, toTarget: attRel)
    let dir = outputRoot.appendingPathComponent(
        attRel.split(separator: "/").dropLast().map(String.init).joined(separator: "/"),
        isDirectory: true
    )
    return (dir, href)
}

/// Marker comment written into generated folder index.html files so a later
/// export can tell them apart from a note that happened to be titled "index".
let htmlFolderIndexMarker = "apple-notes-exporter-folder-index"

/// Write an `index.html` listing in each directory under `root` that contains
/// exported HTML notes or subfolders. Skips `* (Attachments)` directories.
func writeHTMLFolderIndexes(underRoot root: URL) throws {
    let fm = FileManager.default
    var dirs: [URL] = [root]
    let keys: [URLResourceKey] = [.isDirectoryKey]
    if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            if url.lastPathComponent.hasSuffix(" (Attachments)") || url.lastPathComponent == "Attachments" {
                enumerator.skipDescendants()
                continue
            }
            dirs.append(url)
        }
    }
    dirs.sort { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }
    for dir in dirs {
        try writeHTMLFolderIndex(inFolder: dir)
    }
}

/// Write a single folder's `index.html` listing sibling HTML notes and subfolders.
func writeHTMLFolderIndex(inFolder folderURL: URL) throws {
    let fm = FileManager.default
    let contents = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

    var subfolders: [URL] = []
    var notes: [URL] = []
    for url in contents {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true {
            if !url.lastPathComponent.hasSuffix(" (Attachments)") && url.lastPathComponent != "Attachments" {
                subfolders.append(url)
            }
            continue
        }
        if url.pathExtension.lowercased() == "html" && url.lastPathComponent.lowercased() != "index.html" {
            notes.append(url)
        }
    }

    let indexURL = folderURL.appendingPathComponent("index.html")
    if fm.fileExists(atPath: indexURL.path),
       let existing = try? String(contentsOf: indexURL, encoding: .utf8),
       !existing.contains(htmlFolderIndexMarker) {
        // A note was exported as index.html (older builds). Move it aside.
        let renamed = generateUniqueExportFilename(baseName: "index", extension: "html", inDirectory: folderURL)
        try fm.moveItem(at: indexURL, to: folderURL.appendingPathComponent(renamed))
        notes.append(folderURL.appendingPathComponent(renamed))
    }

    notes.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    subfolders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

    guard !notes.isEmpty || !subfolders.isEmpty else { return }

    func href(_ filename: String) -> String {
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return encoded.htmlEscaped
    }

    var items: [String] = []
    for sub in subfolders {
        let name = sub.lastPathComponent.htmlEscaped
        items.append("    <li><a href=\"\(href(sub.lastPathComponent))/index.html\">\(name)/</a></li>")
    }
    for note in notes {
        let name = note.deletingPathExtension().lastPathComponent.htmlEscaped
        items.append("    <li><a href=\"\(href(note.lastPathComponent))\">\(name)</a></li>")
    }

    let folderName = folderURL.lastPathComponent.htmlEscaped
    let html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <title>\(folderName)</title>
      <!-- \(htmlFolderIndexMarker) -->
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 2em; line-height: 1.5; }
        h1 { font-size: 1.4em; }
        ul { padding-left: 1.2em; }
      </style>
    </head>
    <body>
      <h1>\(folderName)</h1>
      <ul>
    \(items.joined(separator: "\n"))
      </ul>
    </body>
    </html>
    """
    try html.write(to: indexURL, atomically: true, encoding: .utf8)
}

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
        accountId: note.accountId, attachments: note.attachments,
        identifier: note.identifier,
        isDeleted: note.isDeleted
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
