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
    case pdfVector = "PDFVECTOR"
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
        .pdfVector: "Vector PDF",
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

// MARK: - Font Family

@available(macOS 13.0, *)
enum FontFamilyOption: String, AppEnum {
    case system, serif, sansSerif, monospace

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Font Family"

    static var caseDisplayRepresentations: [FontFamilyOption: DisplayRepresentation] = [
        .system: "System", .serif: "Serif", .sansSerif: "Sans-Serif", .monospace: "Monospace",
    ]

    var toHTMLFontFamily: HTMLConfiguration.FontFamily {
        switch self {
        case .system:    return .system
        case .serif:     return .serif
        case .sansSerif: return .sansSerif
        case .monospace: return .monospace
        }
    }
}

// MARK: - Filename Date Format

@available(macOS 13.0, *)
enum FilenameDateFormatOption: String, AppEnum {
    case iso
    case us
    case eu

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Date Format"

    static var caseDisplayRepresentations: [FilenameDateFormatOption: DisplayRepresentation] = [
        .iso: "ISO (2026-09-08)",
        .us: "US (09-08-2026)",
        .eu: "European (08-09-2026)",
    ]

    var toFilenameDateFormat: FilenameDateFormat {
        switch self {
        case .iso: return .iso
        case .us:  return .usDate
        case .eu:  return .euDate
        }
    }
}

// MARK: - Export Notes Intent

