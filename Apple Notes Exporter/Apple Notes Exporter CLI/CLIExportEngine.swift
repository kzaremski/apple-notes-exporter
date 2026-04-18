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
import HtmlToPdf

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

    /// Map of note ID to relative file path (from output root), populated at the start of each export
    /// and used to rewrite applenotes:note/UUID links in generated HTML.
    private var internalLinkMap: [String: String] = [:]

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
                // Nothing to re-export, but we still need to prune notes that
                // have been deleted from Apple Notes since the last sync.
                let presentIds = Set(notes.map { $0.id })
                let removed = await syncTracker!.pruneDeleted(presentNoteIds: presentIds)
                for entry in removed {
                    deleteExportedNoteFiles(outputRoot: outputURL, entry: entry)
                    if verbose { CLIOutput.writeStderr("Deleted (no longer in Notes): \(entry.exportedPath)") }
                }
                if verbose {
                    let msg = removed.isEmpty
                        ? "All notes are up to date, nothing to export."
                        : "All present notes are up to date; pruned \(removed.count) deleted note(s)."
                    CLIOutput.writeStderr(msg)
                }
                var updatedManifest = await syncTracker!.getManifest()
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
            let accountURL = outputURL.appendingPathComponent(sanitizeExportFilename(accountName))
            try FileManager.default.createDirectory(at: accountURL, withIntermediateDirectories: true)
            for (folderPath, _) in folders {
                let folderURL = accountURL.appendingPathComponent(folderPath)
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            }
        }

        // Flatten for concurrent export
        var notesWithPaths: [(note: NotesNote, folderURL: URL)] = []
        for (accountName, folders) in hierarchy {
            let accountURL = outputURL.appendingPathComponent(sanitizeExportFilename(accountName))
            for (folderPath, folderNotes) in folders {
                let folderURL = accountURL.appendingPathComponent(folderPath)
                for note in folderNotes {
                    notesWithPaths.append((note: note, folderURL: folderURL))
                }
            }
        }

        // Pre-allocate filenames so applenotes:note/UUID links can be rewritten
        // to real relative paths during rendering.
        self.internalLinkMap = buildInternalLinkPathMap(
            allNotes: notes,
            notesWithPaths: notesWithPaths,
            outputRoot: outputURL,
            format: format,
            addDatePrefix: configurations.addDateToFilename,
            dateFormat: configurations.filenameDateFormat.rawValue,
            existingManifest: existingManifest
        )
        defer { self.internalLinkMap = [:] }

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
        try await setExportFolderTimestamps(hierarchy: hierarchy, outputURL: outputURL)

        // Prune deleted notes from the manifest, remove their files, then save.
        if let syncTracker = syncTracker {
            let presentIds = Set(notes.map { $0.id })
            let removed = await syncTracker.pruneDeleted(presentNoteIds: presentIds)
            for entry in removed {
                deleteExportedNoteFiles(outputRoot: outputURL, entry: entry)
                if verbose { CLIOutput.writeStderr("Deleted (no longer in Notes): \(entry.exportedPath)") }
            }
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
        default:        separator = "\n\n---\n\n"
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
        } else if let preAllocated = internalLinkMap[note.id] {
            // Use the pre-allocated filename so applenotes:note/UUID links
            // we're rewriting in other notes resolve to this actual file.
            let filename = (preAllocated as NSString).lastPathComponent
            fileURL = directory.appendingPathComponent(filename)
            uniqueBaseName = filename.replacingOccurrences(of: ".\(format.fileExtension)", with: "")
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
            let filename = generateUniqueExportFilename(baseName: baseFilename, extension: format.fileExtension, inDirectory: directory)
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

        if format == .pdf {
            try await renderPDF(for: note, to: fileURL, attachmentPaths: attachmentPaths, exportDirectory: directory)
        } else if format.isBinaryFormat {
            let data = try await generateBinaryContent(for: note, format: format, attachmentPaths: attachmentPaths, exportDirectory: directory)
            try data.write(to: fileURL)
        } else {
            let content = try await generateContent(for: note, format: format, attachmentPaths: attachmentPaths, exportDirectory: directory)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        try setExportFileTimestamps(fileURL, creationDate: note.creationDate, modificationDate: note.modificationDate)

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
                    let (name, ext) = splitExportFilename(baseFilename)
                    finalFilename = "\(name) (\(count + 1)).\(ext)"
                    usedFilenames[baseFilename] = count + 1
                } else {
                    finalFilename = baseFilename
                    usedFilenames[baseFilename] = 1
                }

                let fileURL = attachmentsURL.appendingPathComponent(finalFilename)
                try data.write(to: fileURL)
                try setExportFileTimestamps(fileURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)

                let relativePath = "\(noteBaseName) (Attachments)/\(finalFilename)"
                attachmentPaths[attachment.id] = relativePath
            } catch {
                await tracker.attachmentFailed()
            }
        }

        if !fileAttachments.isEmpty {
            try setExportFileTimestamps(attachmentsURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)
        }

        return attachmentPaths
    }

    // MARK: - Content Generation

    private func renderPDF(
        for note: NotesNote,
        to fileURL: URL,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil
    ) async throws {
        let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory, forPDF: true)

        let dims = configurations.pdf.pageSize.dimensions
        let paperSize = CGSize(width: dims.width, height: dims.height)
        let margins = configurations.pdf.htmlConfiguration.toPDFEdgeInsets()
        let config = HtmlToPdf.PDFConfiguration(margins: margins, paperSize: paperSize)

        // PDF rendering has a hard timeout to protect against WebKit hangs
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await html.print(to: fileURL, configuration: config)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw CLIError.fileSystemError("PDF generation timed out after 60 seconds for note '\(note.title)'")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func generateBinaryContent(
        for note: NotesNote,
        format: ExportFormat,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil
    ) async throws -> Data {
        let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
        let enrichedNote = noteWithHTML(note, html: html)
        switch format {
        case .docx: return enrichedNote.toDOCX()
        case .odt:  return enrichedNote.toODT()
        case .epub: return enrichedNote.toEPUB()
        default:    throw CLIError.unsupportedFormat(format)
        }
    }

    private func generateContent(
        for note: NotesNote,
        format: ExportFormat,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil
    ) async throws -> String {
        if format == .pdf {
            throw CLIError.unsupportedFormat(format)
        }
        let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
        if format == .html { return html }
        let enrichedNote = noteWithHTML(note, html: html)
        return generateExportTextContent(for: enrichedNote, format: format, folderName: nil, accountName: nil)
    }

    private func generateHTML(
        for note: NotesNote,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil,
        forPDF: Bool = false
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

        // Rewrite Apple Notes internal links (applenotes:note/UUID?...) to relative paths.
        var bodyAfterLinkRewrite = htmlBody
        if let currentPath = internalLinkMap[note.id], !internalLinkMap.isEmpty {
            bodyAfterLinkRewrite = rewriteInternalLinks(
                html: htmlBody,
                currentNoteRelativePath: currentPath,
                noteIdToRelativePath: internalLinkMap
            )
        }

        var processedHTML = bodyAfterLinkRewrite
        if !note.attachments.isEmpty {
            if let parserHandle = ane_open(databasePath) {
                defer { ane_close(parserHandle) }
                if let rawHandle = ane_get_sqlite_handle(parserHandle) {
                    let database = OpaquePointer(rawHandle)
                    let processor = HTMLAttachmentProcessor(database: database)
                    processedHTML = processor.processHTML(
                        html: bodyAfterLinkRewrite,
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
        let marginValue = forPDF ? "0" : "\(htmlConfig.marginSize)\(htmlConfig.marginUnit.displayName) auto"

        // For PDF, constrain image height to stay within the safe print area
        let imageConstraint: String
        if forPDF {
            // Conservative: assume a default 36pt top+bottom margin, then 20pt padding.
            let dims = configurations.pdf.pageSize.dimensions
            let safe = max(100, dims.height - 72 - 20)
            imageConstraint = "max-height: \(Int(safe))pt; height: auto;"
        } else {
            imageConstraint = ""
        }

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
                    margin: \(marginValue);
                    padding: 0 20px;
                    line-height: 1.0;
                }
                h1, h2, h3, h4, h5, h6, p { margin: 0; padding: 0; line-height: 1.0; }
                ul, ol { margin: 0; margin-left: 1.5em; padding: 0; padding-left: 0.5em; }
                li { margin: 0; padding: 0; line-height: 1.0; }
                img { max-width: 100%; \(imageConstraint) }
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
            let accountKey = sanitizeExportFilename(accountName)
            let folderPath = buildExportFolderPath(folderId: note.folderId, folderLookup: folderLookup)

            result[accountKey, default: [:]][folderPath, default: []].append(note)
        }

        return result
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
