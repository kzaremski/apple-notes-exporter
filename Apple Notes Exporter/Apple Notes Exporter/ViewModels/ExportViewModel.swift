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

    init(repository: NotesRepository = DatabaseNotesRepository(), databasePath: String = "\(NSHomeDirectory())/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite") {
        self.repository = repository
        self.databasePath = databasePath
        self.configurations = ExportConfigurations.load()
    }

    // MARK: - Configuration Management

    func saveConfigurations() {
        configurations.save()
    }

    // MARK: - Export Operations

    /// Export notes to the specified output directory
    func exportNotes(
        _ notes: [NotesNote],
        toDirectory outputURL: URL,
        format: ExportFormat,
        includeAttachments: Bool = true
    ) async {
        // Reset state and clear log for new export
        shouldCancel = false
        exportLog = []
        failedNotesCount = 0
        failedAttachmentsCount = 0
        let startTime = Date()

        do {
            // Incremental sync: load existing manifest and filter to new/changed notes
            let isSync = configurations.incrementalSync
            let existingManifest = isSync ? SyncManifest.load(from: outputURL) : nil
            let syncTracker: SyncManifestTracker?

            let notesToExport: [NotesNote]
            if isSync, let manifest = existingManifest {
                notesToExport = manifest.notesNeedingExport(from: notes)
                // Start from existing manifest so we preserve entries for unchanged notes
                syncTracker = SyncManifestTracker(manifest: manifest)
                if notesToExport.isEmpty {
                    log("✓ All notes are up to date, nothing to export")
                    exportState = .completed(ExportStatistics(
                        successfulNotes: 0,
                        failedNotes: 0,
                        failedAttachments: 0,
                        completionDate: Date()
                    ))
                    // Still update lastSync timestamp
                    var updatedManifest = manifest
                    updatedManifest.lastSync = Date()
                    try updatedManifest.save(to: outputURL)
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

            // Create all directory structure upfront
            for (accountName, folders) in hierarchy {
                let accountURL = outputURL.appendingPathComponent(sanitizeExportFilename(accountName))
                try FileManager.default.createDirectory(at: accountURL, withIntermediateDirectories: true)

                for (folderPath, _) in folders {
                    let folderURL = accountURL.appendingPathComponent(folderPath)
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                }
            }

            // Flatten notes with their folder paths for concurrent export
            var notesWithPaths: [(note: NotesNote, folderURL: URL, folderName: String, accountName: String)] = []
            for (accountName, folders) in hierarchy {
                let accountURL = outputURL.appendingPathComponent(sanitizeExportFilename(accountName))
                for (folderPath, folderNotes) in folders {
                    let folderURL = accountURL.appendingPathComponent(folderPath)
                    for note in folderNotes {
                        notesWithPaths.append((note: note, folderURL: folderURL, folderName: folderPath, accountName: accountName))
                    }
                }
            }

            // Check if we should concatenate all notes into a single file
            // Only MD and TXT support concatenation
            let canConcatenate = format == .markdown || format == .txt
            if configurations.concatenateOutput && canConcatenate {
                try await exportNotesConcatenated(
                    notesWithPaths,
                    format: format,
                    includeAttachments: includeAttachments,
                    totalNotes: notesToExport.count,
                    outputURL: outputURL,
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
                    syncManifest: existingManifest,
                    outputRootURL: isSync ? outputURL : nil
                )
            }

            // Check if export was cancelled before marking as completed
            guard !shouldCancel else {
                // State already set to .cancelled in exportNotesConcurrently
                return
            }

            // Set folder timestamps based on their notes
            try await setExportFolderTimestamps(hierarchy: hierarchy, outputURL: outputURL)

            // Save sync manifest if incremental sync is enabled
            if let syncTracker = syncTracker {
                let finalManifest = await syncTracker.getManifest()
                try finalManifest.save(to: outputURL)
                log("✓ Sync manifest saved")
            }

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
                    let tracker = ExportProgressTracker()
                    let baseFilename = note.sanitizedFileName
                    attachmentPaths = try await exportAttachmentsAndReturnPaths(
                        note.attachments,
                        toDirectory: outputURL,
                        noteBaseName: baseFilename,
                        noteTitle: note.title,
                        noteCreationDate: note.creationDate,
                        noteModificationDate: note.modificationDate,
                        tracker: tracker
                    )
                    let stats = await tracker.getStats()
                    failedAttachmentsCount += stats.failedAttachments
                }

                // Generate content for this note
                let content = try await generateContent(
                    for: note,
                    format: format,
                    attachmentPaths: attachmentPaths,
                    exportDirectory: outputURL,
                    folderName: noteWithPath.folderName,
                    accountName: noteWithPath.accountName
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

        // Join all content with format-appropriate separators
        let separator: String
        switch format {
        case .html:
            separator = "\n<hr style=\"page-break-after: always;\">\n"
        case .pdf:
            separator = "\n<hr style=\"page-break-after: always;\">\n"
        case .markdown:
            separator = "\n\n---\n\n"
        case .txt:
            separator = "\n\n" + String(repeating: "=", count: 72) + "\n\n"
        case .rtf:
            separator = "\n\\page\n"
        case .tex:
            separator = "\n\n\\newpage\n\n"
        case .json:
            separator = ",\n"  // Array elements separated by comma
        case .jsonl:
            separator = "\n"   // One object per line
        case .xml:
            separator = "\n"
        case .csv:
            separator = "\n"   // One row per line
        case .opml:
            separator = "\n"
        case .org:
            separator = "\n\n" + String(repeating: "-", count: 72) + "\n\n"
        case .rst:
            separator = "\n\n" + String(repeating: "=", count: 72) + "\n\n"
        case .adoc:
            separator = "\n\n'''\n\n"  // AsciiDoc thematic break
        case .enex:
            separator = "\n"
        case .docx, .odt, .epub:
            separator = ""  // Binary formats cannot be concatenated
        }

        var concatenated = contentParts.joined(separator: separator)

        // Format-specific wrapping for concatenated output
        if format == .json {
            // Wrap JSON objects in an array
            concatenated = "[\n" + concatenated + "\n]"
        } else if format == .csv {
            // Prepend CSV header row
            concatenated = NotesNote.csvHeader() + "\n" + concatenated
        }

        // Write the single concatenated file
        let filename = "Exported Notes.\(format.fileExtension)"
        let fileURL = outputURL.appendingPathComponent(filename)

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

        log("✓ Exported concatenated file: \(filename)")
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
        } else {
            // Normal mode: generate unique filename
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

            attachmentPaths = try await exportAttachmentsAndReturnPaths(
                note.attachments,
                toDirectory: directory,
                noteBaseName: uniqueBaseName,
                noteTitle: note.title,
                noteCreationDate: note.creationDate,
                noteModificationDate: note.modificationDate,
                tracker: tracker
            )
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

    /// Export attachments for a note and return a map of attachment IDs to relative paths
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

        let fileAttachments = filterFileAttachments(attachments)

        // Skip if no file attachments to export
        guard !fileAttachments.isEmpty else {
            return attachmentPaths
        }

        // Create attachments subfolder using the unique note base name
        let attachmentsURL = directory.appendingPathComponent("\(noteBaseName) (Attachments)")
        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        // Track used filenames to handle collisions
        var usedFilenames: [String: Int] = [:]

        // Export each attachment
        for attachment in fileAttachments {
            try Task.checkCancellation()

            // Expand gallery containers into child attachments
            if attachment.typeUTI == "com.apple.notes.gallery" {
                do {
                    let children = try await repository.fetchGalleryChildren(
                        galleryId: attachment.id, accountId: nil)
                    for child in children {
                        let ext = child.filename.flatMap { fn in
                            fn.components(separatedBy: ".").last.flatMap { e in e.count <= 5 && e != fn ? e : nil }
                        } ?? child.uti.flatMap { NotesAttachment(id: child.id, typeUTI: $0, filename: nil).fileExtension }
                          ?? detectFileExtension(from: child.data)
                          ?? "jpg"
                        let childBase = child.filename ?? "\(child.id).\(ext)"

                        let childFinal: String
                        if let count = usedFilenames[childBase] {
                            let (name, e) = splitExportFilename(childBase)
                            childFinal = "\(name) (\(count + 1)).\(e)"
                            usedFilenames[childBase] = count + 1
                        } else {
                            childFinal = childBase
                            usedFilenames[childBase] = 1
                        }

                        let fileURL = attachmentsURL.appendingPathComponent(childFinal)
                        try child.data.write(to: fileURL)
                        try? setExportFileTimestamps(fileURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)

                        let relativePath = "\(noteBaseName) (Attachments)/\(childFinal)"
                        attachmentPaths[child.id] = relativePath
                        if attachmentPaths[attachment.id] == nil {
                            attachmentPaths[attachment.id] = relativePath
                        }
                    }
                } catch {
                    log("Gallery expansion failed for \(attachment.id): \(error.localizedDescription)")
                    await tracker.attachmentFailed()
                }
                continue
            }

            do {
                let data = try await repository.fetchAttachment(id: attachment.id)

                let baseFilename: String
                if let filename = attachment.filename {
                    baseFilename = filename
                } else if let fetchedFilename = await repository.fetchAttachmentFilename(id: attachment.id) {
                    baseFilename = fetchedFilename
                } else {
                    let ext = attachment.fileExtension
                        ?? detectFileExtension(from: data)
                        ?? "bin"
                    baseFilename = "\(attachment.id).\(ext)"
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

                // Write attachment to disk
                try data.write(to: fileURL)

                // Set attachment timestamps to match note's dates
                try setExportFileTimestamps(fileURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)

                log("✓ Exported attachment: \(finalFilename) for note '\(noteTitle)'")

                // Store relative path for this attachment
                let relativePath = "\(noteBaseName) (Attachments)/\(finalFilename)"
                attachmentPaths[attachment.id] = relativePath

            } catch {
                await tracker.attachmentFailed()

                // Build detailed error message for user logs
                var errorDetails = [
                    "Attachment ID: \(attachment.id)",
                    "Type: \(attachment.typeUTI)",
                    "Note: '\(noteTitle)'"
                ]

                if let filename = attachment.filename {
                    errorDetails.append("Filename: \(filename)")
                }

                // Include detailed error information
                errorDetails.append("Error: \(error.localizedDescription)")

                if let nsError = error as NSError? {
                    errorDetails.append("Domain: \(nsError.domain)")
                    errorDetails.append("Code: \(nsError.code)")

                    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                        errorDetails.append("Underlying: \(underlyingError.localizedDescription)")
                    }
                }

                let detailedMessage = "✗ Failed to export attachment - " + errorDetails.joined(separator: ", ")
                log(detailedMessage)
                Logger.noteExport.warning("Failed to export attachment: \(errorDetails.joined(separator: ", "))")
                // Continue with other attachments even if one fails
            }
        }

        // Set attachments folder timestamps to match note's dates
        if !fileAttachments.isEmpty {
            try setExportFileTimestamps(attachmentsURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)
        }

        return attachmentPaths
    }

    /// Export attachments for a note (thread-safe version for concurrent export)
    private func exportAttachmentsSafely(
        _ attachments: [NotesAttachment],
        toDirectory directory: URL,
        noteBaseName: String,
        noteTitle: String,
        noteCreationDate: Date,
        noteModificationDate: Date,
        tracker: ExportProgressTracker
    ) async throws {
        let fileAttachments = filterFileAttachments(attachments)

        // Skip if no file attachments to export
        guard !fileAttachments.isEmpty else {
            return
        }

        // Create attachments subfolder using the unique note base name
        let attachmentsURL = directory.appendingPathComponent("\(noteBaseName) (Attachments)")
        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        // Track used filenames to handle collisions
        var usedFilenames: [String: Int] = [:]

        // Export each attachment
        for attachment in fileAttachments {
            try Task.checkCancellation()

            // Expand gallery containers into child attachments
            if attachment.typeUTI == "com.apple.notes.gallery" {
                do {
                    let children = try await repository.fetchGalleryChildren(
                        galleryId: attachment.id, accountId: nil)
                    for child in children {
                        let ext = child.filename.flatMap { fn in
                            fn.components(separatedBy: ".").last.flatMap { e in e.count <= 5 && e != fn ? e : nil }
                        } ?? child.uti.flatMap { NotesAttachment(id: child.id, typeUTI: $0, filename: nil).fileExtension }
                          ?? detectFileExtension(from: child.data)
                          ?? "jpg"
                        let childBase = child.filename ?? "\(child.id).\(ext)"

                        let childFinal: String
                        if let count = usedFilenames[childBase] {
                            let (name, e) = splitExportFilename(childBase)
                            childFinal = "\(name) (\(count + 1)).\(e)"
                            usedFilenames[childBase] = count + 1
                        } else {
                            childFinal = childBase
                            usedFilenames[childBase] = 1
                        }

                        let fileURL = attachmentsURL.appendingPathComponent(childFinal)
                        try child.data.write(to: fileURL)
                        try? setExportFileTimestamps(fileURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)

                    }
                } catch {
                    log("Gallery expansion failed for \(attachment.id): \(error.localizedDescription)")
                    await tracker.attachmentFailed()
                }
                continue
            }

            do {
                let data = try await repository.fetchAttachment(id: attachment.id)

                let baseFilename: String
                if let filename = attachment.filename {
                    baseFilename = filename
                } else if let fetchedFilename = await repository.fetchAttachmentFilename(id: attachment.id) {
                    baseFilename = fetchedFilename
                } else {
                    let ext = attachment.fileExtension
                        ?? detectFileExtension(from: data)
                        ?? "bin"
                    baseFilename = "\(attachment.id).\(ext)"
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

                // Write attachment to disk
                try data.write(to: fileURL)

                // Set attachment timestamps to match note's dates
                try setExportFileTimestamps(fileURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)

                log("✓ Exported attachment: \(finalFilename) for note '\(noteTitle)'")

            } catch {
                await tracker.attachmentFailed()

                // Build detailed error message for user logs
                var errorDetails = [
                    "Attachment ID: \(attachment.id)",
                    "Type: \(attachment.typeUTI)",
                    "Note: '\(noteTitle)'"
                ]

                if let filename = attachment.filename {
                    errorDetails.append("Filename: \(filename)")
                }

                // Include detailed error information
                errorDetails.append("Error: \(error.localizedDescription)")

                if let nsError = error as NSError? {
                    errorDetails.append("Domain: \(nsError.domain)")
                    errorDetails.append("Code: \(nsError.code)")

                    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                        errorDetails.append("Underlying: \(underlyingError.localizedDescription)")
                    }
                }

                let detailedMessage = "✗ Failed to export attachment - " + errorDetails.joined(separator: ", ")
                log(detailedMessage)
                Logger.noteExport.warning("Failed to export attachment: \(errorDetails.joined(separator: ", "))")
                // Continue with other attachments even if one fails
            }
        }

        // Set attachments folder timestamps to match note's dates
        if !fileAttachments.isEmpty {
            try setExportFileTimestamps(attachmentsURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)
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

    /// Add a log entry (thread-safe)
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logLock.lock()
        defer { logLock.unlock() }
        exportLog.append("[\(timestamp)] \(message)")
    }

    // MARK: - Content Generation

    /// Generate content for a note in the specified format
    private func generateContent(for note: NotesNote, format: ExportFormat, attachmentPaths: [String: String] = [:], exportDirectory: URL? = nil, folderName: String? = nil, accountName: String? = nil) async throws -> String {
        switch format {
        case .html:
            return try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
        case .txt:
            // Generate HTML first, then convert to plain text (includes tables, links, hashtags)
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = NotesNote(
                id: note.id,
                title: note.title,
                plaintext: note.plaintext,
                htmlBody: html,
                creationDate: note.creationDate,
                modificationDate: note.modificationDate,
                folderId: note.folderId,
                accountId: note.accountId,
                attachments: note.attachments
            )
            return noteWithHTML.toPlainText()
        case .markdown:
            // For markdown and other formats, generate HTML first then convert
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = NotesNote(
                id: note.id,
                title: note.title,
                plaintext: note.plaintext,
                htmlBody: html,
                creationDate: note.creationDate,
                modificationDate: note.modificationDate,
                folderId: note.folderId,
                accountId: note.accountId,
                attachments: note.attachments
            )
            return noteWithHTML.toMarkdown()
        case .rtf:
            // Generate HTML first, then convert to RTF
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = NotesNote(
                id: note.id,
                title: note.title,
                plaintext: note.plaintext,
                htmlBody: html,
                creationDate: note.creationDate,
                modificationDate: note.modificationDate,
                folderId: note.folderId,
                accountId: note.accountId,
                attachments: note.attachments
            )
            return noteWithHTML.toRTF(
                fontFamily: configurations.rtf.fontFamily.rtfFontName,
                fontSize: configurations.rtf.fontSizePoints
            )
        case .tex:
            // Generate HTML first, then convert to LaTeX
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = NotesNote(
                id: note.id,
                title: note.title,
                plaintext: note.plaintext,
                htmlBody: html,
                creationDate: note.creationDate,
                modificationDate: note.modificationDate,
                folderId: note.folderId,
                accountId: note.accountId,
                attachments: note.attachments
            )
            return noteWithHTML.toLatex(template: configurations.latex.template)
        case .pdf:
            return try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
        case .json:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = noteWithBody(note, html: html)
            return noteWithHTML.toJSON(folderName: folderName, accountName: accountName)
        case .jsonl:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = noteWithBody(note, html: html)
            return noteWithHTML.toJSONL(folderName: folderName, accountName: accountName)
        case .xml:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = noteWithBody(note, html: html)
            return noteWithHTML.toXML(folderName: folderName, accountName: accountName)
        case .csv:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = noteWithBody(note, html: html)
            return noteWithHTML.toCSV(folderName: folderName, accountName: accountName)
        case .opml:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = noteWithBody(note, html: html)
            return noteWithHTML.toOPML()
        case .org:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = noteWithBody(note, html: html)
            return noteWithHTML.toOrg()
        case .rst:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = noteWithBody(note, html: html)
            return noteWithHTML.toRST()
        case .adoc:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = noteWithBody(note, html: html)
            return noteWithHTML.toAsciiDoc()
        case .enex:
            let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
            let noteWithHTML = noteWithBody(note, html: html)
            return noteWithHTML.toENEX()
        case .docx, .odt, .epub:
            // Binary formats should use generateBinaryContent() instead
            fatalError("Binary format \(format.rawValue) should not use generateContent(). Use generateBinaryContent() instead.")
        }
    }

    /// Generate binary content for ZIP-based formats (DOCX, ODT, EPUB)
    private func generateBinaryContent(for note: NotesNote, format: ExportFormat, attachmentPaths: [String: String] = [:], exportDirectory: URL? = nil) async throws -> Data {
        let html = try await generateHTML(for: note, attachmentPaths: attachmentPaths, exportDirectory: exportDirectory)
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
            attachments: note.attachments
        )
    }

    // MARK: - Content Generation

    private func generateHTML(
        for note: NotesNote,
        config: HTMLConfiguration? = nil,
        forPDF: Bool = false,
        attachmentPaths: [String: String] = [:],
        exportDirectory: URL? = nil,
        pdfPageSize: CGSize? = nil,
        pdfMargins: NSEdgeInsets? = nil
    ) async throws -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        // Use provided config or default from configurations
        let htmlConfig = config ?? configurations.html

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
                // Create a properly structured HTML document for PDF rendering
                htmlBody = """
                <html>
                <head>
                    <meta charset="UTF-8">
                    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                    <style>
                        body { font-family: -apple-system, system-ui; font-size: 12pt; line-height: 1.6; }
                        pre { white-space: pre-wrap; word-wrap: break-word; }
                    </style>
                </head>
                <body>
                    <pre>\(note.plaintext.htmlEscaped)</pre>
                </body>
                </html>
                """
            }
        }

        // Strip the NoteHTMLGenerator's outer <html><body>...</body></html> wrapper
        // since we wrap the content in our own full HTML document below.
        var processedHTML = htmlBody
        if let bodyStart = processedHTML.range(of: "<body>"),
           let bodyEnd = processedHTML.range(of: "</body>") {
            processedHTML = String(processedHTML[bodyStart.upperBound..<bodyEnd.lowerBound])
        }

        // Only process attachments if we have a database connection and attachments to process
        if !note.attachments.isEmpty {
            // Open a C parser handle and extract the sqlite3 pointer for HTMLAttachmentProcessor
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

        // Build CSS for font and margin
        let fontFamily = htmlConfig.fontFamily.cssFontStack
        let fontSize = "\(htmlConfig.fontSizePoints)pt"

        // For PDF, margins are handled by PDFConfiguration (set body margin to 0)
        // For HTML export, use the configured margin value
        let marginValue = forPDF ? "0" : "\(htmlConfig.marginSize)\(htmlConfig.marginUnit.displayName)"

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
                /* Remove all spacing around headings and paragraphs */
                h1, h2, h3, h4, h5, h6, p {
                    margin: 0;
                    padding: 0;
                    line-height: 1.0;
                }
                /* Remove spacing around lists but keep indentation */
                ul, ol {
                    margin: 0;
                    margin-left: 1.5em;
                    padding: 0;
                    padding-left: 0.5em;
                }
                li {
                    margin: 0;
                    padding: 0;
                    line-height: 1.0;
                }
                img {
                    max-width: 100%;
                    \(generateImageHeightConstraint(forPDF: forPDF, pageSize: pdfPageSize, margins: pdfMargins))
                }
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

    // MARK: - Helper Methods

    /// Generate CSS constraint for image height in PDFs
    private func generateImageHeightConstraint(forPDF: Bool, pageSize: CGSize?, margins: NSEdgeInsets?) -> String {
        guard forPDF, let pageSize = pageSize, let margins = margins else {
            return "" // No constraint for non-PDF exports
        }

        // Calculate maximum image height: page height - top margin - bottom margin
        // Use points as CSS unit (1 point = 1/72 inch, standard for PDF)
        let maxHeight = pageSize.height - margins.top - margins.bottom

        // Add some padding to ensure images don't touch margins (subtract 20pt)
        let safeMaxHeight = max(100, maxHeight - 20)

        return "max-height: \(safeMaxHeight)pt; height: auto;"
    }

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
            let folderPath = buildExportFolderPath(folderId: note.folderId, folderLookup: folderLookup)
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