@available(macOS 13.0, *)
struct ExportNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Export Apple Notes"
    static var description = IntentDescription(
        "Export Apple Notes to any supported file format, with the same options as the command line tool.",
        categoryName: "Export"
    )

    @Parameter(title: "Format", description: "The file format to export notes to.")
    var format: ExportFormatOption

    @Parameter(title: "Output", description: "Destination directory, or the .zip to create when Zip Archive is on.")
    var outputPath: String

    // MARK: Selection

    @Parameter(title: "Folder", description: "Only export notes from this folder: an exact name or folder id. Leave empty for all folders.", default: nil)
    var folderFilter: String?

    @Parameter(title: "Match Folder by Substring", description: "Treat Folder as a substring instead of an exact name.", default: false)
    var folderContains: Bool

    @Parameter(title: "Include Subfolders", description: "Include notes in subfolders of the chosen folder.", default: true)
    var includeSubfolders: Bool

    @Parameter(title: "Account", description: "Only export notes from this account. Leave empty for all accounts.", default: nil)
    var accountFilter: String?

    @Parameter(title: "Note IDs", description: "Export these specific notes by id, in addition to anything the folder filter selects. Leave empty to use the filters alone.", default: nil)
    var noteIDs: [String]?

    @Parameter(title: "Title Contains", description: "Only export notes whose title contains this text.", default: nil)
    var titleContains: String?

    @Parameter(title: "Modified After", description: "Only export notes modified after this date.")
    var modifiedAfter: Date?

    @Parameter(title: "Modified Before", description: "Only export notes modified before this date.")
    var modifiedBefore: Date?

    @Parameter(title: "Include Recently Deleted", description: "Include notes in Recently Deleted.", default: false)
    var includeDeleted: Bool

    // MARK: Output shape

    @Parameter(title: "Zip Archive", description: "Deliver the export as a single .zip. Cannot be combined with Incremental Sync.", default: false)
    var zipOutput: Bool

    @Parameter(title: "Tar Archive", description: "Deliver the export as a single .tar. Cannot be combined with Incremental Sync.", default: false)
    var tarOutput: Bool

    @Parameter(title: "Single File", description: "Join every note into one file. Not available for PDF, DOCX, ODT or EPUB.", default: false)
    var concatenate: Bool

    @Parameter(title: "Incremental Sync", description: "Only export notes that are new or changed since the last export to this folder.", default: false)
    var incremental: Bool

    @Parameter(title: "Reset Sync", description: "Discard the existing sync manifest first, forcing a full re-export.", default: false)
    var resetSync: Bool

    // MARK: Content

    @Parameter(title: "Include Attachments", description: "Export file attachments alongside notes.", default: false)
    var includeAttachments: Bool

    @Parameter(title: "Shared Attachments Folder", description: "Collect attachments under one Attachments folder instead of beside each note.", default: false)
    var sharedAttachments: Bool

    @Parameter(title: "HTML Folder Indexes", description: "Write an index.html in each folder so an HTML export is browsable.", default: false)
    var htmlIndexes: Bool

    @Parameter(title: "Date Prefix", description: "Prepend the creation date to filenames.", default: false)
    var datePrefix: Bool

    @Parameter(title: "Date Format", description: "Format for the filename date prefix.", default: .iso)
    var dateFormat: FilenameDateFormatOption

    @Parameter(title: "Font Family", description: "Font family for HTML, PDF and RTF output.", default: .system)
    var fontFamily: FontFamilyOption

    @Parameter(title: "Font Size", description: "Font size in points for HTML, PDF and RTF output.", default: 14.0)
    var fontSize: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Export notes as \(\.$format) to \(\.$outputPath)") {
            \.$folderFilter
            \.$folderContains
            \.$includeSubfolders
            \.$accountFilter
            \.$noteIDs
            \.$titleContains
            \.$modifiedAfter
            \.$modifiedBefore
            \.$includeDeleted
            \.$zipOutput
            \.$tarOutput
            \.$concatenate
            \.$incremental
            \.$resetSync
            \.$includeAttachments
            \.$sharedAttachments
            \.$htmlIndexes
            \.$datePrefix
            \.$dateFormat
            \.$fontFamily
            \.$fontSize
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let exportFormat = format.toExportFormat

        if zipOutput && tarOutput {
            return .result(value: "Pick either Zip Archive or Tar Archive, not both.")
        }
        let archiveFormat: ExportArchiveFormat? = zipOutput ? .zip : (tarOutput ? .tar : nil)
        if archiveFormat != nil && incremental {
            return .result(value: "An archive cannot be combined with Incremental Sync: the sync manifest has to persist in a folder between runs.")
        }
        if concatenate && !exportFormat.supportsConcatenation {
            return .result(value: "Single File is not available for \(exportFormat.rawValue): it is a packaged format with its own internal structure.")
        }

        let destinationURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath).standardizedFileURL

        // Zip stages into a folder beside the archive so the destination never
        // holds loose note files, matching the CLI and the app.
        let archiveURL: URL?
        let workingURL: URL
        if let archiveFormat {
            let locations = archiveExportLocations(destination: destinationURL, format: archiveFormat)
            archiveURL = locations.archive
            workingURL = locations.staging
        } else {
            archiveURL = nil
            workingURL = destinationURL
        }
        // With Single File the destination may name the file itself, in which
        // case the directory to create is the one containing it. Creating a
        // directory at the file's own path makes the later write collide with
        // it; the CLI and MCP have always done this and Shortcuts did not.
        let directoryToCreate = (concatenate && archiveFormat == nil
            && workingURL.pathExtension.lowercased() == exportFormat.fileExtension)
            ? workingURL.deletingLastPathComponent()
            : workingURL
        try FileManager.default.createDirectory(at: directoryToCreate, withIntermediateDirectories: true)

        if resetSync {
            try? FileManager.default.removeItem(at: workingURL.appendingPathComponent(SyncManifest.filename))
        }

        var configs = ExportConfigurations.default
        configs.includeAttachments = includeAttachments
        configs.sharedAttachmentsFolder = sharedAttachments
        configs.addDateToFilename = datePrefix
        configs.filenameDateFormat = dateFormat.toFilenameDateFormat
        configs.concatenateOutput = concatenate
        configs.incrementalSync = incremental
        configs.html.writeFolderIndexes = htmlIndexes
        configs.html = HTMLConfiguration(
            fontSizePoints: fontSize,
            fontFamily: fontFamily.toHTMLFontFamily,
            marginSize: configs.html.marginSize,
            marginUnit: configs.html.marginUnit,
            embedImagesInline: configs.html.embedImagesInline,
            linkEmbeddedImages: configs.html.linkEmbeddedImages,
            writeFolderIndexes: htmlIndexes
        )

        // Same engine the CLI and the MCP server use, rather than a third
        // export loop that only ever supported a handful of these options.
        let engine = CLIExportEngine(databasePath: defaultNotesDatabasePath(), configurations: configs)

        let folderTokens = folderFilter.map { $0.isEmpty ? [] : [$0] } ?? []
        let wantsTrash = includeDeleted || folderTokens.contains { isRecentlyDeletedFolderName($0) }

        let accounts = try await engine.fetchAccounts()
        let folders = try await engine.fetchFolders()
        let allNotes = try await engine.fetchNotes(includeDeleted: wantsTrash)

        let unmatched = unmatchedFolderFilters(
            filters: folderTokens, folders: folders, matchContains: folderContains
        )
        if !unmatched.isEmpty {
            let names = folders.map(\.name).sorted().joined(separator: ", ")
            return .result(value: "No folder matches \(unmatched.joined(separator: ", ")). Available folders: \(names)")
        }

        var filtered = applyNoteSelection(
            notes: allNotes,
            folders: folders,
            folderFilters: folderTokens,
            matchContains: folderContains,
            includeSubfolders: includeSubfolders,
            includeDeleted: wantsTrash,
            noteIds: noteIDs ?? []
        )

        if let accountName = accountFilter, !accountName.isEmpty {
            let matchingIds = Set(accounts
                .filter { $0.name.localizedCaseInsensitiveContains(accountName) }
                .map { $0.id })
            filtered = filtered.filter { matchingIds.contains($0.accountId) }
        }
        if let tc = titleContains, !tc.isEmpty {
            filtered = filtered.filter { $0.title.localizedCaseInsensitiveContains(tc) }
        }
        if let after = modifiedAfter {
            filtered = filtered.filter { $0.modificationDate > after }
        }
        if let before = modifiedBefore {
            filtered = filtered.filter { $0.modificationDate < before }
        }

        guard !filtered.isEmpty || incremental else {
            return .result(value: "No notes matched the specified filters.")
        }

        do {
            let result = try await engine.exportNotes(
                filtered,
                toDirectory: workingURL,
                format: exportFormat,
                includeAttachments: includeAttachments,
                verbose: false,
                allKnownNoteIds: Set(allNotes.map(\.id)),
                progressHandler: { _, _ in }
            )

            var destination = workingURL.path
            if let archiveURL {
                do {
                    try createArchive(archiveFormat ?? .zip, at: workingURL, to: archiveURL)
                    try? FileManager.default.removeItem(at: workingURL)
                    destination = archiveURL.path
                } catch {
                    try? FileManager.default.removeItem(at: workingURL)
                    return .result(value: "Export finished but the archive could not be written: \(error.localizedDescription)")
                }
            }

            var summary = "\(result.exported) notes exported as \(exportFormat.rawValue) to \(destination)."
            if result.skipped > 0 { summary += " \(result.skipped) unchanged." }
            if result.failed > 0 { summary += " \(result.failed) failed." }
            return .result(value: summary)
        } catch {
            if archiveURL != nil { try? FileManager.default.removeItem(at: workingURL) }
            Logger.noteExport.error("Shortcut export failed: \(error.localizedDescription)")
            return .result(value: "Export failed: \(error.localizedDescription)")
        }
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

