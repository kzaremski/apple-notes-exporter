//
//  CLIExportEngine.swift
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

import Foundation
import OSLog

// MARK: - CLI Export Engine

/// Headless export actor — contains all export logic extracted from ExportViewModel
/// with @MainActor / @Published machinery removed. Designed to be transport-agnostic
/// so a future MCP target can call it directly without subprocess overhead.
actor CLIExportEngine {

    // MARK: - Types

    struct ExportResult: Encodable {
        let success: Bool
        let exported: Int
        let skipped: Int
        let failed: Int
        let failedAttachments: Int
        let outputDirectory: String
        let format: String
        let durationSeconds: Double
    }

    // MARK: - Properties

    private let repository: NotesRepository
    let configurations: ExportConfigurations
    private let databasePath: String

    private var maxConcurrentExports: Int {
        let coreCount = ProcessInfo.processInfo.processorCount
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let totalMemoryGB = Int(ceil(Double(totalMemory) / 1_073_741_824.0))
        let memoryLimit = max(1, totalMemoryGB / 2)
        return max(1, min(min(coreCount, memoryLimit), 16))
    }

    // MARK: - Init

    init(
        databasePath: String = "\(NSHomeDirectory())/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite",
        configurations: ExportConfigurations = .default
    ) {
        self.databasePath = databasePath
        self.configurations = configurations
        self.repository = DatabaseNotesRepository(databasePath: databasePath)
    }

    // MARK: - Public API

    /// Export the given notes to outputURL in the specified format.
    func exportNotes(
        _ notes: [NotesNote],
        toDirectory outputURL: URL,
        format: ExportFormat,
        includeAttachments: Bool,
        verbose: Bool,
        progressHandler: @Sendable @escaping (Int, Int) -> Void
    ) async throws -> ExportResult {
        guard format != .pdf else {
            throw CLIError.unsupportedFormat(format)
        }

        let startTime = Date()

        // Incremental sync
        let isSync = configurations.incrementalSync
        let existingManifest = isSync ? SyncManifest.load(from: outputURL) : nil
        let syncTracker: SyncManifestTracker?

        let notesToExport: [NotesNote]
        if isSync, let manifest = existingManifest {
            notesToExport = manifest.notesNeedingExport(from: notes)
            syncTracker = SyncManifestTracker(manifest: manifest)
            if notesToExport.isEmpty {
                if verbose { CLIOutput.writeStderr("All notes are up to date, nothing to export.") }
                var updatedManifest = manifest
                updatedManifest.lastSync = Date()
                try updatedManifest.save(to: outputURL)
                return ExportResult(
                    success: true, exported: 0, skipped: notes.count, failed: 0, failedAttachments: 0,
                    outputDirectory: outputURL.path, format: format.fileExtension,
                    durationSeconds: Date().timeIntervalSince(startTime)
                )
            }
            if verbose { CLIOutput.writeStderr("Incremental sync: \(notesToExport.count) new/changed of \(notes.count) total") }
        } else {
            notesToExport = notes
            syncTracker = isSync ? SyncManifestTracker(manifest: .empty()) : nil
        }

        // Build account/folder hierarchy for output directory structure
        let hierarchy = try await organizeNotesByHierarchy(notesToExport)

        // Create directory structure
        for (accountName, folders) in hierarchy {
            let accountURL = outputURL.appendingPathComponent(sanitizeFilename(accountName))
            try FileManager.default.createDirectory(at: accountURL, withIntermediateDirectories: true)
            for (folderPath, _) in folders {
                let folderURL = accountURL.appendingPathComponent(folderPath)
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            }
        }

        // Flatten for concurrent export
        var notesWithPaths: [(note: NotesNote, folderURL: URL)] = []
        for (accountName, folders) in hierarchy {
            let accountURL = outputURL.appendingPathComponent(sanitizeFilename(accountName))
            for (folderPath, folderNotes) in folders {
                let folderURL = accountURL.appendingPathComponent(folderPath)
                for note in folderNotes {
                    notesWithPaths.append((note: note, folderURL: folderURL))
                }
            }
        }

        let tracker = ExportProgressTracker()

        if configurations.concatenateOutput {
            try await exportNotesConcatenated(
                notesWithPaths, format: format,
                includeAttachments: includeAttachments,
                outputURL: outputURL, verbose: verbose, tracker: tracker,
                progressHandler: progressHandler
            )
        } else {
            try await exportNotesConcurrently(
                notesWithPaths, format: format,
                includeAttachments: includeAttachments,
                totalNotes: notesToExport.count, startTime: startTime,
                syncTracker: syncTracker,
                syncManifest: existingManifest,
                outputRootURL: isSync ? outputURL : nil,
                verbose: verbose, tracker: tracker,
                progressHandler: progressHandler
            )
        }

        // Set folder timestamps
        try await setFolderTimestamps(hierarchy: hierarchy, outputURL: outputURL)

        // Save sync manifest
        if let syncTracker = syncTracker {
            let finalManifest = await syncTracker.getManifest()
            try finalManifest.save(to: outputURL)
        }

        let stats = await tracker.getStats()
        let duration = Date().timeIntervalSince(startTime)

        return ExportResult(
            success: stats.failedNotes == 0,
            exported: stats.completed,
            skipped: notes.count - notesToExport.count,
            failed: stats.failedNotes,
            failedAttachments: stats.failedAttachments,
            outputDirectory: outputURL.path,
            format: format.fileExtension,
            durationSeconds: duration
        )
    }

    // MARK: - Concurrent Export

    private func exportNotesConcurrently(
        _ notesWithPaths: [(note: NotesNote, folderURL: URL)],
        format: ExportFormat,
        includeAttachments: Bool,
        totalNotes: Int,
        startTime: Date,
        syncTracker: SyncManifestTracker?,
        syncManifest: SyncManifest?,
        outputRootURL: URL?,
        verbose: Bool,
        tracker: ExportProgressTracker,
        progressHandler: @Sendable @escaping (Int, Int) -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = notesWithPaths.makeIterator()
            var activeTaskCount = 0

            while activeTaskCount < maxConcurrentExports, let noteWithPath = iterator.next() {
                let overridePath = syncManifest?.existingPath(for: noteWithPath.note.id)
                group.addTask {
                    await self.exportNoteSafelyWrapped(
                        noteWithPath.note,
                        toDirectory: noteWithPath.folderURL,
                        format: format,
                        includeAttachments: includeAttachments,
                        tracker: tracker,
                        syncTracker: syncTracker,
                        overrideRelativePath: overridePath,
                        outputRootURL: outputRootURL,
                        verbose: verbose
                    )
                }
                activeTaskCount += 1
            }

            for try await _ in group {
                let stats = await tracker.getStats()
                progressHandler(stats.completed + stats.failedNotes, totalNotes)

                if let noteWithPath = iterator.next() {
                    let overridePath = syncManifest?.existingPath(for: noteWithPath.note.id)
                    group.addTask {
                        await self.exportNoteSafelyWrapped(
                            noteWithPath.note,
                            toDirectory: noteWithPath.folderURL,
                            format: format,
                            includeAttachments: includeAttachments,
                            tracker: tracker,
                            syncTracker: syncTracker,
                            overrideRelativePath: overridePath,
                            outputRootURL: outputRootURL,
                            verbose: verbose
                        )
                    }
                }
            }
        }
    }

    private func exportNotesConcatenated(
        _ notesWithPaths: [(note: NotesNote, folderURL: URL)],
        format: ExportFormat,
        includeAttachments: Bool,
        outputURL: URL,
        verbose: Bool,
        tracker: ExportProgressTracker,
        progressHandler: @Sendable @escaping (Int, Int) -> Void
    ) async throws {
        var contentParts: [String] = []
        let total = notesWithPaths.count

        for (index, noteWithPath) in notesWithPaths.enumerated() {
            let note = noteWithPath.note
            progressHandler(index, total)
            do {
                var attachmentPaths: [String: String] = [:]
                if includeAttachments && note.hasAttachments {
                    attachmentPaths = try await exportAttachmentsAndReturnPaths(
                        note.attachments, toDirectory: outputURL,
                        noteBaseName: note.sanitizedFileName,
                        noteTitle: note.title,
                        noteCreationDate: note.creationDate,
                        noteModificationDate: note.modificationDate,
                        tracker: tracker
                    )
                }
                let content = try await generateContent(for: note, format: format, attachmentPaths: attachmentPaths, exportDirectory: outputURL)
                contentParts.append(content)
                if verbose { CLIOutput.writeStderr("✓ Processed: \(note.title)") }
            } catch {
                await tracker.noteFailed()
                if verbose { CLIOutput.writeStderr("✗ Failed: \(note.title) — \(error.localizedDescription)") }
            }
        }

        let separator: String
        switch format {
        case .html:     separator = "\n<hr style=\"page-break-after: always;\">\n"
        case .markdown: separator = "\n\n---\n\n"
        case .txt:      separator = "\n\n" + String(repeating: "=", count: 72) + "\n\n"
        case .rtf:      separator = "\n\\page\n"
        case .tex:      separator = "\n\n\\newpage\n\n"
        case .pdf:      separator = ""  // unreachable — blocked upstream
        }

        let concatenated = contentParts.joined(separator: separator)
        let filename = "Exported Notes.\(format.fileExtension)"
        let fileURL = outputURL.appendingPathComponent(filename)
        try concatenated.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Single Note Export

    private func exportNoteSafelyWrapped(
        _ note: NotesNote,
        toDirectory directory: URL,
        format: ExportFormat,
        includeAttachments: Bool,
        tracker: ExportProgressTracker,
        syncTracker: SyncManifestTracker?,
        overrideRelativePath: String?,
        outputRootURL: URL?,
        verbose: Bool
    ) async {
        do {
            try await exportNoteSafely(
                note, toDirectory: directory, format: format,
                includeAttachments: includeAttachments,
                tracker: tracker, syncTracker: syncTracker,
                overrideRelativePath: overrideRelativePath,
                outputRootURL: outputRootURL
            )
            _ = await tracker.noteCompleted()
            if verbose { CLIOutput.writeStderr("✓ Exported: \(note.title)") }
        } catch {
            await tracker.noteFailed()
            if verbose { CLIOutput.writeStderr("✗ Failed: \(note.title) — \(error.localizedDescription)") }
        }
    }

    private func exportNoteSafely(
        _ note: NotesNote,
        toDirectory directory: URL,
        format: ExportFormat,
        includeAttachments: Bool,
        tracker: ExportProgressTracker,
        syncTracker: SyncManifestTracker?,
        overrideRelativePath: String?,
        outputRootURL: URL?
    ) async throws {
        try Task.checkCancellation()

        let fileURL: URL
        let uniqueBaseName: String

        if let relativePath = overrideRelativePath, let rootURL = outputRootURL {
            fileURL = rootURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            uniqueBaseName = fileURL.deletingPathExtension().lastPathComponent
        } else {
            let baseFilename: String
            if configurations.addDateToFilename {
                let formatter = DateFormatter()
                formatter.dateFormat = configurations.filenameDateFormat.rawValue
                let datePrefix = formatter.string(from: note.creationDate)
                baseFilename = "\(datePrefix) \(note.sanitizedFileName)"
            } else {
                baseFilename = note.sanitizedFileName
            }
            let filename = generateUniqueFilename(baseName: baseFilename, extension: format.fileExtension, inDirectory: directory)
            fileURL = directory.appendingPathComponent(filename)
            uniqueBaseName = filename.replacingOccurrences(of: ".\(format.fileExtension)", with: "")
        }

        var attachmentPaths: [String: String] = [:]
        if includeAttachments && note.hasAttachments {
            try Task.checkCancellation()
            attachmentPaths = try await exportAttachmentsAndReturnPaths(
                note.attachments, toDirectory: directory,
                noteBaseName: uniqueBaseName,
                noteTitle: note.title,
                noteCreationDate: note.creationDate,
                noteModificationDate: note.modificationDate,
                tracker: tracker
            )
        }

        let content = try await generateContent(for: note, format: format, attachmentPaths: attachmentPaths, exportDirectory: directory)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        try setFileTimestamps(fileURL, creationDate: note.creationDate, modificationDate: note.modificationDate)

        if let syncTracker = syncTracker, let rootURL = outputRootURL {
            let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            let attachmentRelPaths = attachmentPaths.values.map { path -> String in
                let noteDir = directory.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                return noteDir.isEmpty ? path : "\(noteDir)/\(path)"
            }
            await syncTracker.recordExport(
                noteId: note.id,
                modificationDate: note.modificationDate,
                exportedPath: relativePath,
                attachmentPaths: attachmentRelPaths
            )
        }
    }

    // MARK: - Attachment Export

    private func exportAttachmentsAndReturnPaths(
        _ attachments: [NotesAttachment],
        toDirectory directory: URL,
        noteBaseName: String,
        noteTitle: String,
        noteCreationDate: Date,
        noteModificationDate: Date,
        tracker: ExportProgressTracker
    ) async throws -> [String: String] {
        var attachmentPaths: [String: String] = [:]

        let nonFileAttachmentPrefixes = [
            "com.apple.notes.table",
            "com.apple.notes.inlinetextattachment",
            "com.apple.notes.inlinehashtagattachment",
            "com.apple.notes.inlinementionattachment",
            "public.url"
        ]

        let fileAttachments = attachments.filter { attachment in
            !nonFileAttachmentPrefixes.contains { attachment.typeUTI.hasPrefix($0) }
        }

        guard !fileAttachments.isEmpty else { return attachmentPaths }

        let attachmentsURL = directory.appendingPathComponent("\(noteBaseName) (Attachments)")
        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        var usedFilenames: [String: Int] = [:]

        for attachment in fileAttachments {
            try Task.checkCancellation()
            do {
                let data = try await repository.fetchAttachment(id: attachment.id)

                let baseFilename: String
                if let filename = attachment.filename {
                    baseFilename = filename
                } else if let fetchedFilename = await repository.fetchAttachmentFilename(id: attachment.id) {
                    baseFilename = fetchedFilename
                } else {
                    baseFilename = "\(attachment.id).\(attachment.fileExtension ?? "bin")"
                }

                let finalFilename: String
                if let count = usedFilenames[baseFilename] {
                    let (name, ext) = splitFilename(baseFilename)
                    finalFilename = "\(name) (\(count + 1)).\(ext)"
                    usedFilenames[baseFilename] = count + 1
                } else {
                    finalFilename = baseFilename
                    usedFilenames[baseFilename] = 1
                }

                let fileURL = attachmentsURL.appendingPathComponent(finalFilename)
                try data.write(to: fileURL)
                try setFileTimestamps(fileURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)

                let relativePath = "\(noteBaseName) (Attachments)/\(finalFilename)"
                attachmentPaths[attachment.id] = relativePath
            } catch {
                await tracker.attachmentFailed()
            }
        }

        if !fileAttachments.isEmpty {
            try setFileTimestamps(attachmentsURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)
        }

        return attachmentPaths
    }

    // MARK: - Content Generation

    private func generateContent(
        for note: NotesNote,
        format: ExportFormat,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil
    ) async throws -> String {
        switch format {
        case .html:
            return try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
        case .txt:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            return makeNote(note, html: html).toPlainText()
        case .markdown:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            return makeNote(note, html: html).toMarkdown()
        case .rtf:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            return makeNote(note, html: html).toRTF(
                fontFamily: configurations.rtf.fontFamily.rtfFontName,
                fontSize: configurations.rtf.fontSizePoints
            )
        case .tex:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            return makeNote(note, html: html).toLatex(template: configurations.latex.template)
        case .pdf:
            throw CLIError.unsupportedFormat(format)
        }
    }

    private func makeNote(_ note: NotesNote, html: String) -> NotesNote {
        NotesNote(
            id: note.id, title: note.title, plaintext: note.plaintext,
            htmlBody: html,
            creationDate: note.creationDate, modificationDate: note.modificationDate,
            folderId: note.folderId, accountId: note.accountId,
            attachments: note.attachments
        )
    }

    private func generateHTML(
        for note: NotesNote,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil
    ) async throws -> String {
        let htmlConfig = configurations.html

        let htmlBody: String
        if let existingHTML = note.htmlBody {
            htmlBody = existingHTML
        } else {
            do {
                htmlBody = try await repository.generateHTML(forNoteId: note.id)
            } catch {
                // Fallback to plaintext
                htmlBody = "<html><body><pre>\(note.plaintext.htmlEscaped)</pre></body></html>"
            }
        }

        var processedHTML = htmlBody
        if !note.attachments.isEmpty {
            if let parserHandle = ane_open(databasePath) {
                defer { ane_close(parserHandle) }
                if let rawHandle = ane_get_sqlite_handle(parserHandle) {
                    let database = OpaquePointer(rawHandle)
                    let processor = HTMLAttachmentProcessor(database: database)
                    processedHTML = processor.processHTML(
                        html: htmlBody,
                        attachments: note.attachments,
                        attachmentPaths: attachmentPaths,
                        exportDirectory: exportDirectory?.path,
                        embedImages: htmlConfig.embedImagesInline,
                        linkEmbeddedImages: htmlConfig.linkEmbeddedImages
                    )
                }
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let fontFamily = htmlConfig.fontFamily.cssFontStack
        let fontSize = "\(htmlConfig.fontSizePoints)pt"
        let marginValue = "\(htmlConfig.marginSize)\(htmlConfig.marginUnit.displayName)"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <meta name="created" content="\(dateFormatter.string(from: note.creationDate))">
            <meta name="modified" content="\(dateFormatter.string(from: note.modificationDate))">
            <title>\(note.title.htmlEscaped)</title>
            <style>
                body {
                    font-family: \(fontFamily);
                    font-size: \(fontSize);
                    max-width: 800px;
                    margin: \(marginValue) auto;
                    padding: 0 20px;
                    line-height: 1.0;
                }
                h1, h2, h3, h4, h5, h6, p { margin: 0; padding: 0; line-height: 1.0; }
                ul, ol { margin: 0; margin-left: 1.5em; padding: 0; padding-left: 0.5em; }
                li { margin: 0; padding: 0; line-height: 1.0; }
                img { max-width: 100%; }
            </style>
        </head>
        <body>
            <div class="content">
                \(processedHTML)
            </div>
        </body>
        </html>
        """
    }

    // MARK: - Hierarchy Organisation

    func organizeNotesByHierarchy(_ notes: [NotesNote]) async throws -> [String: [String: [NotesNote]]] {
        var result: [String: [String: [NotesNote]]] = [:]

        let accounts = try await repository.fetchAccounts()
        let folders = try await repository.fetchFolders()

        var accountLookup: [String: String] = [:]
        for account in accounts { accountLookup[account.id] = account.name }

        var folderLookup: [String: NotesFolder] = [:]
        for folder in folders { folderLookup[folder.id] = folder }

        for note in notes {
            let accountName = accountLookup[note.accountId] ?? "Unknown Account"
            let accountKey = sanitizeFilename(accountName)
            let folderPath = buildFolderPath(folderId: note.folderId, folderLookup: folderLookup)

            result[accountKey, default: [:]][folderPath, default: []].append(note)
        }

        return result
    }

    private func buildFolderPath(folderId: String, folderLookup: [String: NotesFolder]) -> String {
        guard let folder = folderLookup[folderId] else { return sanitizeFilename("Unknown Folder") }

        var components: [String] = [sanitizeFilename(folder.name)]
        var currentParentId = folder.parentId
        while let parentId = currentParentId, let parentFolder = folderLookup[parentId] {
            components.insert(sanitizeFilename(parentFolder.name), at: 0)
            currentParentId = parentFolder.parentId
        }
        return components.joined(separator: "/")
    }

    // MARK: - Helpers

    private func setFileTimestamps(_ fileURL: URL, creationDate: Date, modificationDate: Date) throws {
        let attributes: [FileAttributeKey: Any] = [
            .creationDate: creationDate,
            .modificationDate: modificationDate
        ]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path)
    }

    private func setFolderTimestamps(hierarchy: [String: [String: [NotesNote]]], outputURL: URL) async throws {
        for (accountName, folders) in hierarchy {
            let accountURL = outputURL.appendingPathComponent(sanitizeFilename(accountName))
            var accountOldest: Date?
            var accountLatest: Date?

            for (folderPath, notes) in folders {
                guard !notes.isEmpty else { continue }
                let folderURL = accountURL.appendingPathComponent(folderPath)
                let oldest = notes.map { $0.creationDate }.min() ?? Date()
                let latest = notes.map { $0.modificationDate }.max() ?? Date()
                try setFileTimestamps(folderURL, creationDate: oldest, modificationDate: latest)
                if accountOldest == nil || oldest < accountOldest! { accountOldest = oldest }
                if accountLatest == nil || latest > accountLatest! { accountLatest = latest }
            }
            if let o = accountOldest, let l = accountLatest {
                try setFileTimestamps(accountURL, creationDate: o, modificationDate: l)
            }
        }
    }

    func sanitizeFilename(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.newlines).union(.illegalCharacters).union(.controlCharacters)
        return name.components(separatedBy: invalidCharacters).joined(separator: "_")
    }

    private func generateUniqueFilename(baseName: String, extension ext: String, inDirectory directory: URL) -> String {
        let initial = "\(baseName).\(ext)"
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(initial).path) { return initial }
        var counter = 2
        while counter <= 10000 {
            let candidate = "\(baseName) (\(counter)).\(ext)"
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) { return candidate }
            counter += 1
        }
        return "\(baseName)_\(UUID().uuidString).\(ext)"
    }

    private func splitFilename(_ filename: String) -> (name: String, ext: String) {
        if let lastDot = filename.lastIndex(of: "."), lastDot != filename.startIndex {
            return (String(filename[..<lastDot]), String(filename[filename.index(after: lastDot)...]))
        }
        return (filename, "")
    }

    // MARK: - Repository Access (for list commands)

    func fetchAccounts() async throws -> [NotesAccount] {
        try await repository.fetchAccounts()
    }

    func fetchFolders() async throws -> [NotesFolder] {
        try await repository.fetchFolders()
    }

    func fetchNotes() async throws -> [NotesNote] {
        try await repository.fetchNotes()
    }
}
