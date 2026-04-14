//
//  AppIntents.swift
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
import AppIntents
import OSLog
import HtmlToPdf

// MARK: - Export Format Enum for App Intents

@available(macOS 13.0, *)
enum ExportFormatOption: String, AppEnum {
    case html = "HTML"
    case pdf = "PDF"
    case tex = "TEX"
    case markdown = "MD"
    case rtf = "RTF"
    case txt = "TXT"
    case json = "JSON"
    case jsonl = "JSONL"
    case xml = "XML"
    case csv = "CSV"
    case opml = "OPML"
    case org = "ORG"
    case rst = "RST"
    case adoc = "ADOC"
    case docx = "DOCX"
    case odt = "ODT"
    case epub = "EPUB"
    case enex = "ENEX"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Export Format"

    static var caseDisplayRepresentations: [ExportFormatOption: DisplayRepresentation] = [
        .html: "HTML",
        .pdf: "PDF",
        .tex: "LaTeX",
        .markdown: "Markdown",
        .rtf: "RTF",
        .txt: "Plain Text",
        .json: "JSON",
        .jsonl: "JSON Lines",
        .xml: "XML",
        .csv: "CSV",
        .opml: "OPML",
        .org: "Org Mode",
        .rst: "reStructuredText",
        .adoc: "AsciiDoc",
        .docx: "Word (DOCX)",
        .odt: "OpenDocument (ODT)",
        .epub: "EPUB",
        .enex: "Evernote (ENEX)",
    ]

    /// Convert to the core ExportFormat type
    var toExportFormat: ExportFormat {
        ExportFormat(rawValue: self.rawValue)!
    }
}

// MARK: - Export Notes Intent

@available(macOS 13.0, *)
struct ExportNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Export Apple Notes"
    static var description = IntentDescription(
        "Export Apple Notes to various file formats.",
        categoryName: "Export"
    )

    @Parameter(title: "Format", description: "The file format to export notes to.")
    var format: ExportFormatOption

    @Parameter(title: "Output Folder", description: "Path to the output directory (e.g. ~/Desktop/notes).")
    var outputPath: String

    @Parameter(title: "Folder", description: "Only export notes from this folder (case-insensitive). Leave empty for all folders.", default: nil)
    var folderFilter: String?

    @Parameter(title: "Account", description: "Only export notes from this account (case-insensitive). Leave empty for all accounts.", default: nil)
    var accountFilter: String?

    @Parameter(title: "Include Attachments", description: "Export file attachments alongside notes.", default: false)
    var includeAttachments: Bool

    @Parameter(title: "Date Prefix", description: "Prepend creation date to filenames.", default: false)
    var datePrefix: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Export notes as \(\.$format) to \(\.$outputPath)") {
            \.$folderFilter
            \.$accountFilter
            \.$includeAttachments
            \.$datePrefix
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let exportFormat = format.toExportFormat
        let resolvedPath = (outputPath as NSString).expandingTildeInPath
        let outputURL = URL(fileURLWithPath: resolvedPath)

        // Create output directory
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let repo = DatabaseNotesRepository()
        let databasePath = "\(NSHomeDirectory())/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"

        // Fetch data
        let accounts = try await repo.fetchAccounts()
        let folders = try await repo.fetchFolders()
        var notes = try await repo.fetchNotes()

        // Apply filters
        if let accountName = accountFilter, !accountName.isEmpty {
            let matchingIds = Set(accounts
                .filter { $0.name.localizedCaseInsensitiveCompare(accountName) == .orderedSame }
                .map { $0.id })
            notes = notes.filter { matchingIds.contains($0.accountId) }
        }

        if let folderName = folderFilter, !folderName.isEmpty {
            let matchingIds = Set(folders
                .filter { $0.name.localizedCaseInsensitiveCompare(folderName) == .orderedSame }
                .map { $0.id })
            notes = notes.filter { matchingIds.contains($0.folderId) }
        }

        guard !notes.isEmpty else {
            return .result(value: "No notes matched the specified filters.")
        }

        // Build lookups
        var accountNames: [String: String] = [:]
        for account in accounts { accountNames[account.id] = account.name }
        var folderLookup: [String: NotesFolder] = [:]
        for folder in folders { folderLookup[folder.id] = folder }

        // Organize and create directories
        var hierarchy: [(accountName: String, folderPath: String, note: NotesNote)] = []
        for note in notes {
            let acctName = sanitizeFileNameString(accountNames[note.accountId] ?? "Unknown Account")
            let fPath = buildExportFolderPath(folderId: note.folderId, folderLookup: folderLookup)
            hierarchy.append((accountName: acctName, folderPath: fPath, note: note))
        }

        var createdDirs: Set<String> = []
        for item in hierarchy {
            let dirURL = outputURL.appendingPathComponent(item.accountName).appendingPathComponent(item.folderPath)
            if !createdDirs.contains(dirURL.path) {
                try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                createdDirs.insert(dirURL.path)
            }
        }

        // Export
        var successCount = 0
        var failCount = 0

        for item in hierarchy {
            let note = item.note
            let folderURL = outputURL.appendingPathComponent(item.accountName).appendingPathComponent(item.folderPath)

            do {
                let baseFilename: String
                if datePrefix {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    baseFilename = "\(formatter.string(from: note.creationDate)) \(note.sanitizedFileName)"
                } else {
                    baseFilename = note.sanitizedFileName
                }

                let filename = generateUniqueExportFilename(baseName: baseFilename, ext: exportFormat.fileExtension, inDirectory: folderURL)
                let fileURL = folderURL.appendingPathComponent(filename)
                let uniqueBaseName = filename.replacingOccurrences(of: ".\(exportFormat.fileExtension)", with: "")

                // Attachments
                var attachmentPaths: [String: String] = [:]
                if includeAttachments && note.hasAttachments {
                    attachmentPaths = try await intentExportAttachments(
                        note: note,
                        toDirectory: folderURL,
                        noteBaseName: uniqueBaseName,
                        repo: repo
                    )
                }

                // Generate HTML
                let html = try await intentGenerateHTML(
                    for: note,
                    repo: repo,
                    databasePath: databasePath,
                    attachmentPaths: attachmentPaths,
                    exportDirectory: folderURL,
                    forPDF: exportFormat == .pdf
                )

                // Write output
                if exportFormat == .pdf {
                    let pdfConfig = HtmlToPdf.PDFConfiguration(
                        margins: HtmlToPdf.EdgeInsets(top: 36, left: 36, bottom: 36, right: 36),
                        paperSize: CGSize(width: 612, height: 792)
                    )
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await html.print(to: fileURL, configuration: pdfConfig) }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 60_000_000_000)
                            throw NSError(domain: "ANE", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDF timeout"])
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                } else if exportFormat.isBinaryFormat {
                    let enrichedNote = noteWithHTML(note, html: html)
                    let data: Data
                    switch exportFormat {
                    case .docx: data = enrichedNote.toDOCX()
                    case .odt:  data = enrichedNote.toODT()
                    case .epub: data = enrichedNote.toEPUB()
                    default: fatalError()
                    }
                    try data.write(to: fileURL)
                } else {
                    let enrichedNote = noteWithHTML(note, html: html)
                    let content = generateExportTextContent(for: enrichedNote, format: exportFormat, folderName: item.folderPath, accountName: item.accountName)
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                }

                try? setExportFileTimestamps(fileURL, creationDate: note.creationDate, modificationDate: note.modificationDate)

                successCount += 1
            } catch {
                failCount += 1
                Logger.noteExport.error("Shortcut export failed for '\(note.title)': \(error.localizedDescription)")
            }
        }

        let summary = "\(successCount) notes exported as \(exportFormat.rawValue). \(failCount > 0 ? "\(failCount) failed." : "")"
        return .result(value: summary)
    }
}

