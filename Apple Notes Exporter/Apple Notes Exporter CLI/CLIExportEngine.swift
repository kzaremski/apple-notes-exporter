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
        databasePath: String = defaultNotesDatabasePath(),
        configurations: ExportConfigurations = .default
    ) {
        self.databasePath = resolvedFilePath(databasePath)
        self.configurations = configurations
        self.repository = DatabaseNotesRepository(databasePath: self.databasePath)
    }

    // MARK: - Public API

    /// Export the given notes to outputURL in the specified format.
    func exportNotes(
        _ notes: [NotesNote],
        toDirectory outputURL: URL,
        format: ExportFormat,
        includeAttachments: Bool,
        verbose: Bool,
        allKnownNoteIds: Set<String>? = nil,
        progressHandler: @Sendable @escaping (Int, Int) -> Void
    ) async throws -> ExportResult {
        let startTime = Date()

        // Incremental sync
        let isSync = configurations.incrementalSync
        let existingManifest = isSync ? SyncManifest.load(from: outputURL) : nil
        let syncTracker: SyncManifestTracker?

        let notesToExport: [NotesNote]
        var activeManifest = existingManifest
        if isSync, var manifest = existingManifest {
            // Repair entries that point somewhere the note no longer belongs.
            // Older versions parked unresolvable notes in "Unknown Folder" and
            // then overwrote them there forever; the same applies to a note the
            // user has since moved between folders in Apple Notes.
            let accounts = try await repository.fetchAccounts()
            let folders = try await repository.fetchFolders()
            var accountLookup: [String: String] = [:]
            for account in accounts { accountLookup[account.id] = account.name }
            var folderLookup: [String: NotesFolder] = [:]
            for folder in folders { folderLookup[folder.id] = folder }

            let relocated = healManifestPaths(
                manifest: &manifest,
                notes: notes,
                accountLookup: accountLookup,
                folderLookup: folderLookup,
                outputRoot: outputURL
            )
            if verbose && !relocated.isEmpty {
                CLIOutput.writeStderr("Relocating \(relocated.count) note(s) whose export folder changed.")
            }
            activeManifest = manifest

            notesToExport = manifest.notesNeedingExport(from: notes)
            syncTracker = SyncManifestTracker(manifest: manifest)
            if notesToExport.isEmpty {
                // Nothing to re-export, but we still need to prune notes that
                // have been deleted from Apple Notes since the last sync.
                // Prune against every note in the library, not just this
                // run's selection: a narrower --folder must not make previously
                // exported notes look deleted and take their files with it.
                let presentIds = allKnownNoteIds.map { $0.union(notes.map(\.id)) } ?? Set(notes.map(\.id))
                let removed = await syncTracker!.pruneDeleted(presentNoteIds: presentIds)
                for pruned in removed {
                    deleteExportedNoteFiles(outputRoot: outputURL, entry: pruned.entry)
                    if verbose { CLIOutput.writeStderr("Deleted (no longer in Notes): \(pruned.entry.exportedPath)") }
                }
                if verbose {
                    let msg = removed.isEmpty
                        ? "All notes are up to date, nothing to export."
                        : "All present notes are up to date; pruned \(removed.count) deleted note(s)."
                    CLIOutput.writeStderr(msg)
                }
                await syncTracker!.finishRun(pruned: removed)
                let updatedManifest = await syncTracker!.getManifest()
                try updatedManifest.save(to: outputURL)
                if format == .html && !configurations.concatenateOutput && configurations.html.writeFolderIndexes {
                    try writeHTMLFolderIndexes(underRoot: outputURL)
                }
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

        // Create directory structure. Concatenating writes one file and no
        // tree, so creating it would leave empty account and folder directories
        // beside the file, and when --output names the file it would create a
        // directory at that exact path for the final write to collide with.
        if !configurations.concatenateOutput {
            for (accountName, folders) in hierarchy {
                let accountURL = outputURL.appendingPathComponent(sanitizeExportFilename(accountName))
                try FileManager.default.createDirectory(at: accountURL, withIntermediateDirectories: true)
                for (folderPath, _) in folders {
                    let folderURL = accountURL.appendingPathComponent(folderPath)
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                }
            }
        }

        // Flatten for concurrent export
        let notesWithPaths = flattenExportHierarchy(hierarchy, outputRoot: outputURL)

        // Pre-allocate filenames so applenotes:note/UUID links can be rewritten
        // to real relative paths during rendering.
        self.internalLinkMap = buildInternalLinkPathMap(
            allNotes: notes,
            notesWithPaths: notesWithPaths.map { (note: $0.note, folderURL: $0.folderURL) },
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
                syncManifest: activeManifest,
                outputRootURL: outputURL,
                verbose: verbose, tracker: tracker,
                progressHandler: progressHandler
            )
        }

        // Set folder timestamps. Concatenating creates no tree (see above), and
        // stamping a directory that was never created throws, which would fail
        // the run after the file had already been written successfully.
        if !configurations.concatenateOutput {
            try await setExportFolderTimestamps(hierarchy: hierarchy, outputURL: outputURL)
        }

        // Prune deleted notes from the manifest, remove their files, then save.
        if let syncTracker = syncTracker {
            // See above: "present" means present in Apple Notes, not present
            // in this run's filtered selection.
            let presentIds = allKnownNoteIds.map { $0.union(notes.map(\.id)) } ?? Set(notes.map(\.id))
            let removed = await syncTracker.pruneDeleted(presentNoteIds: presentIds)
            for pruned in removed {
                deleteExportedNoteFiles(outputRoot: outputURL, entry: pruned.entry)
                if verbose { CLIOutput.writeStderr("Deleted (no longer in Notes): \(pruned.entry.exportedPath)") }
            }
            await syncTracker.finishRun(pruned: removed)
            let finalManifest = await syncTracker.getManifest()
            try finalManifest.save(to: outputURL)
        }

        if format == .html && !configurations.concatenateOutput && configurations.html.writeFolderIndexes {
            try writeHTMLFolderIndexes(underRoot: outputURL)
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
        _ notesWithPaths: [(note: NotesNote, folderURL: URL, folderName: String, accountName: String)],
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
                        folderName: noteWithPath.folderName,
                        accountName: noteWithPath.accountName,
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
                            folderName: noteWithPath.folderName,
                            accountName: noteWithPath.accountName,
                            verbose: verbose
                        )
                    }
                }
            }
        }
    }

    private func exportNotesConcatenated(
        _ notesWithPaths: [(note: NotesNote, folderURL: URL, folderName: String, accountName: String)],
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
                    // When the destination names a file, attachments belong in
                    // the folder containing it.
                    let attachmentRoot = outputURL.pathExtension.lowercased() == format.fileExtension
                        ? outputURL.deletingLastPathComponent()
                        : outputURL
                    let attachments = try await exportNoteAttachments(
                        note.attachments, toDirectory: attachmentRoot,
                        outputRoot: attachmentRoot,
                        noteBaseName: note.sanitizedFileName,
                        noteTitle: note.title,
                        creationDate: note.creationDate,
                        modificationDate: note.modificationDate,
                        sharedAttachmentsFolder: configurations.sharedAttachmentsFolder,
                        repository: repository,
                        tracker: tracker
                    )
                    attachmentPaths = attachments.paths
                    report(attachments.events, verbose: verbose)
                }
                let content = try await generateContent(
                    for: note, format: format,
                    attachmentPaths: attachmentPaths, exportDirectory: outputURL,
                    folderName: noteWithPath.folderName, accountName: noteWithPath.accountName,
                    concatenating: true
                )
                contentParts.append(content)
                // Without this the run reports "exported: 0" while writing a
                // perfectly good file, so anything scripting the CLI sees a
                // successful export as having done nothing.
                _ = await tracker.noteCompleted()
                if verbose { CLIOutput.writeStderr("✓ Processed: \(note.title)") }
            } catch {
                await tracker.noteFailed()
                if verbose { CLIOutput.writeStderr("✗ Failed: \(note.title) — \(error.localizedDescription)") }
            }
        }

        // Shared with the app: this switch used to have no ENEX case, so notes
        // were joined with a Markdown rule inside an XML document, and neither
        // the JSON array nor the CSV header was applied.
        let concatenated = ConcatenatedExport.assemble(contentParts, format: format)
        // The destination may be the file the user named or a directory to put
        // the default name in, matching how the app resolves it.
        let fileURL = concatenatedExportURL(destination: outputURL, format: format)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try concatenated.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Single Note Export

    /// Send attachment events to stderr. Warnings always: a failed attachment
    /// used to be swallowed entirely by the CLI, with nothing printed even
    /// under --verbose.
    private func report(_ events: [AttachmentExportEvent], verbose: Bool) {
        for event in events where verbose || event.severity == .warning {
            CLIOutput.writeStderr(event.message)
        }
    }

    private func exportNoteSafelyWrapped(
        _ note: NotesNote,
        toDirectory directory: URL,
        format: ExportFormat,
        includeAttachments: Bool,
        tracker: ExportProgressTracker,
        syncTracker: SyncManifestTracker?,
        overrideRelativePath: String?,
        outputRootURL: URL?,
        folderName: String,
        accountName: String,
        verbose: Bool
    ) async {
        do {
            try await exportNoteSafely(
                note, toDirectory: directory, format: format,
                includeAttachments: includeAttachments,
                tracker: tracker, syncTracker: syncTracker,
                overrideRelativePath: overrideRelativePath,
                outputRootURL: outputRootURL,
                folderName: folderName,
                accountName: accountName,
                verbose: verbose
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
        outputRootURL: URL?,
        folderName: String,
        accountName: String,
        verbose: Bool
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
            let attachments = try await exportNoteAttachments(
                note.attachments, toDirectory: directory,
                outputRoot: outputRootURL ?? directory,
                noteBaseName: uniqueBaseName,
                noteTitle: note.title,
                creationDate: note.creationDate,
                modificationDate: note.modificationDate,
                sharedAttachmentsFolder: configurations.sharedAttachmentsFolder,
                repository: repository,
                tracker: tracker
            )
            attachmentPaths = attachments.paths
            report(attachments.events, verbose: verbose)
        }

        // Vector handwriting: nil means the note has none, and the ordinary
        // PDF pipeline takes over.
        var vectorPages: Int?
        if format == .pdfVector {
            vectorPages = try writePaperVectorPDF(for: note, to: fileURL, configuration: configurations.pdfVector)
        }

        // The vector case has to come first: Vector PDF is a binary format, so
        // otherwise a note it had already written would fall through to the
        // DOCX/ODT/EPUB branch and be overwritten.
        if let vectorPages {
            if verbose {
                CLIOutput.writeStderr("Rendered \(vectorPages) vector page\(vectorPages == 1 ? "" : "s") for '\(note.title)'")
            }
        } else if format == .pdf || format == .pdfVector {
            try await renderPDF(for: note, to: fileURL, attachmentPaths: attachmentPaths, exportDirectory: directory)
        } else if format.isBinaryFormat {
            let data = try await generateBinaryContent(for: note, format: format, attachmentPaths: attachmentPaths, exportDirectory: directory)
            try data.write(to: fileURL)
        } else {
            let content = try await generateContent(
                for: note, format: format,
                attachmentPaths: attachmentPaths, exportDirectory: directory,
                folderName: folderName, accountName: accountName
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            if format == .enex,
               let warning = ENEXLimits.oversizeWarning(title: note.title, byteCount: content.utf8.count) {
                // Not gated on --verbose: the file was written but may be
                // refused, which the user needs to know either way.
                CLIOutput.writeStderr("Warning: \(warning)")
            }
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
        // DOCX/ODT image embedding pulls bytes out of base64 data URIs
        // in the HTML body, so we must force inline-embed regardless of
        // the user's HTML config.
        let needInlineImages = format == .docx || format == .odt
        let html = try await generateHTML(
            for: note,
            attachmentPaths: attachmentPaths,
            exportDirectory: exportDirectory,
            embedImagesInlineOverride: needInlineImages ? true : nil
        )
        let enrichedNote = noteWithHTML(note, html: html)
        switch format {
        case .docx: return enrichedNote.toDOCX()
        case .odt:  return enrichedNote.toODT()
        case .epub: return enrichedNote.toEPUB()
        default:    throw CLIError.unsupportedFormat(format)
        }
    }

    /// Render one note in a text format, without writing anything to disk.
    ///
    /// Lets a caller read a note's actual content (formatting, links, tables)
    /// rather than only the plaintext the database stores alongside it.
    func renderNote(_ note: NotesNote, as format: ExportFormat) async throws -> String {
        guard !format.isBinaryFormat else {
            throw CLIError.unsupportedFormat(format)
        }
        return try await generateContent(for: note, format: format)
    }

    private func generateContent(
        for note: NotesNote,
        format: ExportFormat,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil,
        folderName: String? = nil,
        accountName: String? = nil,
        concatenating: Bool = false
    ) async throws -> String {
        if format == .pdf || format == .pdfVector {
            throw CLIError.unsupportedFormat(format)
        }
        let html = try await generateHTML(
            for: note,
            attachmentPaths: attachmentPaths,
            exportDirectory: exportDirectory,
            targetFormat: format
        )
        if format == .html { return html }
        let enrichedNote = noteWithHTML(note, html: html)

        // A .enex is a single document, so anything the markup links to has to
        // travel inside it rather than as a sibling file.
        let resources = format == .enex
            ? linkedAttachmentResources(linkedIn: html, paths: attachmentPaths, outputRoot: exportDirectory)
            : []

        return generateExportTextContent(
            for: enrichedNote,
            format: format,
            folderName: folderName,
            accountName: accountName,
            concatenating: concatenating,
            attachmentResources: resources,
            rtfFontFamily: configurations.rtf.fontFamily.rtfFontName,
            rtfFontSize: configurations.rtf.fontSizePoints,
            latexTemplate: configurations.latex.template
        )
    }

    private func generateHTML(
        for note: NotesNote,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil,
        forPDF: Bool = false,
        targetFormat: ExportFormat? = nil,
        embedImagesInlineOverride: Bool? = nil
    ) async throws -> String {
        // Shared with the app so the two cannot disagree about, say, whether
        // Markdown carries its images inline.
        var htmlConfig = targetFormat.map { htmlConfiguration(for: $0, base: configurations.html) }
            ?? configurations.html
        if let override = embedImagesInlineOverride {
            htmlConfig.embedImagesInline = override
            if override { htmlConfig.linkEmbeddedImages = false }
        }

        let htmlBody: String
        if let existingHTML = note.htmlBody {
            htmlBody = existingHTML
        } else {
            do {
                htmlBody = try await repository.generateHTML(forNoteId: note.id)
            } catch {
                // Fallback to plaintext
                htmlBody = plaintextFallbackHTMLDocument(plaintext: note.plaintext)
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

        // Strip the note's own <html><body> wrapper before embedding it in the
        // document below. The CLI never did this, so its HTML nested a second
        // document inside the first where the app's did not.
        processedHTML = extractHTMLBody(processedHTML)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let fontFamily = htmlConfig.fontFamily.cssFontStack
        let fontSize = "\(htmlConfig.fontSizePoints)pt"
        let marginValue = forPDF ? "0" : "\(htmlConfig.marginSize)\(htmlConfig.marginUnit.displayName)"

        // Shared with the app, from the configured page size and margins. This
        // used to assume a 36pt top and bottom margin regardless of settings.
        let pdfDimensions = configurations.pdf.pageSize.dimensions
        let imageConstraint = imageHeightConstraint(
            forPDF: forPDF,
            pageSize: CGSize(width: pdfDimensions.width, height: pdfDimensions.height),
            margins: configurations.pdf.htmlConfiguration.toNSEdgeInsets()
        )

        return noteHTMLDocument(
            title: note.title,
            created: dateFormatter.string(from: note.creationDate),
            modified: dateFormatter.string(from: note.modificationDate),
            fontFamily: fontFamily,
            fontSize: fontSize,
            margin: marginValue,
            imageConstraint: imageConstraint,
            body: processedHTML
        )
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
            let folderPath = buildExportFolderPath(folderId: note.folderId, folderLookup: folderLookup, accountId: note.accountId, isDeleted: note.isDeleted)

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

    func fetchNotes(includeDeleted: Bool = false) async throws -> [NotesNote] {
        try await repository.fetchNotes(includeDeleted: includeDeleted)
    }
}
