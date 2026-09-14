//
//  ExportViewModel.swift
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
import SwiftUI
import OSLog
import HtmlToPdf

// MARK: - Export Errors

enum ExportError: Error, LocalizedError {
    case pdfGenerationTimeout

    var errorDescription: String? {
        switch self {
        case .pdfGenerationTimeout:
            return "PDF generation timed out after 60 seconds. This note may contain many large images or corrupted attachments."
        }
    }
}

// MARK: - Export Progress

struct ExportProgress: Equatable {
    var current: Int = 0
    var total: Int = 0
    var message: String = ""
    var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }
}

// MARK: - Export Statistics

struct ExportStatistics: Equatable {
    var successfulNotes: Int = 0
    var failedNotes: Int = 0
    var failedAttachments: Int = 0
    var completionDate: Date = Date()
}

// MARK: - Export State

enum ExportState: Equatable {
    case idle
    case exporting(ExportProgress)
    case completed(ExportStatistics)
    case cancelled
    case error(String)

    var isExporting: Bool {
        if case .exporting = self { return true }
        return false
    }
}

// MARK: - Export ViewModel

@MainActor
class ExportViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var exportState: ExportState = .idle
    @Published var shouldCancel: Bool = false
    @Published var exportLog: [String] = []
    @Published var configurations: ExportConfigurations

    // MARK: - Statistics Tracking

    private var failedNotesCount: Int = 0
    private var failedAttachmentsCount: Int = 0

    /// Pre-allocated note-id -> relative file path map, set at the start of each export.
    /// Used by generateHTML to rewrite applenotes:note/UUID links to real paths.
    private var internalLinkMap: [String: String] = [:]

    // MARK: - Concurrency Settings

    /// Calculate optimal number of concurrent exports based on system resources
    /// Formula: min(core_count, total_ram_gb_rounded_up / 2)
    /// This balances CPU availability with memory constraints
    private var maxConcurrentExports: Int {
        let coreCount = ProcessInfo.processInfo.processorCount

        // Get total physical memory in bytes
        let totalMemory = ProcessInfo.processInfo.physicalMemory

        // Convert to gigabytes and round up to nearest gigabyte
        let totalMemoryGB = Int(ceil(Double(totalMemory) / 1_073_741_824.0))

        // Calculate memory-based limit (half of available RAM in GB)
        let memoryLimit = max(1, totalMemoryGB / 2)

        // Take the minimum to respect both CPU and memory constraints
        let optimal = min(coreCount, memoryLimit)

        // Ensure at least 1 concurrent task, cap at 16 for safety
        return max(1, min(optimal, 16))
    }

    private let logLock = NSLock()  // Thread-safe logging

    // MARK: - Dependencies

    private let repository: NotesRepository
    private let databasePath: String

    // MARK: - Initialization

    init(repository: NotesRepository = DatabaseNotesRepository(), databasePath: String = defaultNotesDatabasePath()) {
        self.repository = repository
        self.databasePath = resolvedFilePath(databasePath)
        self.configurations = ExportConfigurations.load()
    }

    // MARK: - Configuration Management

    func saveConfigurations() {
        configurations.save()
    }

    // MARK: - Export Operations

    /// Export notes to the specified output directory
    /// Root name used for both the staging folder and the archive.
    static let zipRootName = exportArchiveRootName

    /// What the finished export actually produced: the archive for a zip
    /// export, otherwise the output folder. The archive name can differ from
    /// the destination the user picked, so the UI cannot infer it.
    @Published var lastExportArtifactURL: URL?


    func exportNotes(
        _ notes: [NotesNote],
        toDirectory destinationURL: URL,
        format: ExportFormat,
        includeAttachments: Bool = true
    ) async {
        // Reset state and clear log for new export
        shouldCancel = false
        exportLog = []
        failedNotesCount = 0
        failedAttachmentsCount = 0
        lastExportArtifactURL = nil
        let startTime = Date()

        // A zip export writes the tree into a staging folder next to where the
        // archive will land, so the archive has a single tidy root and the
        // user's chosen folder is never littered with loose note files. The
        // staging folder is removed once the archive exists.
        let archiveFormat = configurations.incrementalSync ? nil : configurations.archiveFormat
        let makeZip = archiveFormat != nil

        // In zip mode the destination may be the archive the user named in the
        // save panel, or a plain folder if they picked one before switching
        // modes. Either way the archive's own name becomes the root folder
        // inside it, so "Trip Notes.zip" expands to a "Trip Notes" folder.
        // With Single File the destination may be the file the user named in the
        // save panel. Attachments and folder paths still need a directory to work
        // in, and that has to be the file's containing folder: using the file path
        // itself buries the whole tree inside a folder called "Exported Notes.md"
        // and the final write then collides with that folder.
        let singleFileURL: URL? =
            (!makeZip && configurations.concatenateOutput && format.supportsConcatenation)
            ? concatenatedExportURL(destination: destinationURL, format: format)
            : nil

        let archiveURL: URL
        let outputURL: URL
        if makeZip {
            let locations = archiveExportLocations(destination: destinationURL, format: archiveFormat ?? .zip)
            archiveURL = locations.archive
            outputURL = locations.staging
        } else if let singleFileURL {
            archiveURL = singleFileURL
            outputURL = singleFileURL.deletingLastPathComponent()
        } else {
            archiveURL = destinationURL
            outputURL = destinationURL
        }

        do {
            if makeZip {
                try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            }
            // Incremental sync: load existing manifest and filter to new/changed notes
            let isSync = configurations.incrementalSync
            // Pruning must be judged against the whole library, not this run's
            // selection, or exporting a subset would delete the files of every
            // note the user did not happen to select this time.
            // nil means "the library is unknown", which suppresses pruning. A
            // failed read must keep that meaning: collapsing it to an empty set
            // would say "the library contains nothing", and every previously
            // exported note would be pruned from disk as deleted.
            var libraryNoteIds: Set<String>?
            if isSync {
                do {
                    libraryNoteIds = Set(try await repository.fetchNotes(includeDeleted: false).map(\.id))
                } catch {
                    libraryNoteIds = nil
                    log("⚠︎ Could not read the full library; deleted notes will not be pruned this run.")
                    Logger.noteExport.warning(
                        "Library read failed during incremental sync; skipping prune: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            let existingManifest = isSync ? SyncManifest.load(from: outputURL) : nil
            let syncTracker: SyncManifestTracker?

            let notesToExport: [NotesNote]
            var activeManifest = existingManifest
            if isSync, var manifest = existingManifest {
                // Repair entries that point somewhere the note no longer
                // belongs. Older versions parked unresolvable notes in
                // "Unknown Folder" and then overwrote them there forever; the
                // same applies to a note moved between folders in Apple Notes.
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
                if !relocated.isEmpty {
                    log("Relocating \(relocated.count) note(s) whose export folder changed")
                }
                activeManifest = manifest

                notesToExport = manifest.notesNeedingExport(from: notes)
                // Start from existing manifest so we preserve entries for unchanged notes
                syncTracker = SyncManifestTracker(manifest: manifest)
                if notesToExport.isEmpty {
                    let removed: [SyncManifest.PrunedNote] = await pruneIfLibraryKnown(
                        tracker: syncTracker!,
                        libraryNoteIds: libraryNoteIds,
                        selected: notes,
                        outputRoot: outputURL
                    )
                    await syncTracker!.finishRun(pruned: removed)
                    let updatedManifest = await syncTracker!.getManifest()
                    try updatedManifest.save(to: outputURL)
                    log("✓ All notes are up to date, nothing to export")
                    exportState = .completed(ExportStatistics(
                        successfulNotes: 0,
                        failedNotes: 0,
                        failedAttachments: 0,
                        completionDate: Date()
                    ))
                    return
                }
                log("Incremental sync: \(notesToExport.count) new/changed notes of \(notes.count) total")
            } else {
                notesToExport = notes
                syncTracker = isSync ? SyncManifestTracker(manifest: .empty()) : nil
            }

            // Start exporting
            exportState = .exporting(ExportProgress(
                current: 0,
                total: notesToExport.count,
                message: isSync ? "Starting incremental sync..." : "Starting export..."
            ))

            // Group notes by account and folder for organized output
            let hierarchy = try await organizeNotesByHierarchy(notesToExport)

            // Create all directory structure upfront. Single File writes one
            // file and no tree, so creating it would leave an empty copy of the
            // whole folder hierarchy sitting beside that file.
            if singleFileURL == nil {
                for (accountName, folders) in hierarchy {
                    let accountURL = outputURL.appendingPathComponent(sanitizeExportFilename(accountName))
                    try FileManager.default.createDirectory(at: accountURL, withIntermediateDirectories: true)

                    for (folderPath, _) in folders {
                        let folderURL = accountURL.appendingPathComponent(folderPath)
                        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                    }
                }
            }

            // Flatten notes with their folder paths for concurrent export
            let notesWithPaths = flattenExportHierarchy(hierarchy, outputRoot: outputURL)

            // Pre-allocate filenames so applenotes:note/UUID internal links can be
            // rewritten to actual relative file paths during rendering.
            let simplifiedPairs = notesWithPaths.map { (note: $0.note, folderURL: $0.folderURL) }
            self.internalLinkMap = buildInternalLinkPathMap(
                allNotes: notes,
                notesWithPaths: simplifiedPairs,
                outputRoot: outputURL,
                format: format,
                addDatePrefix: configurations.addDateToFilename,
                dateFormat: configurations.filenameDateFormat.rawValue,
                existingManifest: existingManifest
            )
            defer { self.internalLinkMap = [:] }

            // Check if we should concatenate all notes into a single file
            let canConcatenate = format.supportsConcatenation
            if configurations.concatenateOutput && canConcatenate {
                try await exportNotesConcatenated(
                    notesWithPaths,
                    format: format,
                    includeAttachments: includeAttachments,
                    totalNotes: notesToExport.count,
                    outputURL: outputURL,
                    fileURL: singleFileURL
                        ?? concatenatedExportURL(destination: outputURL, format: format),
                    startTime: startTime
                )
            } else {
                // Export notes concurrently (default behavior)
                try await exportNotesConcurrently(
                    notesWithPaths,
                    format: format,
                    includeAttachments: includeAttachments,
                    totalNotes: notesToExport.count,
                    startTime: startTime,
                    syncTracker: syncTracker,
                    syncManifest: activeManifest,
                    outputRootURL: outputURL
                )
            }

            // Check if export was cancelled before marking as completed
            guard !shouldCancel else {
                // State already set to .cancelled in exportNotesConcurrently
                return
            }

            // Set folder timestamps based on their notes. Single File writes no
            // folder tree, and stamping paths that were never created throws.
            if singleFileURL == nil {
                try await setExportFolderTimestamps(hierarchy: hierarchy, outputURL: outputURL)
            }

            // Prune deleted notes from manifest, remove their files, then save.
            if let syncTracker = syncTracker {
                let removed: [SyncManifest.PrunedNote] = await pruneIfLibraryKnown(
                    tracker: syncTracker,
                    libraryNoteIds: libraryNoteIds,
                    selected: notes,
                    outputRoot: outputURL
                )
                await syncTracker.finishRun(pruned: removed)
                let finalManifest = await syncTracker.getManifest()
                try finalManifest.save(to: outputURL)
                log("✓ Sync manifest saved")
            }

            // Not when concatenating: there is no exported tree to index, and
            // outputURL is then the folder the user saved the file into, so
            // this would write an index.html into every directory under it.
            if format == .html && !configurations.concatenateOutput && configurations.html.writeFolderIndexes {
                try writeHTMLFolderIndexes(underRoot: outputURL)
            }

            if makeZip {
                log("Creating \(archiveURL.lastPathComponent)...")
                try createArchive(archiveFormat ?? .zip, at: outputURL, to: archiveURL)
                try? FileManager.default.removeItem(at: outputURL)
                log("✓ Wrote \(archiveURL.lastPathComponent)")
            }

            lastExportArtifactURL = (makeZip || singleFileURL != nil) ? archiveURL : outputURL

            // Export completed successfully
            let successfulNotes = notesToExport.count - failedNotesCount
            exportState = .completed(ExportStatistics(
                successfulNotes: successfulNotes,
                failedNotes: failedNotesCount,
                failedAttachments: failedAttachmentsCount,
                completionDate: Date()
            ))
            Logger.noteExport.info("Export completed: \(successfulNotes) successful, \(self.failedNotesCount) failed notes, \(self.failedAttachmentsCount) failed attachments")

        } catch {
            if makeZip {
                try? FileManager.default.removeItem(at: outputURL)
            }
            exportState = .error(error.localizedDescription)
            Logger.noteExport.error("Export failed: \(error.localizedDescription)")
        }
    }

    /// Export notes concurrently using TaskGroup
    private func exportNotesConcurrently(
        _ notesWithPaths: [(note: NotesNote, folderURL: URL, folderName: String, accountName: String)],
        format: ExportFormat,
        includeAttachments: Bool,
        totalNotes: Int,
        startTime: Date,
        syncTracker: SyncManifestTracker? = nil,
        syncManifest: SyncManifest? = nil,
        outputRootURL: URL? = nil
    ) async throws {
        let tracker = ExportProgressTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = notesWithPaths.makeIterator()
            var activeTaskCount = 0

            // Launch initial batch of concurrent exports
            while activeTaskCount < maxConcurrentExports, let noteWithPath = iterator.next() {
                let overridePath = syncManifest?.existingPath(for: noteWithPath.note.id)
                group.addTask {
                    await self.exportNoteConcurrently(
                        noteWithPath.note,
                        toDirectory: noteWithPath.folderURL,
                        format: format,
                        includeAttachments: includeAttachments,
                        tracker: tracker,
                        syncTracker: syncTracker,
                        overrideRelativePath: overridePath,
                        outputRootURL: outputRootURL,
                        folderName: noteWithPath.folderName,
                        accountName: noteWithPath.accountName
                    )
                }
                activeTaskCount += 1
            }

            // Process completed tasks and launch new ones
            for try await _ in group {
                // Check for cancellation
                if shouldCancel {
                    group.cancelAll()
                    exportState = .cancelled
                    Logger.noteExport.info("Export cancelled by user")
                    return
                }

                // Update progress
                let stats = await tracker.getStats()
                let completed = stats.completed

                // Update stats on main actor
                failedNotesCount = stats.failedNotes
                failedAttachmentsCount = stats.failedAttachments

                // Calculate time remaining
                let elapsedTime = Date().timeIntervalSince(startTime)
                let timePerNote = elapsedTime / Double(completed)
                let remainingNotes = totalNotes - completed
                let estimatedRemaining = timePerNote * Double(remainingNotes)

                // Update progress message
                let message = completed >= 10
                    ? "Exporting notes \(completed) of \(totalNotes) (\(formatTimeRemaining(estimatedRemaining)) remaining)"
                    : "Exporting notes \(completed) of \(totalNotes)"

                exportState = .exporting(ExportProgress(
                    current: completed,
                    total: totalNotes,
                    message: message
                ))

                // Launch next task if available
                if let noteWithPath = iterator.next() {
                    let overridePath = syncManifest?.existingPath(for: noteWithPath.note.id)
                    group.addTask {
                        await self.exportNoteConcurrently(
                            noteWithPath.note,
                            toDirectory: noteWithPath.folderURL,
                            format: format,
                            includeAttachments: includeAttachments,
                            tracker: tracker,
                            syncTracker: syncTracker,
                            overrideRelativePath: overridePath,
                            outputRootURL: outputRootURL,
                            folderName: noteWithPath.folderName,
                            accountName: noteWithPath.accountName
                        )
                    }
                }
            }
        }
    }

    /// Export all notes concatenated into a single file
    private func exportNotesConcatenated(
        _ notesWithPaths: [(note: NotesNote, folderURL: URL, folderName: String, accountName: String)],
        format: ExportFormat,
        includeAttachments: Bool,
        totalNotes: Int,
        outputURL: URL,
        fileURL: URL,
        startTime: Date
    ) async throws {
        var contentParts: [String] = []

        for (index, noteWithPath) in notesWithPaths.enumerated() {
            guard !shouldCancel else {
                exportState = .cancelled
                Logger.noteExport.info("Export cancelled by user")
                return
            }

            let note = noteWithPath.note

            exportState = .exporting(ExportProgress(
                current: index,
                total: totalNotes,
                message: "Processing note \(index + 1) of \(totalNotes)..."
            ))

            do {
                // Export attachments if needed (into the output root directory)
                var attachmentPaths: [String: String] = [:]
                if includeAttachments && note.hasAttachments {
                    let attachments = try await exportNoteAttachments(
                        note.attachments,
                        toDirectory: outputURL,
                        outputRoot: outputURL,
                        noteBaseName: note.sanitizedFileName,
                        noteTitle: note.title,
                        creationDate: note.creationDate,
                        modificationDate: note.modificationDate,
                        sharedAttachmentsFolder: configurations.sharedAttachmentsFolder,
                        repository: repository
                    )
                    attachmentPaths = attachments.paths
                    failedAttachmentsCount += attachments.failures
                    for event in attachments.events { log(event.message) }
                }

                // Generate content for this note
                let content = try await generateContent(
                    for: note,
                    format: format,
                    attachmentPaths: attachmentPaths,
                    exportDirectory: outputURL,
                    folderName: noteWithPath.folderName,
                    accountName: noteWithPath.accountName,
                    concatenating: true
                )
                contentParts.append(content)
                log("✓ Processed note: \(note.title)")
            } catch {
                failedNotesCount += 1
                log("✗ Failed to process note '\(note.title)': \(error.localizedDescription)")
                Logger.noteExport.error("Failed to process note for concatenation: \(note.title) - \(error.localizedDescription)")
            }
        }

        guard !shouldCancel else {
            exportState = .cancelled
            return
        }

        // Join the notes and apply whatever wrapper the format needs, shared
        // with the CLI so the two cannot describe a format differently.
        let concatenated = ConcatenatedExport.assemble(contentParts, format: format)

        // Write the single concatenated file. The caller resolved the path,
        // since it also had to derive the working directory from it.
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        if format == .pdf {
            // For PDF, the concatenated content is HTML — render it
            let pdfConfig = configurations.pdf
            let pageSize = pdfConfig.pageSize.dimensions
            let margins = pdfConfig.htmlConfiguration.toPDFEdgeInsets()
            let pdfConfiguration = HtmlToPdf.PDFConfiguration(
                margins: margins,
                paperSize: CGSize(width: pageSize.width, height: pageSize.height)
            )

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await concatenated.print(to: fileURL, configuration: pdfConfiguration)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(totalNotes) * 60_000_000_000)
                    throw ExportError.pdfGenerationTimeout
                }
                try await group.next()
                group.cancelAll()
            }
        } else {
            try concatenated.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        log("✓ Exported concatenated file: \(fileURL.lastPathComponent)")
    }

    /// Export a single note concurrently (non-throwing wrapper for TaskGroup)
    private func exportNoteConcurrently(
        _ note: NotesNote,
        toDirectory directory: URL,
        format: ExportFormat,
        includeAttachments: Bool,
        tracker: ExportProgressTracker,
        syncTracker: SyncManifestTracker? = nil,
        overrideRelativePath: String? = nil,
        outputRootURL: URL? = nil,
        folderName: String? = nil,
        accountName: String? = nil
    ) async {
        do {
            try await exportNoteSafely(
                note,
                toDirectory: directory,
                format: format,
                includeAttachments: includeAttachments,
                tracker: tracker,
                syncTracker: syncTracker,
                overrideRelativePath: overrideRelativePath,
                outputRootURL: outputRootURL,
                folderName: folderName,
                accountName: accountName
            )
            _ = await tracker.noteCompleted()
        } catch {
            await tracker.noteFailed()

            // Build detailed error message for user logs
            var errorDetails = [
                "Note: '\(note.title)'",
                "ID: \(note.id)",
                "Format: \(format.rawValue)",
                "Error: \(error.localizedDescription)"
            ]

            if let nsError = error as NSError? {
                errorDetails.append("Domain: \(nsError.domain)")
                errorDetails.append("Code: \(nsError.code)")

                if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    errorDetails.append("Underlying: \(underlyingError.localizedDescription)")
                }
            }

            let detailedMessage = "✗ Failed to export note - " + errorDetails.joined(separator: ", ")
            log(detailedMessage)
            Logger.noteExport.error("Failed to export note: \(errorDetails.joined(separator: ", "))")
        }
    }

    /// Export a single note to disk (thread-safe version for concurrent export)
    private func exportNoteSafely(
        _ note: NotesNote,
        toDirectory directory: URL,
        format: ExportFormat,
        includeAttachments: Bool,
        tracker: ExportProgressTracker,
        syncTracker: SyncManifestTracker? = nil,
        overrideRelativePath: String? = nil,
        outputRootURL: URL? = nil,
        folderName: String? = nil,
        accountName: String? = nil
    ) async throws {
        // Check for cancellation before starting export
        try Task.checkCancellation()

        // Determine file URL — either overwrite at existing path (sync) or generate new
        let fileURL: URL
        let uniqueBaseName: String

        if let relativePath = overrideRelativePath, let rootURL = outputRootURL {
            // Sync mode: overwrite at previously exported path
            fileURL = rootURL.appendingPathComponent(relativePath)
            // Ensure parent directory exists (in case folder structure was deleted)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            uniqueBaseName = fileURL.deletingPathExtension().lastPathComponent
        } else if let preAllocated = internalLinkMap[note.id] {
            // Use the pre-allocated filename so applenotes:note/UUID links
            // rewritten in other notes resolve to this actual file.
            let filename = (preAllocated as NSString).lastPathComponent
            fileURL = directory.appendingPathComponent(filename)
            uniqueBaseName = filename.replacingOccurrences(of: ".\(format.fileExtension)", with: "")
        } else {
            // Fallback: generate unique filename by hitting the filesystem
            let baseFilename: String
            if configurations.addDateToFilename {
                let formatter = DateFormatter()
                formatter.dateFormat = configurations.filenameDateFormat.rawValue
                let datePrefix = formatter.string(from: note.creationDate)
                baseFilename = "\(datePrefix) \(note.sanitizedFileName)"
            } else {
                baseFilename = note.sanitizedFileName
            }
            let filename = generateUniqueExportFilename(
                baseName: baseFilename,
                extension: format.fileExtension,
                inDirectory: directory
            )
            fileURL = directory.appendingPathComponent(filename)
            uniqueBaseName = filename.replacingOccurrences(of: ".\(format.fileExtension)", with: "")
        }

        // Export attachments before note content (required for HTML attachment path resolution)
        var attachmentPaths: [String: String] = [:]
        if includeAttachments && note.hasAttachments {
            // Check for cancellation before processing attachments
            try Task.checkCancellation()

            let attachments = try await exportNoteAttachments(
                note.attachments,
                toDirectory: directory,
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
            // Drained here, back on the main actor, so these lines still
            // precede the note's own "✓ Exported" line as they always did.
            for event in attachments.events { log(event.message) }
        }

        // Handle PDF export separately (binary format, requires WebKit)
        if format == .pdf {
            // Check for cancellation before expensive PDF generation
            try Task.checkCancellation()

            // Use PDF configuration
            let pdfConfig = configurations.pdf

            // Apply page size and margin configuration
            let pageSize = pdfConfig.pageSize.dimensions
            let margins = pdfConfig.htmlConfiguration.toPDFEdgeInsets()

            // Generate HTML with PDF-specific constraints
            let pageSizeCG = CGSize(width: pageSize.width, height: pageSize.height)
            let marginsNS = pdfConfig.htmlConfiguration.toNSEdgeInsets()

            let html = try await generateHTML(
                for: note,
                config: pdfConfig.htmlConfiguration,
                forPDF: true,
                attachmentPaths: attachmentPaths,
                exportDirectory: directory,
                pdfPageSize: pageSizeCG,
                pdfMargins: marginsNS
            )
            let pdfConfiguration = HtmlToPdf.PDFConfiguration(
                margins: margins,
                paperSize: pageSizeCG
            )

            // Add timeout for PDF generation to prevent infinite hangs on corrupted images
            // Notes with many images can take 30+ seconds to render
            // HEIC conversion to JPEG helps, but timeout still needed for truly corrupted files
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await html.print(to: fileURL, configuration: pdfConfiguration)
                }

                group.addTask {
                    // 60 second timeout - allows image-heavy notes to render while catching infinite hangs
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    throw ExportError.pdfGenerationTimeout
                }

                // Wait for first task to complete (either PDF finishes or timeout)
                try await group.next()
                group.cancelAll()
            }

            log("✓ Exported PDF: \(note.title)")
        } else if format.isBinaryFormat {
            // Binary ZIP-based formats (DOCX, ODT, EPUB)
            try Task.checkCancellation()
            let data = try await generateBinaryContent(for: note, format: format, attachmentPaths: attachmentPaths, exportDirectory: directory)
            try data.write(to: fileURL)
            log("✓ Exported \(format.rawValue): \(note.title)")
        } else {
            // Generate content based on format
            let content = try await generateContent(for: note, format: format, attachmentPaths: attachmentPaths, exportDirectory: directory, folderName: folderName, accountName: accountName)

            // Write to file
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            log("✓ Exported note: \(note.title)")
            if format == .enex,
               let warning = ENEXLimits.oversizeWarning(title: note.title, byteCount: content.utf8.count) {
                log("⚠︎ \(warning)")
            }
        }

        // Set file timestamps to match note's creation and modification dates
        try setExportFileTimestamps(fileURL, creationDate: note.creationDate, modificationDate: note.modificationDate)

        // Record in sync manifest if tracking
        if let syncTracker = syncTracker, let rootURL = outputRootURL {
            // Compute relative path from output root
            let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            let attachmentRelPaths = attachmentPaths.values.map { path in
                // attachmentPaths values are relative to the note's directory, make them relative to root
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

    /// Cancel the current export operation
    func cancelExport() {
        shouldCancel = true
    }

    /// Reset export state
    func reset() {
        exportState = .idle
        shouldCancel = false
    }

    /// Prune manifest entries for notes that have left Apple Notes, and delete
    /// their exported files.
    ///
    /// Only ever called with the full library. `libraryNoteIds` is nil when the
    /// library could not be read, and pruning is then skipped entirely: judging
    /// "deleted" against this run's selection would delete the exported files of
    /// every note the user simply did not select.
    private func pruneIfLibraryKnown(
        tracker: SyncManifestTracker,
        libraryNoteIds: Set<String>?,
        selected: [NotesNote],
        outputRoot: URL
    ) async -> [SyncManifest.PrunedNote] {
        guard let presentIds = prunePresentNoteIds(
            libraryNoteIds: libraryNoteIds,
            selectedNoteIds: selected.map(\.id)
        ) else { return [] }

        let removed = await tracker.pruneDeleted(presentNoteIds: presentIds)
        for pruned in removed {
            deleteExportedNoteFiles(outputRoot: outputRoot, entry: pruned.entry)
            log("✓ Pruned deleted note: \(pruned.entry.exportedPath)")
        }
        return removed
    }

    /// Add a log entry (thread-safe)
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logLock.lock()
        defer { logLock.unlock() }
        exportLog.append("[\(timestamp)] \(message)")
    }

    // MARK: - Content Generation

    /// Generate content for a note in the specified format
    /// Render one note as text in the given format.
    ///
    /// This used to be a switch of its own, parallel to the CLI's. They drifted:
    /// the app's honoured `concatenating` for ENEX only, so a Single File XML or
    /// OPML export nested a whole document per note inside the wrapper, and the
    /// per-format HTML settings were spelled out again in each case.
    private func generateContent(
        for note: NotesNote,
        format: ExportFormat,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil,
        folderName: String? = nil,
        accountName: String? = nil,
        concatenating: Bool = false
    ) async throws -> String {
        if format.isBinaryFormat {
            fatalError("Binary format \(format.rawValue) should not use generateContent(). Use generateBinaryContent() instead.")
        }
        let html = try await generateHTML(
            for: note,
            attachmentPaths: attachmentPaths,
            exportDirectory: exportDirectory,
            targetFormat: format
        )
        // PDF is rendered from this HTML rather than converted from it.
        if format == .html || format == .pdf { return html }
        let enrichedNote = noteWithBody(note, html: html)

        // A .enex is a single document, so a link to a sibling file does not
        // survive the import. Anything the markup links to travels inside the
        // note as a resource, the way images already do.
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

    /// Generate binary content for ZIP-based formats (DOCX, ODT, EPUB)
    private func generateBinaryContent(for note: NotesNote, format: ExportFormat, attachmentPaths: [String: String] = [:], exportDirectory: URL? = nil) async throws -> Data {
        // Force inline base64 image embedding so the DOCX/ODT converters
        // can extract image bytes from the HTML and package them inside
        // the ZIP regardless of the user's HTML preferences.
        var binaryHTMLConfig = configurations.html
        binaryHTMLConfig.embedImagesInline = true
        binaryHTMLConfig.linkEmbeddedImages = false

        let html = try await generateHTML(
            for: note,
            config: binaryHTMLConfig,
            attachmentPaths: attachmentPaths,
            exportDirectory: exportDirectory
        )
        let noteWithHTML = noteWithBody(note, html: html)

        switch format {
        case .docx:
            return noteWithHTML.toDOCX()
        case .odt:
            return noteWithHTML.toODT()
        case .epub:
            return noteWithHTML.toEPUB()
        default:
            fatalError("Format \(format.rawValue) is not a binary format")
        }
    }

    /// Create a copy of a note with the given HTML body set
    private func noteWithBody(_ note: NotesNote, html: String) -> NotesNote {
        return NotesNote(
            id: note.id,
            title: note.title,
            plaintext: note.plaintext,
            htmlBody: html,
            creationDate: note.creationDate,
            modificationDate: note.modificationDate,
            folderId: note.folderId,
            accountId: note.accountId,
            attachments: note.attachments,
            identifier: note.identifier,
            isDeleted: note.isDeleted
        )
    }

    // MARK: - Content Generation

    private func generateHTML(
        for note: NotesNote,
        config: HTMLConfiguration? = nil,
        forPDF: Bool = false,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil,
        targetFormat: ExportFormat? = nil,
        pdfPageSize: CGSize? = nil,
        pdfMargins: NSEdgeInsets? = nil
    ) async throws -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        // Use provided config or default from configurations
        // Shared with the CLI so the two cannot disagree about, say, whether
        // Markdown carries its images inline.
        let htmlConfig = config
            ?? targetFormat.map { htmlConfiguration(for: $0, base: configurations.html) }
            ?? configurations.html

        // Generate HTML on-demand during export if not already present
        let htmlBody: String
        if let existingHTML = note.htmlBody {
            htmlBody = existingHTML
        } else {
            // Generate HTML from protobuf during export
            do {
                htmlBody = try await repository.generateHTML(forNoteId: note.id)
            } catch {
                // Fallback to plaintext if HTML generation fails (corrupted protobuf, etc.)
                Logger.noteExport.warning("Failed to generate HTML for note \(note.id), falling back to plaintext: \(error)")
                htmlBody = plaintextFallbackHTMLDocument(plaintext: note.plaintext)
            }
        }

        // Rewrite applenotes:note/UUID internal links to real relative paths.
        var linkRewrittenBody = htmlBody
        if let currentPath = internalLinkMap[note.id], !internalLinkMap.isEmpty {
            linkRewrittenBody = rewriteInternalLinks(
                html: htmlBody,
                currentNoteRelativePath: currentPath,
                noteIdToRelativePath: internalLinkMap
            )
        }

        // Strip the NoteHTMLGenerator's outer <html><body>...</body></html> wrapper
        // since we wrap the content in our own full HTML document below.
        var processedHTML = linkRewrittenBody

        // Only process attachments if we have a database connection and attachments to process
        if !note.attachments.isEmpty {
            // Open a C parser handle and extract the sqlite3 pointer for HTMLAttachmentProcessor
            if let parserHandle = ane_open(databasePath) {
                defer { ane_close(parserHandle) }
                if let rawHandle = ane_get_sqlite_handle(parserHandle) {
                    let database = OpaquePointer(rawHandle)
                    let processor = HTMLAttachmentProcessor(database: database)
                    processedHTML = processor.processHTML(
                        html: linkRewrittenBody,
                        attachments: note.attachments,
                        attachmentPaths: attachmentPaths,
                        exportDirectory: exportDirectory?.path,
                        embedImages: htmlConfig.embedImagesInline,
                        linkEmbeddedImages: htmlConfig.linkEmbeddedImages
                    )
                }
            }
        }

        // The note's own markup carries an <html><body> wrapper, which has to
        // come off before it is embedded in the document built below. This used
        // to run *before* attachment processing and was then overwritten by it,
        // so any note with an attachment kept a nested <html><body>.
        processedHTML = extractHTMLBody(processedHTML)

        // Build CSS for font and margin
        let fontFamily = htmlConfig.fontFamily.cssFontStack
        let fontSize = "\(htmlConfig.fontSizePoints)pt"

        // For PDF, margins are handled by PDFConfiguration (set body margin to 0)
        // For HTML export, use the configured margin value
        let marginValue = forPDF ? "0" : "\(htmlConfig.marginSize)\(htmlConfig.marginUnit.displayName)"

        return noteHTMLDocument(
            title: note.title,
            created: dateFormatter.string(from: note.creationDate),
            modified: dateFormatter.string(from: note.modificationDate),
            fontFamily: fontFamily,
            fontSize: fontSize,
            margin: marginValue,
            imageConstraint: imageHeightConstraint(
                forPDF: forPDF, pageSize: pdfPageSize, margins: pdfMargins),
            body: processedHTML
        )
    }

    // MARK: - Helper Methods

    /// Generate CSS constraint for image height in PDFs

    /// Organize notes by account and folder hierarchy
    private func organizeNotesByHierarchy(_ notes: [NotesNote]) async throws -> [String: [String: [NotesNote]]] {
        var hierarchy: [String: [String: [NotesNote]]] = [:]

        let accounts = try await repository.fetchAccounts()
        let folders = try await repository.fetchFolders()

        var accountLookup: [String: String] = [:]
        for account in accounts { accountLookup[account.id] = account.name }

        var folderLookup: [String: NotesFolder] = [:]
        for folder in folders { folderLookup[folder.id] = folder }

        for note in notes {
            let accountKey = sanitizeExportFilename(accountLookup[note.accountId] ?? "Unknown Account")
            let folderPath = buildExportFolderPath(folderId: note.folderId, folderLookup: folderLookup, accountId: note.accountId, isDeleted: note.isDeleted)
            hierarchy[accountKey, default: [:]][folderPath, default: []].append(note)
        }

        return hierarchy
    }

    /// Format time remaining for display
    private func formatTimeRemaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return "\(minutes)m"
        } else {
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m"
        }
    }

}