// MARK: - List Notes Intent

@available(macOS 13.0, *)
struct ListNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "List Apple Notes"
    static var description = IntentDescription(
        "List notes, optionally filtered by folder, account, title or modification date.",
        categoryName: "Export"
    )

    @Parameter(title: "Folder", description: "Only list notes in this folder: an exact name or folder id.", default: nil)
    var folderFilter: String?

    @Parameter(title: "Match Folder by Substring", description: "Treat Folder as a substring instead of an exact name.", default: false)
    var folderContains: Bool

    @Parameter(title: "Include Subfolders", description: "Include notes in subfolders of the chosen folder.", default: true)
    var includeSubfolders: Bool

    @Parameter(title: "Account", description: "Only list notes from this account.", default: nil)
    var accountFilter: String?

    @Parameter(title: "Title Contains", description: "Only list notes whose title contains this text.", default: nil)
    var titleContains: String?

    @Parameter(title: "Modified After", description: "Only list notes modified after this date.")
    var modifiedAfter: Date?

    @Parameter(title: "Modified Before", description: "Only list notes modified before this date.")
    var modifiedBefore: Date?

    @Parameter(title: "Include Recently Deleted", description: "Include notes in Recently Deleted.", default: false)
    var includeDeleted: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("List Apple Notes") {
            \.$folderFilter
            \.$folderContains
            \.$includeSubfolders
            \.$accountFilter
            \.$titleContains
            \.$modifiedAfter
            \.$modifiedBefore
            \.$includeDeleted
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let repo = DatabaseNotesRepository()
        let folderTokens = folderFilter.map { $0.isEmpty ? [] : [$0] } ?? []
        let wantsTrash = includeDeleted || folderTokens.contains { isRecentlyDeletedFolderName($0) }

        let accounts = try await repo.fetchAccounts()
        let folders = try await repo.fetchFolders()
        let allNotes = try await repo.fetchNotes(includeDeleted: wantsTrash)

        let unmatched = unmatchedFolderFilters(
            filters: folderTokens, folders: folders, matchContains: folderContains
        )
        if !unmatched.isEmpty {
            return .result(value: ["No folder matches \(unmatched.joined(separator: ", "))."])
        }

        var filtered = applyNoteSelection(
            notes: allNotes,
            folders: folders,
            folderFilters: folderTokens,
            matchContains: folderContains,
            includeSubfolders: includeSubfolders,
            includeDeleted: wantsTrash,
            noteIds: []
        )
        if let accountName = accountFilter, !accountName.isEmpty {
            let ids = Set(accounts.filter { $0.name.localizedCaseInsensitiveContains(accountName) }.map { $0.id })
            filtered = filtered.filter { ids.contains($0.accountId) }
        }
        if let tc = titleContains, !tc.isEmpty {
            filtered = filtered.filter { $0.title.localizedCaseInsensitiveContains(tc) }
        }
        if let after = modifiedAfter { filtered = filtered.filter { $0.modificationDate > after } }
        if let before = modifiedBefore { filtered = filtered.filter { $0.modificationDate < before } }

        return .result(value: filtered.map(\.title))
    }
}

