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
            log("✗ Failed to export note '\(note.title)': \(error.localizedDescription)")
            Logger.noteExport.error("Failed to export note '\(note.title)': \(error.localizedDescription)")
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
        // Sanitize filename
        let filename = "\(note.sanitizedFileName).\(format.fileExtension)"
        let fileURL = directory.appendingPathComponent(filename)

        // Generate content based on format
        let content = try generateContent(for: note, format: format)

        // Write to file
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        log("✓ Exported note: \(note.title)")

        // Export attachments if requested
        if includeAttachments && note.hasAttachments {
            try await exportAttachmentsSafely(
                note.attachments,
                toDirectory: directory,
                noteTitle: note.title,
                tracker: tracker
            )
        }
    }

    /// Export attachments for a note (thread-safe version for concurrent export)
    private func exportAttachmentsSafely(
        _ attachments: [NotesAttachment],
        toDirectory directory: URL,
        noteTitle: String,
        tracker: ExportProgressTracker
    ) async throws {
        // Filter out non-file attachments (tables, URLs, etc. that are embedded in note content)
        let nonFileAttachmentTypes = [
            "com.apple.notes.table",
            "public.url",
            "com.apple.notes.inlinetextattachment",
            "com.apple.notes.inlinehashtagattachment",
            "com.apple.notes.inlinementionattachment"
        ]

        let fileAttachments = attachments.filter { attachment in
            !nonFileAttachmentTypes.contains(attachment.typeUTI)
        }

        // Skip if no file attachments to export
        guard !fileAttachments.isEmpty else {
            return
        }

        // Create attachments subfolder with note title
        let sanitizedTitle = sanitizeFilename(noteTitle)
        let attachmentsURL = directory.appendingPathComponent("\(sanitizedTitle) (Attachments)")
        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        // Export each attachment
        for attachment in fileAttachments {
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
                let typeInfo = attachment.typeUTI
                log("✗ Failed to export attachment \(attachment.id) (type: \(typeInfo)) for note '\(noteTitle)': \(error.localizedDescription)")
                Logger.noteExport.warning("Failed to export attachment \(attachment.id) (type: \(typeInfo)): \(error.localizedDescription)")
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

    // MARK: - Private Export Methods

    /// Export a single note to disk
    private func exportNote(
        _ note: NotesNote,
        toDirectory directory: URL,
        format: ExportFormat,
        includeAttachments: Bool,
        currentNoteIndex: Int,
        totalNotes: Int,
        mainMessage: String
    ) async throws {
        // Sanitize filename
        let filename = "\(note.sanitizedFileName).\(format.fileExtension)"
        let fileURL = directory.appendingPathComponent(filename)

        // Generate content based on format
        let content = try generateContent(for: note, format: format)

        // Write to file
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        log("✓ Exported note: \(note.title)")

        // Export attachments if requested
        if includeAttachments && note.hasAttachments {
            try await exportAttachments(
                note.attachments,
                toDirectory: directory,
                noteTitle: note.title,
                currentNoteIndex: currentNoteIndex,
                totalNotes: totalNotes,
                mainMessage: mainMessage
            )
        }
    }

    /// Generate content for a note in the specified format
    private func generateContent(for note: NotesNote, format: ExportFormat) throws -> String {
        switch format {
        case .html:
            return generateHTML(for: note)
        case .markdown:
            return generateMarkdown(for: note)
        case .txt:
            return note.plaintext
        case .rtf:
            return generateRTF(for: note)
        case .tex:
            return generateTeX(for: note)
        case .pdf:
            // PDF requires different handling (not text-based)
            // For now, export as HTML and note that PDF conversion requires external tool
            return generateHTML(for: note)
        }
    }

    /// Export attachments for a note
    private func exportAttachments(_ attachments: [NotesAttachment], toDirectory directory: URL, noteTitle: String, currentNoteIndex: Int, totalNotes: Int, mainMessage: String) async throws {
        // Filter out non-file attachments (tables, URLs, etc. that are embedded in note content)
        let nonFileAttachmentTypes = [
            "com.apple.notes.table",
            "public.url",
            "com.apple.notes.inlinetextattachment",
            "com.apple.notes.inlinehashtagattachment",
            "com.apple.notes.inlinementionattachment"
        ]

        let fileAttachments = attachments.filter { attachment in
            !nonFileAttachmentTypes.contains(attachment.typeUTI)
        }

        // Skip if no file attachments to export
        guard !fileAttachments.isEmpty else {
            return
        }

        // Create attachments subfolder with note title
        let sanitizedTitle = sanitizeFilename(noteTitle)
        let attachmentsURL = directory.appendingPathComponent("\(sanitizedTitle) (Attachments)")
        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        for attachment in fileAttachments {
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
                failedAttachmentsCount += 1
                let typeInfo = attachment.typeUTI
                log("✗ Failed to export attachment \(attachment.id) (type: \(typeInfo)) for note '\(noteTitle)': \(error.localizedDescription)")
                Logger.noteExport.warning("Failed to export attachment \(attachment.id) (type: \(typeInfo)): \(error.localizedDescription)")
                // Continue with other attachments even if one fails
            }
        }
    }

    // MARK: - Content Generation

    private func generateHTML(for note: NotesNote) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(note.title.htmlEscaped)</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    max-width: 800px;
                    margin: 40px auto;
                    padding: 0 20px;
                    line-height: 1.6;
                }
                .metadata {
                    color: #666;
                    font-size: 0.9em;
                    margin-bottom: 20px;
                    padding-bottom: 10px;
                    border-bottom: 1px solid #ddd;
                }
                h1 {
                    margin-bottom: 10px;
                }
            </style>
        </head>
        <body>
            <h1>\(note.title.htmlEscaped)</h1>
            <div class="metadata">
                <p>Created: \(dateFormatter.string(from: note.creationDate))</p>
                <p>Modified: \(dateFormatter.string(from: note.modificationDate))</p>
            </div>
            <div class="content">
                \(note.htmlBody)
            </div>
        </body>
        </html>
        """
    }

    private func generateMarkdown(for note: NotesNote) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        return """
        # \(note.title)

        **Created:** \(dateFormatter.string(from: note.creationDate))
        **Modified:** \(dateFormatter.string(from: note.modificationDate))

        ---

        \(note.plaintext)
        """
    }

    private func generateRTF(for note: NotesNote) -> String {
        // Basic RTF format
        let rtfHeader = "{\\rtf1\\ansi\\deff0"
        let title = "{\\b \\fs32 \(note.title.rtfEscaped)}\n\\par\n"
        let content = note.plaintext.rtfEscaped
        let rtfFooter = "}"

        return "\(rtfHeader)\(title)\(content)\(rtfFooter)"
    }

    private func generateTeX(for note: NotesNote) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        return """
        \\documentclass{article}
        \\usepackage[utf8]{inputenc}
        \\title{\(note.title.texEscaped)}
        \\date{\(dateFormatter.string(from: note.modificationDate))}

        \\begin{document}

        \\maketitle

        \(note.plaintext.texEscaped)

        \\end{document}
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
