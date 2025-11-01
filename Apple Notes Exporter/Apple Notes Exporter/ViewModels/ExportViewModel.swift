//
//  ExportViewModel.swift
//  Apple Notes Exporter
//
//  ViewModel for managing note export operations
//  Handles export progress, file writing, and attachment handling
//

import Foundation
import SwiftUI
import OSLog
import HtmlToPdf
import SQLite3

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

// MARK: - Progress Tracker Actor

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
            // Start exporting
            exportState = .exporting(ExportProgress(
                current: 0,
                total: notes.count,
                message: "Starting export..."
            ))

            // Group notes by account and folder for organized output
            let hierarchy = try await organizeNotesByHierarchy(notes)

            // Create all directory structure upfront
            for (accountName, folders) in hierarchy {
                let accountURL = outputURL.appendingPathComponent(sanitizeFilename(accountName))
                try FileManager.default.createDirectory(at: accountURL, withIntermediateDirectories: true)

                for (folderPath, _) in folders {
                    let folderURL = accountURL.appendingPathComponent(folderPath)
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                }
            }

            // Flatten notes with their folder paths for concurrent export
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

            // Export notes concurrently
            try await exportNotesConcurrently(
                notesWithPaths,
                format: format,
                includeAttachments: includeAttachments,
                totalNotes: notes.count,
                startTime: startTime
            )

            // Check if export was cancelled before marking as completed
            guard !shouldCancel else {
                // State already set to .cancelled in exportNotesConcurrently
                return
            }

            // Set folder timestamps based on their notes
            try await setFolderTimestamps(hierarchy: hierarchy, outputURL: outputURL)

            // Export completed successfully
            let successfulNotes = notes.count - failedNotesCount
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
        _ notesWithPaths: [(note: NotesNote, folderURL: URL)],
        format: ExportFormat,
        includeAttachments: Bool,
        totalNotes: Int,
        startTime: Date
    ) async throws {
        let tracker = ExportProgressTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = notesWithPaths.makeIterator()
            var activeTaskCount = 0

            // Launch initial batch of concurrent exports
            while activeTaskCount < maxConcurrentExports, let noteWithPath = iterator.next() {
                group.addTask {
                    await self.exportNoteConcurrently(
                        noteWithPath.note,
                        toDirectory: noteWithPath.folderURL,
                        format: format,
                        includeAttachments: includeAttachments,
                        tracker: tracker
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
                    group.addTask {
                        await self.exportNoteConcurrently(
                            noteWithPath.note,
                            toDirectory: noteWithPath.folderURL,
                            format: format,
                            includeAttachments: includeAttachments,
                            tracker: tracker
                        )
                    }
                }
            }
        }
    }

    /// Export a single note concurrently (non-throwing wrapper for TaskGroup)
    private func exportNoteConcurrently(
        _ note: NotesNote,
        toDirectory directory: URL,
        format: ExportFormat,
        includeAttachments: Bool,
        tracker: ExportProgressTracker
    ) async {
        do {
            try await exportNoteSafely(
                note,
                toDirectory: directory,
                format: format,
                includeAttachments: includeAttachments,
                tracker: tracker
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
        tracker: ExportProgressTracker
    ) async throws {
        // Check for cancellation before starting export
        try Task.checkCancellation()

        // Generate unique filename early (handles duplicates)
        let baseFilename = note.sanitizedFileName
        let filename = generateUniqueFilename(
            baseName: baseFilename,
            extension: format.fileExtension,
            inDirectory: directory
        )
        let fileURL = directory.appendingPathComponent(filename)
        let uniqueBaseName = filename.replacingOccurrences(of: ".\(format.fileExtension)", with: "")

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
        } else {
            // Generate content based on format
            let content = try await generateContent(for: note, format: format, attachmentPaths: attachmentPaths, exportDirectory: directory)

            // Write to file
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            log("✓ Exported note: \(note.title)")
        }

        // Set file timestamps to match note's creation and modification dates
        try setFileTimestamps(fileURL, creationDate: note.creationDate, modificationDate: note.modificationDate)
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

        // Filter out non-file attachments (inline content embedded in note)
        let nonFileAttachmentPrefixes = [
            "com.apple.notes.table",                    // Tables
            "com.apple.notes.inlinetextattachment",     // Hashtags, calculations, etc.
            "com.apple.notes.inlinehashtagattachment",  // Hashtags (legacy)
            "com.apple.notes.inlinementionattachment",  // Mentions
            "com.apple.paper",                          // Apple Paper documents
            "public.url"                                // URLs
        ]

        let fileAttachments = attachments.filter { attachment in
            !nonFileAttachmentPrefixes.contains { prefix in
                attachment.typeUTI.hasPrefix(prefix)
            }
        }

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
            // Check for cancellation before processing each attachment
            try Task.checkCancellation()

            do {
                // Fetch attachment data from repository
                let data = try await repository.fetchAttachment(id: attachment.id)

                // Determine base filename
                // If attachment.filename is not available, try to get it from the database
                let baseFilename: String
                if let filename = attachment.filename {
                    baseFilename = filename
                } else if let fetchedFilename = await repository.fetchAttachmentFilename(id: attachment.id) {
                    baseFilename = fetchedFilename
                } else {
                    // Final fallback to UUID with extension
                    baseFilename = "\(attachment.id).\(attachment.fileExtension ?? "bin")"
                }

                // Handle filename collisions by adding a counter suffix
                let finalFilename: String
                if let count = usedFilenames[baseFilename] {
                    // This filename has been used before, add a counter
                    let (name, ext) = splitFilename(baseFilename)
                    finalFilename = "\(name) (\(count + 1)).\(ext)"
                    usedFilenames[baseFilename] = count + 1
                } else {
                    // First time using this filename
                    finalFilename = baseFilename
                    usedFilenames[baseFilename] = 1
                }

                let fileURL = attachmentsURL.appendingPathComponent(finalFilename)

                // Write attachment to disk
                try data.write(to: fileURL)

                // Set attachment timestamps to match note's dates
                try setFileTimestamps(fileURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)

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
            try setFileTimestamps(attachmentsURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)
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
        // Filter out non-file attachments (inline content embedded in note)
        let nonFileAttachmentPrefixes = [
            "com.apple.notes.table",                    // Tables
            "com.apple.notes.inlinetextattachment",     // Hashtags, calculations, etc.
            "com.apple.notes.inlinehashtagattachment",  // Hashtags (legacy)
            "com.apple.notes.inlinementionattachment",  // Mentions
            "com.apple.paper",                          // Apple Paper documents
            "public.url"                                // URLs
        ]

        let fileAttachments = attachments.filter { attachment in
            !nonFileAttachmentPrefixes.contains { prefix in
                attachment.typeUTI.hasPrefix(prefix)
            }
        }

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
            // Check for cancellation before processing each attachment
            try Task.checkCancellation()

            do {
                // Fetch attachment data from repository
                let data = try await repository.fetchAttachment(id: attachment.id)

                // Determine base filename
                // If attachment.filename is not available, try to get it from the database
                let baseFilename: String
                if let filename = attachment.filename {
                    baseFilename = filename
                } else if let fetchedFilename = await repository.fetchAttachmentFilename(id: attachment.id) {
                    baseFilename = fetchedFilename
                } else {
                    // Final fallback to UUID with extension
                    baseFilename = "\(attachment.id).\(attachment.fileExtension ?? "bin")"
                }

                // Handle filename collisions by adding a counter suffix
                let finalFilename: String
                if let count = usedFilenames[baseFilename] {
                    // This filename has been used before, add a counter
                    let (name, ext) = splitFilename(baseFilename)
                    finalFilename = "\(name) (\(count + 1)).\(ext)"
                    usedFilenames[baseFilename] = count + 1
                } else {
                    // First time using this filename
                    finalFilename = baseFilename
                    usedFilenames[baseFilename] = 1
                }

                let fileURL = attachmentsURL.appendingPathComponent(finalFilename)

                // Write attachment to disk
                try data.write(to: fileURL)

                // Set attachment timestamps to match note's dates
                try setFileTimestamps(fileURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)

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
            try setFileTimestamps(attachmentsURL, creationDate: noteCreationDate, modificationDate: noteModificationDate)
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
    private func generateContent(for note: NotesNote, format: ExportFormat, attachmentPaths: [String: String] = [:], exportDirectory: URL? = nil) async throws -> String {
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
        }
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

        // Process HTML to replace attachment markers with actual content
        var processedHTML = htmlBody

        // Only process attachments if we have a database connection and attachments to process
        if !note.attachments.isEmpty {
            // Open database connection for attachment processing
            var db: OpaquePointer?
            if sqlite3_open(databasePath, &db) == SQLITE_OK, let database = db {
                let processor = HTMLAttachmentProcessor(database: database)
                processedHTML = processor.processHTML(
                    html: htmlBody,
                    attachments: note.attachments,
                    attachmentPaths: attachmentPaths,
                    exportDirectory: exportDirectory?.path,
                    embedImages: htmlConfig.embedImagesInline,
                    linkEmbeddedImages: htmlConfig.linkEmbeddedImages
                )
                sqlite3_close(database)
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

        // Fetch all accounts and folders from repository
        let accounts = try await repository.fetchAccounts()
        let folders = try await repository.fetchFolders()

        // Create lookup dictionaries for faster access
        var accountLookup: [String: String] = [:]
        for account in accounts {
            accountLookup[account.id] = account.name
        }

        var folderLookup: [String: NotesFolder] = [:]
        for folder in folders {
            folderLookup[folder.id] = folder
        }

        for note in notes {
            let accountName = accountLookup[note.accountId] ?? "Unknown Account"
            let accountKey = sanitizeFilename(accountName)

            // Build folder path by walking up the parent chain
            let folderPath = buildFolderPath(folderId: note.folderId, folderLookup: folderLookup)

            if hierarchy[accountKey] == nil {
                hierarchy[accountKey] = [:]
            }

            if hierarchy[accountKey]![folderPath] == nil {
                hierarchy[accountKey]![folderPath] = []
            }

            hierarchy[accountKey]![folderPath]!.append(note)
        }

        return hierarchy
    }

    /// Build a folder path string by walking up the parent folder chain
    private func buildFolderPath(folderId: String, folderLookup: [String: NotesFolder]) -> String {
        guard let folder = folderLookup[folderId] else {
            return sanitizeFilename("Unknown Folder")
        }

        var pathComponents: [String] = [sanitizeFilename(folder.name)]

        // Walk up the parent chain
        var currentParentId = folder.parentId
        while let parentId = currentParentId, let parentFolder = folderLookup[parentId] {
            pathComponents.insert(sanitizeFilename(parentFolder.name), at: 0)
            currentParentId = parentFolder.parentId
        }

        // Join with "/" to create a relative path
        return pathComponents.joined(separator: "/")
    }

    /// Split a filename into name and extension
    private func splitFilename(_ filename: String) -> (name: String, ext: String) {
        if let lastDotIndex = filename.lastIndex(of: "."),
           lastDotIndex != filename.startIndex {
            let name = String(filename[..<lastDotIndex])
            let ext = String(filename[filename.index(after: lastDotIndex)...])
            return (name, ext)
        } else {
            // No extension found
            return (filename, "")
        }
    }

    /// Set file creation and modification timestamps
    private func setFileTimestamps(_ fileURL: URL, creationDate: Date, modificationDate: Date) throws {
        let attributes: [FileAttributeKey: Any] = [
            .creationDate: creationDate,
            .modificationDate: modificationDate
        ]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path)
    }

    /// Set folder timestamps based on the oldest creation date and latest modification date of notes within
    private func setFolderTimestamps(hierarchy: [String: [String: [NotesNote]]], outputURL: URL) async throws {
        for (accountName, folders) in hierarchy {
            let accountURL = outputURL.appendingPathComponent(sanitizeFilename(accountName))

            // Track dates for the account
            var accountOldestCreation: Date?
            var accountLatestModification: Date?

            for (folderPath, notes) in folders {
                guard !notes.isEmpty else { continue }

                let folderURL = accountURL.appendingPathComponent(folderPath)

                // Find oldest creation and latest modification among all notes in this folder
                let oldestCreation = notes.map { $0.creationDate }.min() ?? Date()
                let latestModification = notes.map { $0.modificationDate }.max() ?? Date()

                // Set folder timestamps
                try setFileTimestamps(folderURL, creationDate: oldestCreation, modificationDate: latestModification)

                // Track for account-level timestamps
                if accountOldestCreation == nil || oldestCreation < accountOldestCreation! {
                    accountOldestCreation = oldestCreation
                }
                if accountLatestModification == nil || latestModification > accountLatestModification! {
                    accountLatestModification = latestModification
                }
            }

            // Set account folder timestamps
            if let oldestCreation = accountOldestCreation,
               let latestModification = accountLatestModification {
                try setFileTimestamps(accountURL, creationDate: oldestCreation, modificationDate: latestModification)
            }
        }
    }

    /// Sanitize filename for filesystem
    private func sanitizeFilename(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.newlines)
            .union(.illegalCharacters)
            .union(.controlCharacters)

        return name.components(separatedBy: invalidCharacters).joined(separator: "_")
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

    /// Generate unique filename by checking for collisions and appending counter if needed
    private func generateUniqueFilename(baseName: String, extension: String, inDirectory directory: URL) -> String {
        let initialFilename = "\(baseName).\(`extension`)"
        let initialURL = directory.appendingPathComponent(initialFilename)

        // If no collision, use the original name
        if !FileManager.default.fileExists(atPath: initialURL.path) {
            return initialFilename
        }

        // File exists, find unique name by appending counter (starting from 2)
        var counter = 2
        while true {
            let uniqueFilename = "\(baseName) (\(counter)).\(`extension`)"
            let uniqueURL = directory.appendingPathComponent(uniqueFilename)

            if !FileManager.default.fileExists(atPath: uniqueURL.path) {
                return uniqueFilename
            }

            counter += 1

            // Safety limit to prevent infinite loop
            if counter > 10000 {
                // Fall back to using UUID if we somehow have 10000 files with same name
                return "\(baseName)_\(UUID().uuidString).\(`extension`)"
            }
        }
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