// MARK: - List Accounts Intent

@available(macOS 13.0, *)
struct ListAccountsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Apple Notes Accounts"
    static var description = IntentDescription(
        "List all available Apple Notes accounts.",
        categoryName: "Export"
    )

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let repo = DatabaseNotesRepository()
        let accounts = try await repo.fetchAccounts()
        let names = accounts.map { "\($0.name) (\($0.accountType.displayName))" }
        return .result(value: names)
    }
}

// MARK: - List Folders Intent

@available(macOS 13.0, *)
struct ListFoldersIntent: AppIntent {
    static var title: LocalizedStringResource = "List Apple Notes Folders"
    static var description = IntentDescription(
        "List all folders in Apple Notes, optionally filtered by account.",
        categoryName: "Export"
    )

    @Parameter(title: "Account", description: "Filter by account name (case-insensitive). Leave empty for all.", default: nil)
    var accountFilter: String?

    static var parameterSummary: some ParameterSummary {
        Summary("List folders") {
            \.$accountFilter
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let repo = DatabaseNotesRepository()
        let accounts = try await repo.fetchAccounts()
        let folders = try await repo.fetchFolders()

        var accountNames: [String: String] = [:]
        for account in accounts { accountNames[account.id] = account.name }

        var filtered = folders
        if let filter = accountFilter, !filter.isEmpty {
            let matchingIds = Set(accounts
                .filter { $0.name.localizedCaseInsensitiveCompare(filter) == .orderedSame }
                .map { $0.id })
            filtered = folders.filter { matchingIds.contains($0.accountId) }
        }

        let names = filtered.map { folder in
            let acctName = accountNames[folder.accountId] ?? "Unknown"
            return "\(acctName)/\(folder.name)"
        }
        return .result(value: names)
    }
}

// MARK: - App Shortcuts Provider

@available(macOS 13.0, *)
struct ANEShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ExportNotesIntent(),
            phrases: [
                "Export notes with \(.applicationName)",
                "Export Apple Notes with \(.applicationName)",
                "Back up notes with \(.applicationName)",
            ],
            shortTitle: "Export Notes",
            systemImageName: "square.and.arrow.up"
        )
        AppShortcut(
            intent: ListAccountsIntent(),
            phrases: [
                "List accounts in \(.applicationName)",
            ],
            shortTitle: "List Accounts",
            systemImageName: "person.2"
        )
        AppShortcut(
            intent: ListFoldersIntent(),
            phrases: [
                "List folders in \(.applicationName)",
            ],
            shortTitle: "List Folders",
            systemImageName: "folder"
        )
    }
}