// MARK: - Sync Status Intent

@available(macOS 13.0, *)
struct SyncStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Apple Notes Sync Status"
    static var description = IntentDescription(
        "Report the incremental sync state of a previously exported folder. Does not read the Notes database.",
        categoryName: "Export"
    )

    @Parameter(title: "Output Folder", description: "The folder a previous incremental export wrote to.")
    var outputPath: String

    static var parameterSummary: some ParameterSummary {
        Summary("Sync status of \(\.$outputPath)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath).standardizedFileURL
        guard let manifest = SyncManifest.load(from: url) else {
            return .result(value: "No sync manifest in \(url.path). That folder has not been used for an incremental export.")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var summary = "\(manifest.notes.count) notes tracked, last synced \(formatter.string(from: manifest.lastSync))."
        if let run = manifest.history.last {
            summary += " Last run: \(run.added.count) added, \(run.updated.count) updated, \(run.deleted.count) deleted."
        }
        return .result(value: summary)
    }
}

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
            intent: ListNotesIntent(),
            phrases: [
                "List notes in \(.applicationName)",
                "List Apple Notes with \(.applicationName)",
            ],
            shortTitle: "List Notes",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: SyncStatusIntent(),
            phrases: [
                "Check sync status in \(.applicationName)",
            ],
            shortTitle: "Sync Status",
            systemImageName: "clock.arrow.circlepath"
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
