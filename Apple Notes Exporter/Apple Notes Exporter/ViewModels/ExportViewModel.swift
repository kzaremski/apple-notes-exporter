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

    private let maxConcurrentExports = 8  // Number of notes to export concurrently
    private let logLock = NSLock()  // Thread-safe logging

    // MARK: - Dependencies

    private let repository: NotesRepository

    // MARK: - Initialization

    init(repository: NotesRepository = DatabaseNotesRepository()) {
        self.repository = repository
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

        // Generate unique filename (handles duplicates)
        let baseFilename = note.sanitizedFileName
        let filename = generateUniqueFilename(
            baseName: baseFilename,
            extension: format.fileExtension,
            inDirectory: directory
        )
        let fileURL = directory.appendingPathComponent(filename)

        // Handle PDF export separately (binary format, requires WebKit)
        if format == .pdf {
            // Check for cancellation before expensive PDF generation
            try Task.checkCancellation()

            // Use PDF configuration
            let pdfConfig = configurations.pdf
            let html = generateHTML(for: note, config: pdfConfig.htmlConfiguration, forPDF: true)

            // Apply page size and margin configuration
            let pageSize = pdfConfig.pageSize.dimensions
            let margins = pdfConfig.htmlConfiguration.toPDFEdgeInsets()
            let pdfConfiguration = HtmlToPdf.PDFConfiguration(
                margins: margins,
                paperSize: CGSize(width: pageSize.width, height: pageSize.height)
            )
            try await html.print(to: fileURL, configuration: pdfConfiguration)
            log("✓ Exported PDF: \(note.title)")
        } else {
            // Generate content based on format
            let content = try generateContent(for: note, format: format)

            // Write to file
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            log("✓ Exported note: \(note.title)")
        }

        // Export attachments if requested
        if includeAttachments && note.hasAttachments {
            // Check for cancellation before processing attachments
            try Task.checkCancellation()

            // Use the unique filename base (without extension) for attachment folder
            let uniqueBaseName = filename.replacingOccurrences(of: ".\(format.fileExtension)", with: "")
            try await exportAttachmentsSafely(
                note.attachments,
                toDirectory: directory,
                noteBaseName: uniqueBaseName,
                noteTitle: note.title,
                tracker: tracker
            )
        }
    }

    /// Export attachments for a note (thread-safe version for concurrent export)
    private func exportAttachmentsSafely(
        _ attachments: [NotesAttachment],
        toDirectory directory: URL,
        noteBaseName: String,
        noteTitle: String,
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

        // Export each attachment
        for attachment in fileAttachments {
            // Check for cancellation before processing each attachment
            try Task.checkCancellation()

            do {
                // Fetch attachment data from repository
                let data = try await repository.fetchAttachment(id: attachment.id)

                // Determine filename
                let filename = attachment.filename ?? "\(attachment.id).\(attachment.fileExtension ?? "bin")"
                let fileURL = attachmentsURL.appendingPathComponent(filename)

                // Write attachment to disk
                try data.write(to: fileURL)
                log("✓ Exported attachment: \(filename) for note '\(noteTitle)'")

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
    private func generateContent(for note: NotesNote, format: ExportFormat) throws -> String {
        switch format {
        case .html:
            return generateHTML(for: note)
        case .markdown:
            return note.toMarkdown()
        case .txt:
            return note.toPlainText()
        case .rtf:
            // Use RTF font configuration
            return note.toRTF(
                fontFamily: configurations.rtf.fontFamily.rtfFontName,
                fontSize: configurations.rtf.fontSizePoints
            )
        case .tex:
            // Use LaTeX template from configuration
            return note.toLatex(template: configurations.latex.template)
        case .pdf:
            return generateHTML(for: note)
        }
    }

    // MARK: - Content Generation

    private func generateHTML(for note: NotesNote, config: HTMLConfiguration? = nil, forPDF: Bool = false) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        // Use provided config or default from configurations
        let htmlConfig = config ?? configurations.html

        // Build CSS for font and margin
        let fontFamily = htmlConfig.fontFamily.cssFontStack
        let fontSize = "\(htmlConfig.fontSizePoints)pt"

        // For PDF, margins are handled by PDFConfiguration, so set body margin to 0
        // For HTML export, use the configured margin
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
            </style>
        </head>
        <body>
            <div class="content">
                \(note.htmlBody)
            </div>
        </body>
        </html>
        """
    }

    // MARK: - Helper Methods

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
