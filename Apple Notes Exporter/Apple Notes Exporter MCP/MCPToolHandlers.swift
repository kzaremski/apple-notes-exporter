//
//  MCPToolHandlers.swift
//  Apple Notes Exporter MCP
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
import MCP

// MARK: - Tool Handlers

enum MCPToolHandlers {

    // MARK: - Tool Definitions

    static let allTools: [Tool] = [
        Tool(
            name: "list_accounts",
            description: "List all Apple Notes accounts (iCloud, On My Mac, Exchange, etc.).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
        ),
        Tool(
            name: "list_folders",
            description: "List Apple Notes folders, optionally filtered by account.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "account": .object([
                        "type": .string("string"),
                        "description": .string("Account name filter (partial match, case-insensitive).")
                    ])
                ])
            ])
        ),
        Tool(
            name: "list_notes",
            description: "List notes with optional filtering and sorting. Use include_content to embed plaintext.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "account": .object(["type": .string("string"),
                        "description": .string("Account name filter (partial match).")]),
                    "folder": .object(["type": .string("string"),
                        "description": .string("Folder name filter (partial match).")]),
                    "title_contains": .object(["type": .string("string"),
                        "description": .string("Title substring filter (case-insensitive).")]),
                    "modified_after": .object(["type": .string("string"),
                        "description": .string("ISO 8601 date — return notes modified after this date.")]),
                    "modified_before": .object(["type": .string("string"),
                        "description": .string("ISO 8601 date — return notes modified before this date.")]),
                    "sort": .object([
                        "type": .string("string"),
                        "description": .string("Sort order."),
                        "enum": .array([.string("name"), .string("date-modified"), .string("date-created")])
                    ]),
                    "include_content": .object(["type": .string("boolean"),
                        "description": .string("Include plaintext body of each note in the response.")])
                ])
            ])
        ),
        Tool(
            name: "export_notes",
            description: "Export notes to files. PDF is not supported; use html and convert if needed.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "output": .object(["type": .string("string"),
                        "description": .string("Output directory path (created if absent).")]),
                    "format": .object([
                        "type": .string("string"),
                        "description": .string("Export format."),
                        "enum": .array([.string("html"), .string("markdown"), .string("rtf"), .string("txt"), .string("tex")])
                    ]),
                    "notes": .object(["type": .string("string"),
                        "description": .string("Comma-separated note IDs to export (omit to export all matching).")]),
                    "account": .object(["type": .string("string"),
                        "description": .string("Account name filter (partial match).")]),
                    "folder": .object(["type": .string("string"),
                        "description": .string("Folder name filter (partial match).")]),
                    "title_contains": .object(["type": .string("string"),
                        "description": .string("Title substring filter.")]),
                    "modified_after": .object(["type": .string("string"),
                        "description": .string("ISO 8601 date — export notes modified after this date.")]),
                    "modified_before": .object(["type": .string("string"),
                        "description": .string("ISO 8601 date — export notes modified before this date.")]),
                    "incremental": .object(["type": .string("boolean"),
                        "description": .string("Only export new or changed notes (requires output directory).")]),
                    "reset_sync": .object(["type": .string("boolean"),
                        "description": .string("Delete the sync manifest before exporting, forcing a full re-export.")]),
                    "no_attachments": .object(["type": .string("boolean"),
                        "description": .string("Skip exporting attachments.")]),
                    "add_date_prefix": .object(["type": .string("boolean"),
                        "description": .string("Prefix filenames with the note creation date.")]),
                    "font_family": .object([
                        "type": .string("string"),
                        "description": .string("Font family for HTML/RTF output."),
                        "enum": .array([.string("System"), .string("Serif"), .string("Sans-Serif"), .string("Monospace")])
                    ]),
                    "font_size": .object(["type": .string("number"),
                        "description": .string("Font size in points (default: 14).")])
                ]),
                "required": .array([.string("output"), .string("format")])
            ])
        ),
        Tool(
            name: "sync_status",
            description: "Show the incremental sync state for an output directory. Does not open the Notes database.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "output": .object(["type": .string("string"),
                        "description": .string("Output directory to inspect.")])
                ]),
                "required": .array([.string("output")])
            ])
        )
    ]

    // MARK: - Dispatcher

    static func dispatch(params: CallTool.Parameters) async -> CallTool.Result {
        let args = params.arguments ?? [:]
        do {
            switch params.name {
            case "list_accounts":  return try await handleListAccounts(args: args)
            case "list_folders":   return try await handleListFolders(args: args)
            case "list_notes":     return try await handleListNotes(args: args)
            case "export_notes":   return try await handleExportNotes(args: args)
            case "sync_status":    return try handleSyncStatus(args: args)
            default:
                return errorText("Unknown tool '\(params.name)'.")
            }
        } catch let error as CLIError {
            return errorText(error.message)
        } catch {
            return errorText(error.localizedDescription)
        }
    }

    // MARK: - list_accounts

    private static func handleListAccounts(args: [String: Value]) async throws -> CallTool.Result {
        let engine = CLIExportEngine()
        let accounts = try await engine.fetchAccounts()

        struct AccountDTO: Encodable {
            let id: String
            let name: String
            let type: String
        }
        struct Response: Encodable { let accounts: [AccountDTO]; let count: Int }

        let dtos = accounts.map {
            AccountDTO(id: $0.id, name: $0.name, type: String(describing: $0.accountType))
        }
        return jsonText(Response(accounts: dtos, count: dtos.count))
    }

    // MARK: - list_folders

    private static func handleListFolders(args: [String: Value]) async throws -> CallTool.Result {
        let engine = CLIExportEngine()
        async let allAccounts = engine.fetchAccounts()
        async let allFolders  = engine.fetchFolders()
        let (accounts, folders) = try await (allAccounts, allFolders)

        var filtered = folders
        if let accountFilter = args["account"]?.stringValue?.lowercased() {
            let matchingIds = accounts.filter { $0.name.lowercased().contains(accountFilter) }.map { $0.id }
            filtered = filtered.filter { matchingIds.contains($0.accountId) }
        }

        struct FolderDTO: Encodable {
            let id: String
            let name: String
            let parentId: String?
            let accountId: String
            let accountName: String
        }
        struct Response: Encodable { let folders: [FolderDTO]; let count: Int }
        
        let accountLookup = Swift.Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let dtos = filtered.map {
            FolderDTO(id: $0.id, name: $0.name, parentId: $0.parentId,
                      accountId: $0.accountId, accountName: accountLookup[$0.accountId] ?? "")
        }
        return jsonText(Response(folders: dtos, count: dtos.count))
    }

    // MARK: - list_notes

    private static func handleListNotes(args: [String: Value]) async throws -> CallTool.Result {
        let engine = CLIExportEngine()
        async let allAccounts = engine.fetchAccounts()
        async let allFolders  = engine.fetchFolders()
        async let allNotes    = engine.fetchNotes()
        let (accounts, folders, notes) = try await (allAccounts, allFolders, allNotes)

        var filtered = notes

        if let accountFilter = args["account"]?.stringValue?.lowercased() {
            let ids = accounts.filter { $0.name.lowercased().contains(accountFilter) }.map { $0.id }
            filtered = filtered.filter { ids.contains($0.accountId) }
        }
        if let folderFilter = args["folder"]?.stringValue?.lowercased() {
            let ids = folders.filter { $0.name.lowercased().contains(folderFilter) }.map { $0.id }
            filtered = filtered.filter { ids.contains($0.folderId) }
        }
        if let tc = args["title_contains"]?.stringValue?.lowercased() {
            filtered = filtered.filter { $0.title.lowercased().contains(tc) }
        }
        if let dateStr = args["modified_after"]?.stringValue, let date = parseDate(dateStr) {
            filtered = filtered.filter { $0.modificationDate > date }
        }
        if let dateStr = args["modified_before"]?.stringValue, let date = parseDate(dateStr) {
            filtered = filtered.filter { $0.modificationDate < date }
        }

        let sortStr = args["sort"]?.stringValue ?? "date-modified"
        switch sortStr {
        case "name":          filtered.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        case "date-created":  filtered.sort { $0.creationDate > $1.creationDate }
        default:              filtered.sort { $0.modificationDate > $1.modificationDate }
        }

        let includeContent = args["include_content"]?.boolValue ?? false
        let accountLookup = Swift.Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let folderLookup  = Swift.Dictionary(uniqueKeysWithValues: folders.map  { ($0.id, $0.name) })

        struct NoteDTO: Encodable {
            let id: String
            let title: String
            let folderId: String
            let folderName: String
            let accountId: String
            let accountName: String
            let creationDate: Date
            let modificationDate: Date
            let attachmentCount: Int
            let plaintext: String?
        }
        struct Response: Encodable {
            let notes: [NoteDTO]
            let count: Int
        }

        let dtos = filtered.map {
            NoteDTO(
                id: $0.id, title: $0.title,
                folderId: $0.folderId, folderName: folderLookup[$0.folderId] ?? "",
                accountId: $0.accountId, accountName: accountLookup[$0.accountId] ?? "",
                creationDate: $0.creationDate, modificationDate: $0.modificationDate,
                attachmentCount: $0.attachments.count,
                plaintext: includeContent ? $0.plaintext : nil
            )
        }
        return jsonText(Response(notes: dtos, count: dtos.count))
    }

    // MARK: - export_notes

    private static func handleExportNotes(args: [String: Value]) async throws -> CallTool.Result {
        guard let outputStr = args["output"]?.stringValue else {
            return errorText("Missing required argument 'output'.")
        }
        guard let formatStr = args["format"]?.stringValue,
              let exportFormat = ExportFormat(cliString: formatStr) else {
            return errorText("Missing or invalid 'format'. Valid values: html, markdown, rtf, txt, tex.")
        }
        guard exportFormat != .pdf else {
            return errorText("PDF is not supported. Export as HTML and convert with a PDF printer or pandoc.")
        }

        let outputURL = URL(fileURLWithPath: (outputStr as NSString).expandingTildeInPath).standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        } catch {
            return errorText("Cannot create output directory '\(outputStr)'.")
        }

        // Build configurations
        var configs = ExportConfigurations.default
        configs.includeAttachments = !(args["no_attachments"]?.boolValue ?? false)
        configs.addDateToFilename  = args["add_date_prefix"]?.boolValue ?? false
        configs.incrementalSync    = args["incremental"]?.boolValue ?? false

        if let ff = args["font_family"]?.stringValue,
           let fontFamily = HTMLConfiguration.FontFamily(rawValue: ff) {
            configs.html = HTMLConfiguration(
                fontSizePoints: args["font_size"]?.doubleValue ?? configs.html.fontSizePoints,
                fontFamily: fontFamily,
                marginSize: configs.html.marginSize,
                marginUnit: configs.html.marginUnit,
                embedImagesInline: configs.html.embedImagesInline,
                linkEmbeddedImages: configs.html.linkEmbeddedImages
            )
        } else if let size = args["font_size"]?.doubleValue {
            configs.html = HTMLConfiguration(
                fontSizePoints: size,
                fontFamily: configs.html.fontFamily,
                marginSize: configs.html.marginSize,
                marginUnit: configs.html.marginUnit,
                embedImagesInline: configs.html.embedImagesInline,
                linkEmbeddedImages: configs.html.linkEmbeddedImages
            )
        }

        // Reset sync manifest if requested
        if args["reset_sync"]?.boolValue == true {
            let manifestURL = outputURL.appendingPathComponent(SyncManifest.filename)
            try? FileManager.default.removeItem(at: manifestURL)
        }

        let engine = CLIExportEngine(configurations: configs)

        // Fetch and filter
        let (accounts, folders, allNotes): ([NotesAccount], [NotesFolder], [NotesNote])
        do {
            async let a = engine.fetchAccounts()
            async let f = engine.fetchFolders()
            async let n = engine.fetchNotes()
            (accounts, folders, allNotes) = try await (a, f, n)
        } catch {
            return errorText("Cannot read the Notes database. Grant Full Disk Access to the process running this MCP server in System Settings → Privacy & Security → Full Disk Access.")
        }

        var filtered = allNotes

        if let noteIdsStr = args["notes"]?.stringValue {
            let ids = Set(noteIdsStr.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) })
            filtered = filtered.filter { ids.contains($0.id) }
        }
        if let accountFilter = args["account"]?.stringValue?.lowercased() {
            let ids = accounts.filter { $0.name.lowercased().contains(accountFilter) }.map { $0.id }
            filtered = filtered.filter { ids.contains($0.accountId) }
        }
        if let folderFilter = args["folder"]?.stringValue?.lowercased() {
            let ids = folders.filter { $0.name.lowercased().contains(folderFilter) }.map { $0.id }
            filtered = filtered.filter { ids.contains($0.folderId) }
        }
        if let tc = args["title_contains"]?.stringValue?.lowercased() {
            filtered = filtered.filter { $0.title.lowercased().contains(tc) }
        }
        if let dateStr = args["modified_after"]?.stringValue, let date = parseDate(dateStr) {
            filtered = filtered.filter { $0.modificationDate > date }
        }
        if let dateStr = args["modified_before"]?.stringValue, let date = parseDate(dateStr) {
            filtered = filtered.filter { $0.modificationDate < date }
        }

        if filtered.isEmpty {
            struct EmptyResult: Encodable {
                let success: Bool
                let exported: Int
                let skipped: Int
                let failed: Int
                let failedAttachments: Int
                let outputDirectory: String
                let format: String
                let durationSeconds: Double
                let message: String
            }
            return jsonText(EmptyResult(
                success: true, exported: 0, skipped: 0, failed: 0, failedAttachments: 0,
                outputDirectory: outputURL.path, format: exportFormat.fileExtension,
                durationSeconds: 0.0, message: "No notes matched the specified criteria."
            ))
        }

        do {
            let result = try await engine.exportNotes(
                filtered,
                toDirectory: outputURL,
                format: exportFormat,
                includeAttachments: configs.includeAttachments,
                verbose: false,
                progressHandler: { _, _ in }
            )
            return jsonText(result)
        } catch let error as CLIError {
            return errorText(error.message)
        } catch {
            return errorText(error.localizedDescription)
        }
    }

    // MARK: - sync_status

    private static func handleSyncStatus(args: [String: Value]) throws -> CallTool.Result {
        guard let outputStr = args["output"]?.stringValue else {
            return errorText("Missing required argument 'output'.")
        }

        let outputURL = URL(fileURLWithPath: (outputStr as NSString).expandingTildeInPath).standardizedFileURL
        let manifestURL = outputURL.appendingPathComponent(SyncManifest.filename)

        guard let manifest = SyncManifest.load(from: outputURL) else {
            struct Response: Encodable {
                let manifestFound: Bool
                let outputDirectory: String
                let manifestPath: String
            }
            return jsonText(Response(manifestFound: false,
                                     outputDirectory: outputURL.path,
                                     manifestPath: manifestURL.path))
        }

        struct Response: Encodable {
            let manifestFound: Bool
            let lastSync: Date
            let trackedNotes: Int
            let manifestPath: String
        }
        return jsonText(Response(manifestFound: true,
                                 lastSync: manifest.lastSync,
                                 trackedNotes: manifest.notes.count,
                                 manifestPath: manifestURL.path))
    }

    // MARK: - Helpers

    private static func jsonText<T: Encodable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}" .utf8)
        return CallTool.Result(
            content: [.text(String(data: data, encoding: .utf8) ?? "{}")],
            isError: false
        )
    }

    private static func errorText(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(message)], isError: true)
    }

    private static func parseDate(_ string: String) -> Date? {
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFull.date(from: string) { return date }

        let isoBasic = ISO8601DateFormatter()
        if let date = isoBasic.date(from: string) { return date }

        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = TimeZone(identifier: "UTC")
        return dateOnly.date(from: string)
    }
}