// MARK: - Intent-specific Helpers

@available(macOS 13.0, *)
private func intentGenerateHTML(
    for note: NotesNote,
    repo: DatabaseNotesRepository,
    databasePath: String,
    attachmentPaths: [String: String],
    exportDirectory: URL,
    forPDF: Bool
) async throws -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .medium
    dateFormatter.timeStyle = .short

    let htmlBody: String
    if let existingHTML = note.htmlBody {
        htmlBody = existingHTML
    } else {
        do {
            htmlBody = try await repo.generateHTML(forNoteId: note.id)
        } catch {
            htmlBody = "<html><body><pre>\(note.plaintext.htmlEscaped)</pre></body></html>"
        }
    }

    var processedHTML = htmlBody
    if let bodyStart = processedHTML.range(of: "<body>"),
       let bodyEnd = processedHTML.range(of: "</body>") {
        processedHTML = String(processedHTML[bodyStart.upperBound..<bodyEnd.lowerBound])
    }

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
                    exportDirectory: exportDirectory.path,
                    embedImages: true,
                    linkEmbeddedImages: false
                )
            }
        }
    }

    let fontFamily = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
    let marginValue = forPDF ? "0" : "36pt auto"
    let imageConstraint = forPDF ? "max-height: 648pt; height: auto;" : ""

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
            body { font-family: \(fontFamily); font-size: 14pt; max-width: 800px; margin: \(marginValue); padding: 0 20px; line-height: 1.0; }
            h1, h2, h3, h4, h5, h6, p { margin: 0; padding: 0; line-height: 1.0; }
            ul, ol { margin: 0; margin-left: 1.5em; padding: 0; padding-left: 0.5em; }
            li { margin: 0; padding: 0; line-height: 1.0; }
            img { max-width: 100%; \(imageConstraint) }
        </style>
    </head>
    <body>
        <div class="content">\(processedHTML)</div>
    </body>
    </html>
    """
}

@available(macOS 13.0, *)
private func intentExportAttachments(
    note: NotesNote,
    toDirectory directory: URL,
    noteBaseName: String,
    repo: DatabaseNotesRepository
) async throws -> [String: String] {
    var attachmentPaths: [String: String] = [:]

    let fileAttachments = filterFileAttachments(note.attachments)
    guard !fileAttachments.isEmpty else { return [:] }

    let attachmentsURL = directory.appendingPathComponent("\(noteBaseName) (Attachments)")
    try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

    var usedFilenames: [String: Int] = [:]

    for attachment in fileAttachments {
        // Expand gallery containers into child attachments
        if attachment.typeUTI == "com.apple.notes.gallery" {
            do {
                let children = try await repo.fetchGalleryChildren(
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
                    try? setExportFileTimestamps(fileURL, creationDate: note.creationDate, modificationDate: note.modificationDate)

                    let relativePath = "\(noteBaseName) (Attachments)/\(childFinal)"
                    attachmentPaths[child.id] = relativePath
                    if attachmentPaths[attachment.id] == nil {
                        attachmentPaths[attachment.id] = relativePath
                    }
                }
            } catch {
                Logger.noteExport.warning("Gallery expansion failed for \(attachment.id): \(error.localizedDescription)")
            }
            continue
        }

        do {
            let data = try await repo.fetchAttachment(id: attachment.id)

            let baseFilename: String
            if let filename = attachment.filename {
                baseFilename = filename
            } else if let fetchedFilename = await repo.fetchAttachmentFilename(id: attachment.id) {
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
                finalFilename = "\(name) (\(count + 1)).\(ext.isEmpty ? "bin" : ext)"
                usedFilenames[baseFilename] = count + 1
            } else {
                finalFilename = baseFilename
                usedFilenames[baseFilename] = 1
            }

            let fileURL = attachmentsURL.appendingPathComponent(finalFilename)
            try data.write(to: fileURL)
            try? setExportFileTimestamps(fileURL, creationDate: note.creationDate, modificationDate: note.modificationDate)

            attachmentPaths[attachment.id] = "\(noteBaseName) (Attachments)/\(finalFilename)"
        } catch {
            Logger.noteExport.warning("Shortcut: attachment \(attachment.id) failed: \(error.localizedDescription)")
        }
    }

    return attachmentPaths
}
