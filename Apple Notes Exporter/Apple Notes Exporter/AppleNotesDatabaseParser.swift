//
//  AppleNotesDatabaseParser.swift
//  Apple Notes Exporter
//
//  Database parser for Apple Notes that directly accesses the SQLite database
//

import Foundation
import SQLite3
import Compression
import Darwin
import zlib
import OSLog

// MARK: - Data Extension for Gzip

extension Data {
    /// Decompress gzip-compressed data by stripping the gzip header and using DEFLATE
    func gunzipped() -> Data? {
        guard self.count > 2 && self[0] == 0x1f && self[1] == 0x8b else {
            return nil  // Not gzip
        }

        // Parse gzip header to find where the compressed data starts
        // Gzip format: 2 bytes magic + 1 byte compression method + 1 byte flags + 6 bytes (time, xfl, os)
        // = 10 bytes minimum header
        guard self.count >= 10 else { return nil }

        var headerSize = 10
        let flags = self[3]

        // FEXTRA flag (bit 2)
        if (flags & 0x04) != 0 {
            guard self.count >= headerSize + 2 else { return nil }
            let xlen = Int(self[headerSize]) + (Int(self[headerSize + 1]) << 8)
            headerSize += 2 + xlen
        }

        // FNAME flag (bit 3) - original filename, null-terminated
        if (flags & 0x08) != 0 {
            while headerSize < self.count && self[headerSize] != 0 {
                headerSize += 1
            }
            headerSize += 1  // Skip null terminator
        }

        // FCOMMENT flag (bit 4) - comment, null-terminated
        if (flags & 0x10) != 0 {
            while headerSize < self.count && self[headerSize] != 0 {
                headerSize += 1
            }
            headerSize += 1  // Skip null terminator
        }

        // FHCRC flag (bit 1) - header CRC
        if (flags & 0x02) != 0 {
            headerSize += 2
        }

        // The last 8 bytes are CRC32 and original size, remove them
        guard headerSize < self.count - 8 else { return nil }

        // Extract the deflate stream (between header and footer)
        let deflateData = self.subdata(in: headerSize..<(self.count - 8))

        // Now decompress using COMPRESSION_ZLIB on the raw deflate stream
        let sourceBuffer = [UInt8](deflateData)
        let destinationBufferSize = sourceBuffer.count * 10  // Assume 10x expansion

        var destinationBuffer = [UInt8](repeating: 0, count: destinationBufferSize)

        let decodedCount = destinationBuffer.withUnsafeMutableBytes { destPtr in
            sourceBuffer.withUnsafeBytes { srcPtr in
                compression_decode_buffer(
                    destPtr.baseAddress!,
                    destinationBufferSize,
                    srcPtr.baseAddress!,
                    sourceBuffer.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedCount > 0 else {
            return nil
        }

        return Data(destinationBuffer.prefix(decodedCount))
    }
}

// MARK: - Models

struct ParsedNote {
    let id: Int
    let title: String
    let plaintext: String
    let htmlBody: String
    let creationDate: Date
    let modificationDate: Date
    let folderId: Int
    let accountId: Int
    let attachments: [NoteAttachment]
}

struct NoteFolder {
    let id: Int
    let name: String
    let parentId: Int?
    let accountId: Int
}

struct NoteAccount {
    let id: Int
    let name: String
    let identifier: String
}

struct NoteAttachment {
    let id: String
    let typeUTI: String
    let filepath: String?
}

// MARK: - iOS Version Detection

enum NotesVersion: Int {
    case legacy = 0
    case ios9 = 9
    case ios10 = 10
    case ios11 = 11
    case ios12 = 12
    case ios13 = 13
    case ios14 = 14
    case ios15 = 15
    case ios16 = 16
    case ios17 = 17
    case ios18 = 18
    case unknown = -1
}

// MARK: - Database Parser

class AppleNotesDatabaseParser {
    private var db: OpaquePointer?
    private let dbPath: String
    private var version: NotesVersion = .unknown

    init(databasePath: String = "\(NSHomeDirectory())/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite") {
        self.dbPath = databasePath
    }

    // MARK: - Database Operations

    func open() -> Bool {
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            version = detectVersion()
            return true
        } else {
            return false
        }
    }

    func close() {
        sqlite3_close(db)
    }

    // MARK: - Version Detection

    private func detectVersion() -> NotesVersion {
        let columns = getTableColumns("ZICCLOUDSYNCINGOBJECT")

        // iOS 18: ZUNAPPLIEDENCRYPTEDRECORDDATA
        if columns.contains(where: { $0.hasPrefix("ZUNAPPLIEDENCRYPTEDRECORDDATA") }) {
            return .ios18
        }

        // iOS 17: ZGENERATION
        if columns.contains(where: { $0.hasPrefix("ZGENERATION") }) {
            return .ios17
        }

        // iOS 16: ZACCOUNT6-ZACCOUNT8
        if columns.contains(where: { $0.hasPrefix("ZACCOUNT6") }) {
            return .ios16
        }

        // iOS 15: ZACCOUNT5
        if columns.contains(where: { $0.hasPrefix("ZACCOUNT5") }) {
            return .ios15
        }

        // iOS 14: ZLASTOPENEDDATE
        if columns.contains(where: { $0.hasPrefix("ZLASTOPENEDDATE") }) {
            return .ios14
        }

        // iOS 13: ZACCOUNT4
        if columns.contains(where: { $0.hasPrefix("ZACCOUNT4") }) {
            return .ios13
        }

        // iOS 12: ZSERVERRECORDDATA
        if columns.contains(where: { $0.hasPrefix("ZSERVERRECORDDATA") }) {
            return .ios12
        }

        return .unknown
    }

    private func getTableColumns(_ tableName: String) -> [String] {
        var columns: [String] = []
        let query = "PRAGMA table_info(\(tableName));"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 1) {
                    let columnName = String(cString: cString)
                    columns.append(columnName)
                }
            }
            sqlite3_finalize(statement)
        }

        return columns
    }

    // MARK: - Account Queries

    func fetchAccounts() -> [NoteAccount] {
        var accounts: [NoteAccount] = []

        // Check if ZACCOUNTTYPE column exists
        let columns = getTableColumns("ZICCLOUDSYNCINGOBJECT")
        let hasAccountType = columns.contains("ZACCOUNTTYPE")

        var query = "SELECT Z_PK, ZNAME, ZIDENTIFIER"
        if hasAccountType {
            query += ", ZACCOUNTTYPE"
        }
        query += """

        FROM ZICCLOUDSYNCINGOBJECT
        WHERE Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICAccount')
        AND (ZMARKEDFORDELETION = 0 OR ZMARKEDFORDELETION IS NULL);
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(statement, 0))
                let name = sqlite3_column_text(statement, 1).flatMap { String(cString: $0) } ?? "Unknown"
                let identifier = sqlite3_column_text(statement, 2).flatMap { String(cString: $0) } ?? ""

                accounts.append(NoteAccount(id: id, name: name, identifier: identifier))
            }
            sqlite3_finalize(statement)
        }

        return accounts
    }

    // MARK: - Folder Queries

    func fetchFolders() -> [NoteFolder] {
        var folders: [NoteFolder] = []

        // Check which account columns exist (varies by iOS version)
        // ZOWNER is the preferred column for folders (contains FK to account Z_PK)
        let columns = getTableColumns("ZICCLOUDSYNCINGOBJECT")
        let accountColumn = if columns.contains("ZOWNER") {
            "ZOWNER"
        } else if columns.contains("ZACCOUNT") {
            "ZACCOUNT"
        } else if columns.contains("ZACCOUNT2") {
            "ZACCOUNT2"
        } else {
            "Z_PK"  // Fallback - just use primary key
        }

        // Determine title column (ZTITLE2 for modern versions)
        let titleColumn = if columns.contains("ZTITLE2") {
            "ZTITLE2"
        } else if columns.contains("ZTITLE1") {
            "ZTITLE1"
        } else {
            "ZTITLE"  // Fallback
        }

        let query = """
        SELECT Z_PK, \(titleColumn) as TITLE, ZPARENT, \(accountColumn) as ACCOUNT_ID
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICFolder')
        AND (ZMARKEDFORDELETION = 0 OR ZMARKEDFORDELETION IS NULL)
        AND \(titleColumn) IS NOT NULL;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(statement, 0))
                let name = sqlite3_column_text(statement, 1).flatMap { String(cString: $0) } ?? "Untitled"
                let parentId = sqlite3_column_type(statement, 2) != SQLITE_NULL ?
                    Int(sqlite3_column_int64(statement, 2)) : nil
                let accountId = Int(sqlite3_column_int64(statement, 3))

                folders.append(NoteFolder(id: id, name: name, parentId: parentId, accountId: accountId))
            }
            sqlite3_finalize(statement)
        }

        return folders
    }

    // MARK: - Note Queries

    func fetchNotes() -> [ParsedNote] {
        var notes: [ParsedNote] = []

        // Check which columns exist (varies by iOS version)
        let columns = getTableColumns("ZICCLOUDSYNCINGOBJECT")
        let hasPasswordColumn = columns.contains("ZPASSWORDPROTECTED")

        let folderColumn = columns.contains("ZFOLDER") ? "ZFOLDER" : "ZFOLDER2"

        // Determine account column based on iOS version
        // iOS 18: ZACCOUNT7, iOS 16-17: ZACCOUNT7, iOS 15: ZACCOUNT4, iOS 13-14: ZACCOUNT3, iOS 12: ZACCOUNT2
        let accountColumn = if columns.contains("ZACCOUNT7") {
            "ZACCOUNT7"
        } else if columns.contains("ZACCOUNT4") {
            "ZACCOUNT4"
        } else if columns.contains("ZACCOUNT3") {
            "ZACCOUNT3"
        } else if columns.contains("ZACCOUNT2") {
            "ZACCOUNT2"
        } else if columns.contains("ZACCOUNT") {
            "ZACCOUNT"
        } else {
            "Z_PK"  // Fallback
        }

        // Determine title column (ZTITLE1, ZTITLE2, etc.)
        let titleColumn = if columns.contains("ZTITLE1") {
            "ZTITLE1"
        } else if columns.contains("ZTITLE2") {
            "ZTITLE2"
        } else {
            "ZTITLE"  // Fallback
        }

        // Determine creation date column (iOS 15+ uses ZCREATIONDATE3 for notes)
        let creationDateColumn = if columns.contains("ZCREATIONDATE3") {
            "ZCREATIONDATE3"
        } else if columns.contains("ZCREATIONDATE1") {
            "ZCREATIONDATE1"
        } else {
            "ZCREATIONDATE"  // Fallback
        }

        // Determine modification date column
        let modificationDateColumn = if columns.contains("ZMODIFICATIONDATE1") {
            "ZMODIFICATIONDATE1"
        } else {
            "ZMODIFICATIONDATE"  // Fallback
        }

        // Build query based on available columns
        var query = """
        SELECT
            note.Z_PK,
            note.\(titleColumn) as TITLE,
            note.\(creationDateColumn) as CREATION_DATE,
            note.\(modificationDateColumn) as MODIFICATION_DATE,
            note.\(folderColumn) as FOLDER_ID,
            note.\(accountColumn) as ACCOUNT_ID,
            data.ZDATA
        FROM ZICCLOUDSYNCINGOBJECT note
        LEFT JOIN ZICNOTEDATA data ON note.ZNOTEDATA = data.Z_PK
        WHERE note.Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICNote')
        AND (note.ZMARKEDFORDELETION = 0 OR note.ZMARKEDFORDELETION IS NULL)
        """

        // Add password filter only if column exists
        if hasPasswordColumn {
            query += "\nAND note.ZPASSWORDPROTECTED = 0"
        }

        query += ";"

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(statement, 0))
                let title = sqlite3_column_text(statement, 1).flatMap { String(cString: $0) } ?? "Untitled"

                // Handle NULL dates (represented as 0 or very small values)
                let creationInterval = sqlite3_column_double(statement, 2)
                let modificationInterval = sqlite3_column_double(statement, 3)

                // CoreData reference date is 2001-01-01, values before that are invalid
                let creationDate = creationInterval > 0 ? Date(timeIntervalSinceReferenceDate: creationInterval) : Date()
                let modificationDate = modificationInterval > 0 ? Date(timeIntervalSinceReferenceDate: modificationInterval) : Date()

                let folderId = Int(sqlite3_column_int64(statement, 4))
                let accountId = Int(sqlite3_column_int64(statement, 5))

                // Extract and decompress ZDATA
                var plaintext = ""
                let htmlBody = ""  // HTML is generated on-demand during export
                var attachments: [NoteAttachment] = []

                if sqlite3_column_type(statement, 6) == SQLITE_BLOB {
                    let dataSize = sqlite3_column_bytes(statement, 6)
                    if let dataPointer = sqlite3_column_blob(statement, 6) {
                        let data = Data(bytes: dataPointer, count: Int(dataSize))

                        // Decompress and parse
                        if let decompressed = decompressGzip(data) {
                            do {
                                let proto = try NoteStoreProto(serializedBytes: decompressed)
                                if proto.hasDocument {
                                    let document = proto.document
                                    if document.hasNote {
                                        let noteProto = document.note
                                        plaintext = noteProto.noteText

                                        // HTML is generated on-demand during export to improve load performance
                                        // htmlBody = generateHTML(from: noteProto)

                                        // Extract attachments
                                        attachments = extractAttachments(from: noteProto)
                                    }
                                }
                            } catch {
                                // Silently skip notes that fail to parse
                            }
                        }
                    }
                }

                notes.append(ParsedNote(
                    id: id,
                    title: title,
                    plaintext: plaintext,
                    htmlBody: htmlBody,
                    creationDate: creationDate,
                    modificationDate: modificationDate,
                    folderId: folderId,
                    accountId: accountId,
                    attachments: attachments
                ))
            }
            sqlite3_finalize(statement)
        }

        return notes
    }

    // MARK: - Decompression

    private func decompressGzip(_ data: Data) -> Data? {
        // Use the Data extension that properly handles gzip
        return data.gunzipped()
    }

    // MARK: - HTML Generation

    /// Check if two attribute runs have the same style (based on Ruby's same_style? method)
    private func isSameStyle(_ run1: AttributeRun, _ run2: AttributeRun) -> Bool {
        // Don't combine if either has attachment info
        if run1.hasAttachmentInfo || run2.hasAttachmentInfo {
            return false
        }

        // Compare all style attributes
        let sameParagraph = (run1.hasParagraphStyle == run2.hasParagraphStyle) &&
                           (!run1.hasParagraphStyle || (
                               run1.paragraphStyle.styleType == run2.paragraphStyle.styleType &&
                               run1.paragraphStyle.alignment == run2.paragraphStyle.alignment &&
                               run1.paragraphStyle.indentAmount == run2.paragraphStyle.indentAmount &&
                               run1.paragraphStyle.blockQuote == run2.paragraphStyle.blockQuote
                           ))

        let sameFont = (run1.hasFont == run2.hasFont) &&
                      (!run1.hasFont || (
                          run1.font.fontName == run2.font.fontName &&
                          run1.font.pointSize == run2.font.pointSize
                      ))

        let sameFontWeight = run1.fontWeight == run2.fontWeight
        let sameUnderlined = run1.underlined == run2.underlined
        let sameStrikethrough = run1.strikethrough == run2.strikethrough
        let sameSuperscript = run1.superscript == run2.superscript
        let sameLink = run1.link == run2.link
        let sameEmphasis = run1.emphasisStyle == run2.emphasisStyle

        return sameParagraph && sameFont && sameFontWeight && sameUnderlined &&
               sameStrikethrough && sameSuperscript && sameLink && sameEmphasis
    }

    // MARK: - Public HTML Generation for Export

    /// Generate HTML for a specific note by its ID (called on-demand during export)
    func generateHTMLForNote(noteId: Int) -> String? {
        // Query for note data
        let query = """
        SELECT data.ZDATA
        FROM ZICCLOUDSYNCINGOBJECT note
        LEFT JOIN ZICNOTEDATA data ON note.ZNOTEDATA = data.Z_PK
        WHERE note.Z_PK = ?
        AND (note.ZMARKEDFORDELETION = 0 OR note.ZMARKEDFORDELETION IS NULL);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            Logger.noteQuery.error("Failed to prepare HTML generation query for note \(noteId)")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(noteId))

        guard sqlite3_step(statement) == SQLITE_ROW else {
            Logger.noteQuery.debug("No data found for note \(noteId)")
            return nil
        }

        // Extract and decompress ZDATA
        if sqlite3_column_type(statement, 0) == SQLITE_BLOB {
            let dataSize = sqlite3_column_bytes(statement, 0)
            if let dataPointer = sqlite3_column_blob(statement, 0) {
                let data = Data(bytes: dataPointer, count: Int(dataSize))

                // Decompress and parse
                if let decompressed = decompressGzip(data) {
                    do {
                        let proto = try NoteStoreProto(serializedBytes: decompressed)
                        if proto.hasDocument {
                            let document = proto.document
                            if document.hasNote {
                                let noteProto = document.note
                                return generateHTML(from: noteProto)
                            }
                        }
                    } catch {
                        Logger.noteQuery.error("Failed to parse protobuf for note \(noteId): \(error)")
                        return nil
                    }
                }
            }
        }

        return nil
    }

    /// Generates HTML from a protobuf Note (from notestore.pb.swift)
    private func generateHTML(from note: Note) -> String {
        var html = "<html><body>"

        let text = note.noteText
        var currentPos = 0 // Position in UTF-16 code units

        // Condense consecutive attribute runs with the same style (like Ruby does in lines 618-639)
        var condensedRuns: [AttributeRun] = []
        var i = 0
        while i < note.attributeRun.count {
            let currentRun = note.attributeRun[i]
            var combinedLength = currentRun.length

            // Greedily combine runs with the same style
            while i + 1 < note.attributeRun.count && isSameStyle(currentRun, note.attributeRun[i + 1]) {
                i += 1
                combinedLength += note.attributeRun[i].length
            }

            // Create a new run with combined length if we merged anything
            if combinedLength != currentRun.length {
                var mergedRun = currentRun
                mergedRun.clearLength()
                mergedRun.length = combinedLength
                condensedRuns.append(mergedRun)
            } else {
                condensedRuns.append(currentRun)
            }

            i += 1
        }

        // Track list state with nesting support
        var listStack: [(type: Int32, indentLevel: Int32)] = []  // Stack of (list type, indent level)
        var currentListItemHTML = ""  // Accumulate HTML for current list item
        var inListItem = false  // Track if we're currently building a list item

        for (_, run) in condensedRuns.enumerated() {
            let length = Int(run.length) // Length in UTF-16 code units
            let utf16View = text.utf16
            let endPos = min(currentPos + length, utf16View.count)

            // Use UTF-16 indices for proper slicing
            guard let startIndex = utf16View.index(utf16View.startIndex, offsetBy: currentPos, limitedBy: utf16View.endIndex),
                  let endIndex = utf16View.index(utf16View.startIndex, offsetBy: endPos, limitedBy: utf16View.endIndex) else {
                // Skip this run if indices are invalid
                currentPos = endPos
                continue
            }

            let utf16Slice = utf16View[startIndex..<endIndex]
            var segment = String(utf16Slice) ?? ""

            // Determine if this is a list item and get indent level
            var isListItem = false
            var listStyleType = ""
            var listTagName = ""
            var checkboxPrefix = ""
            var indentLevel: Int32 = 0
            var listType: Int32 = 0

            if run.hasParagraphStyle {
                let style = run.paragraphStyle
                indentLevel = style.indentAmount

                switch style.styleType {
                case 100: // Dotted list
                    isListItem = true
                    listStyleType = "disc"
                    listTagName = "ul"
                    listType = 100
                case 101: // Dashed list
                    isListItem = true
                    listStyleType = "square"
                    listTagName = "ul"
                    listType = 101
                case 102: // Numbered list
                    isListItem = true
                    listStyleType = "decimal"
                    listTagName = "ol"
                    listType = 102
                case 103: // Checkbox
                    isListItem = true
                    listStyleType = "none"
                    listTagName = "ul"
                    listType = 103
                    let checked = style.hasChecklist && style.checklist.done != 0
                    checkboxPrefix = checked ? "☑ " : "☐ "
                default:
                    break
                }
            }

            // Handle list nesting based on indent levels
            if isListItem {
                // Close lists that are deeper than current indent
                while !listStack.isEmpty && listStack.last!.indentLevel >= indentLevel &&
                      (listStack.last!.indentLevel > indentLevel || listStack.last!.type != listType) {
                    let closed = listStack.removeLast()
                    html += (closed.type == 102) ? "</ol>" : "</ul>"
                }

                // Open new lists for deeper indents
                while listStack.isEmpty || listStack.last!.indentLevel < indentLevel {
                    let newIndent = listStack.isEmpty ? 0 : listStack.last!.indentLevel + 1
                    if newIndent > indentLevel {
                        break
                    }

                    // Open list at this level
                    if listTagName == "ol" {
                        html += "<ol>"
                    } else {
                        if listStyleType == "square" {
                            html += "<ul style='list-style-type: square;'>"
                        } else if listStyleType == "none" {
                            html += "<ul style='list-style-type: none;'>"
                        } else {
                            html += "<ul>"
                        }
                    }
                    listStack.append((type: listType, indentLevel: newIndent))
                }
            } else {
                // Close all open lists when we exit list context
                while !listStack.isEmpty {
                    let closed = listStack.removeLast()
                    html += (closed.type == 102) ? "</ol>" : "</ul>"
                }
            }

            // Handle list items - accumulate content until newline
            if isListItem {
                // Process text with styling
                var styledText = segment
                var openTags: [String] = []
                var closeTags: [String] = []

                // Font weight
                if run.fontWeight == 1 || run.fontWeight == 3 {
                    openTags.append("<b>")
                    closeTags.insert("</b>", at: 0)
                }
                if run.fontWeight == 2 || run.fontWeight == 3 {
                    openTags.append("<i>")
                    closeTags.insert("</i>", at: 0)
                }

                // Underline
                if run.underlined != 0 {
                    openTags.append("<u>")
                    closeTags.insert("</u>", at: 0)
                }

                // Strikethrough
                if run.strikethrough != 0 {
                    openTags.append("<s>")
                    closeTags.insert("</s>", at: 0)
                }

                // Links
                if !run.link.isEmpty {
                    openTags.append("<a href='\(run.link)'>")
                    closeTags.insert("</a>", at: 0)
                }

                // Handle attachments
                if run.hasAttachmentInfo {
                    let typeUti = run.attachmentInfo.typeUti
                    let attachmentId = run.attachmentInfo.attachmentIdentifier

                    // For tables, create a marker that will be rendered during export
                    if typeUti == "com.apple.notes.table" {
                        styledText = "<span data-attachment-id=\"\(attachmentId)\" data-attachment-type=\"\(typeUti)\">&#xFFFC;</span>"
                    }
                    // For images, create a marker that will be processed during export
                    else if typeUti.hasPrefix("public.image") || typeUti.hasPrefix("public.jpeg") || typeUti.hasPrefix("public.png") || typeUti.hasPrefix("public.heic") {
                        styledText = "<span data-attachment-id=\"\(attachmentId)\" data-attachment-type=\"\(typeUti)\">&#xFFFC;</span>"
                    }
                    // For inline attachments (hashtags, mentions, links, etc.)
                    else if typeUti.hasPrefix("com.apple.notes.inlinetextattachment") {
                        if let inlineText = getInlineAttachmentText(uuid: attachmentId, typeUti: typeUti) {
                            styledText = inlineText
                        } else {
                            styledText = ""
                        }
                    }
                    // For other file attachments
                    else {
                        styledText = "<span data-attachment-id=\"\(attachmentId)\" data-attachment-type=\"\(typeUti)\">[File: \(typeUti)]</span>"
                    }
                }

                // Split by newlines to handle multiple list items in this run
                let parts = styledText.components(separatedBy: "\n")
                for (partIndex, part) in parts.enumerated() {
                    let isLastPart = (partIndex == parts.count - 1)

                    // Skip empty trailing part (just a newline at the end)
                    if isLastPart && part.isEmpty {
                        continue
                    }

                    // Start new list item if needed
                    if !inListItem {
                        inListItem = true
                        currentListItemHTML = checkboxPrefix
                    }

                    // Add styled content to current list item
                    if !part.isEmpty {
                        currentListItemHTML += openTags.joined() + part + closeTags.joined()
                    }

                    // Close list item on newline (not on the last part)
                    if !isLastPart {
                        html += "<li>" + currentListItemHTML + "</li>"
                        currentListItemHTML = ""
                        inListItem = false
                    }
                }
            } else {
                // Close any pending list item when we exit list context (only if it has content beyond checkbox)
                if inListItem {
                    // Only output if there's actual content (not just checkbox prefix)
                    let hasContent = currentListItemHTML.trimmingCharacters(in: .whitespacesAndNewlines).count > 2 // More than just "☐ " or "☑ "
                    if hasContent {
                        html += "<li>" + currentListItemHTML + "</li>"
                    }
                    currentListItemHTML = ""
                    inListItem = false
                }
                // Non-list items: apply paragraph styling and convert newlines to <br>
                var openTags: [String] = []
                var closeTags: [String] = []

                if run.hasParagraphStyle {
                    let style = run.paragraphStyle

                    switch style.styleType {
                    case 0: // Title
                        openTags.append("<h1>")
                        closeTags.insert("</h1>", at: 0)
                    case 1: // Heading
                        openTags.append("<h2>")
                        closeTags.insert("</h2>", at: 0)
                    case 2: // Subheading
                        openTags.append("<h3>")
                        closeTags.insert("</h3>", at: 0)
                    case 4: // Monospaced
                        openTags.append("<pre style='white-space: pre-wrap; font-family: monospace; background: #f5f5f5; padding: 8px; border-radius: 4px; margin: 4px 0;'>")
                        closeTags.insert("</pre>", at: 0)
                    default:
                        break
                    }
                }

                // Font weight
                if run.fontWeight == 1 || run.fontWeight == 3 {
                    openTags.append("<b>")
                    closeTags.insert("</b>", at: 0)
                }
                if run.fontWeight == 2 || run.fontWeight == 3 {
                    openTags.append("<i>")
                    closeTags.insert("</i>", at: 0)
                }

                // Underline
                if run.underlined != 0 {
                    openTags.append("<u>")
                    closeTags.insert("</u>", at: 0)
                }

                // Strikethrough
                if run.strikethrough != 0 {
                    openTags.append("<s>")
                    closeTags.insert("</s>", at: 0)
                }

                // Links
                if !run.link.isEmpty {
                    openTags.append("<a href='\(run.link)'>")
                    closeTags.insert("</a>", at: 0)
                }

                // Handle attachments
                if run.hasAttachmentInfo {
                    let typeUti = run.attachmentInfo.typeUti
                    let attachmentId = run.attachmentInfo.attachmentIdentifier

                    // For tables, create a marker that will be rendered during export
                    if typeUti == "com.apple.notes.table" {
                        segment = "<span data-attachment-id=\"\(attachmentId)\" data-attachment-type=\"\(typeUti)\">&#xFFFC;</span>"
                    }
                    // For images, create a marker that will be processed during export
                    else if typeUti.hasPrefix("public.image") || typeUti.hasPrefix("public.jpeg") || typeUti.hasPrefix("public.png") || typeUti.hasPrefix("public.heic") {
                        segment = "<span data-attachment-id=\"\(attachmentId)\" data-attachment-type=\"\(typeUti)\">&#xFFFC;</span>"
                    }
                    // For inline attachments (hashtags, mentions, links, etc.)
                    else if typeUti.hasPrefix("com.apple.notes.inlinetextattachment") {
                        if let inlineText = getInlineAttachmentText(uuid: attachmentId, typeUti: typeUti) {
                            segment = inlineText
                        } else {
                            segment = "" // Fallback: skip if we can't get the text
                        }
                    }
                    // For other file attachments
                    else {
                        segment = "<span data-attachment-id=\"\(attachmentId)\" data-attachment-type=\"\(typeUti)\">[File: \(typeUti)]</span>"
                    }
                }

                html += openTags.joined() + segment.replacingOccurrences(of: "\n", with: "<br>") + closeTags.joined()
            }

            currentPos = endPos
        }

        // Close any pending list item (only if it has content beyond checkbox/whitespace)
        if inListItem {
            let hasContent = currentListItemHTML.trimmingCharacters(in: .whitespacesAndNewlines).count > 2
            if hasContent {
                html += "<li>" + currentListItemHTML + "</li>"
            }
        }

        // Close any open lists at the end
        while !listStack.isEmpty {
            let closed = listStack.removeLast()
            html += (closed.type == 102) ? "</ol>" : "</ul>"
        }

        html += "</body></html>"
        return html
    }

    /// Get text content for inline attachments (hashtags, mentions, links, etc.)
    private func getInlineAttachmentText(uuid: String, typeUti: String) -> String? {
        let query = """
        SELECT ZALTTEXT, ZTOKENCONTENTIDENTIFIER
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE ZIDENTIFIER = ?
        AND (ZMARKEDFORDELETION = 0 OR ZMARKEDFORDELETION IS NULL);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            Logger.noteQuery.error("Failed to prepare inline attachment query")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (uuid as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            Logger.noteQuery.debug("No inline attachment data found for UUID \(uuid)")
            return nil
        }

        // Get ZALTTEXT (the display text)
        if let altText = sqlite3_column_text(statement, 0) {
            let text = String(cString: altText)

            // For specific types, we may want to add additional info
            if typeUti == "com.apple.notes.inlinetextattachment.mention" {
                // For mentions, could add the token identifier in brackets if available
                if let tokenId = sqlite3_column_text(statement, 1) {
                    let token = String(cString: tokenId)
                    return "\(text) [\(token)]"
                }
            } else if typeUti == "com.apple.notes.inlinetextattachment.link" {
                // For links, could add the token identifier
                if let tokenId = sqlite3_column_text(statement, 1) {
                    let token = String(cString: tokenId)
                    return "\(text) [\(token)]"
                }
            }

            // For hashtags and other inline attachments, just return the text
            return text
        }

        return nil
    }

    /// Extracts attachment info from a protobuf Note
    private func extractAttachments(from note: Note) -> [NoteAttachment] {
        var attachments: [NoteAttachment] = []

        for run in note.attributeRun where run.hasAttachmentInfo {
            let info = run.attachmentInfo
            attachments.append(NoteAttachment(
                id: info.attachmentIdentifier,
                typeUTI: info.typeUti,
                filepath: nil // Will be resolved separately
            ))
        }

        return attachments
    }

    // MARK: - Attachment Data Fetching

    /// Fetch binary data for an attachment by its ID
    func fetchAttachmentData(attachmentId: String) -> Data? {
        // First, try to find the attachment using ZIDENTIFIER
        let attachmentQuery = """
        SELECT att.ZMEDIA, att.Z_PK, att.ZIDENTIFIER, att.ZTYPEUTI, att.ZFILENAME,
               note.ZACCOUNT as ZACCOUNT
        FROM ZICCLOUDSYNCINGOBJECT att
        LEFT JOIN ZICCLOUDSYNCINGOBJECT note ON att.ZNOTE = note.Z_PK
        WHERE att.Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICAttachment')
        AND att.ZIDENTIFIER = ?
        AND (att.ZMARKEDFORDELETION = 0 OR att.ZMARKEDFORDELETION IS NULL);
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, attachmentQuery, -1, &statement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(statement) }

            // Bind the attachment ID parameter
            sqlite3_bind_text(statement, 1, (attachmentId as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) == SQLITE_ROW {
                // Get additional info for debugging
                let typeUTI = sqlite3_column_text(statement, 3).flatMap { String(cString: $0) }
                let attachmentFilename = sqlite3_column_text(statement, 4).flatMap { String(cString: $0) }
                let accountPK = String(sqlite3_column_int64(statement, 5))

                // Check if ZMEDIA is NULL
                if sqlite3_column_type(statement, 0) == SQLITE_NULL {
                    Logger.noteQuery.debug("Attachment \(attachmentId) ZMEDIA=NULL, type=\(typeUTI ?? "nil"), filename=\(attachmentFilename ?? "nil")")

                    // Handle special attachment types that use fallback files
                    if let type = typeUTI {
                        if type == "com.apple.paper" {
                            // Drawing/sketch - look for fallback image
                            return fetchFallbackImage(attachmentId: attachmentId, accountId: accountPK)
                        } else if type == "com.apple.paper.doc.pdf" {
                            // Scanned document - look for fallback PDF
                            return fetchFallbackPDF(attachmentId: attachmentId, accountId: accountPK)
                        }
                    }

                    // If the attachment has a ZFILENAME directly, try to use that
                    if let filename = attachmentFilename {
                        Logger.noteQuery.debug("Trying to find attachment using ZFILENAME: \(filename)")
                        return findExternalAttachment(filename: filename)
                    }

                    return nil
                }

                // Get the ZMEDIA foreign key
                let mediaId = sqlite3_column_int64(statement, 0)
                Logger.noteQuery.debug("Found attachment \(attachmentId) with ZMEDIA=\(mediaId)")

                // Now fetch the actual media data
                return fetchMediaData(mediaId: Int(mediaId))
            } else {
                Logger.noteQuery.debug("No attachment found with ZIDENTIFIER=\(attachmentId)")
            }
        } else {
            Logger.noteQuery.error("Failed to prepare attachment query")
        }

        return nil
    }

    /// Fetch media blob data from the media object row in ZICCLOUDSYNCINGOBJECT
    /// The ZMEDIA column contains a Z_PK pointing to another row in ZICCLOUDSYNCINGOBJECT
    private func fetchMediaData(mediaId: Int) -> Data? {
        let mediaQuery = """
        SELECT ZFILENAME
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE Z_PK = ?;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, mediaQuery, -1, &statement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(statement) }

            // Bind the media ID parameter
            sqlite3_bind_int64(statement, 1, Int64(mediaId))

            if sqlite3_step(statement) == SQLITE_ROW {
                // Get the filename from ZFILENAME column
                let filename = sqlite3_column_text(statement, 0).flatMap { String(cString: $0) }

                Logger.noteQuery.debug("Media object \(mediaId): filename=\(filename ?? "nil")")

                // Try to find the file on disk using the filename
                if let filename = filename {
                    return findExternalAttachment(filename: filename)
                } else {
                    Logger.noteQuery.debug("No ZFILENAME found for media object \(mediaId)")
                }
            } else {
                Logger.noteQuery.debug("No media object row found with Z_PK=\(mediaId)")
            }
        } else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            Logger.noteQuery.error("Failed to prepare ZMEDIA query: \(errorMsg)")
        }

        return nil
    }

    /// Find an external attachment file on disk
    /// Modern macOS Notes stores attachments externally in the filesystem
    private func findExternalAttachment(filename: String) -> Data? {
        // The base path for Notes data
        let groupContainer = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes"

        // Possible locations for attachments
        let searchPaths = [
            // Media directory (modern storage)
            groupContainer + "/Media",
            // Accounts subdirectories
            groupContainer + "/Accounts",
            // Fallbacks directory
            groupContainer + "/Fallbacks"
        ]

        Logger.noteQuery.debug("Searching for external attachment: \(filename)")

        // Search in each location
        for basePath in searchPaths {
            if let data = searchDirectory(basePath, forFile: filename) {
                Logger.noteQuery.debug("Found external attachment at path under \(basePath)")
                return data
            }
        }

        Logger.noteQuery.debug("External attachment not found in any search location")
        return nil
    }

    /// Recursively search a directory for a file
    private func searchDirectory(_ directory: String, forFile filename: String) -> Data? {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(atPath: directory) else {
            return nil
        }

        while let file = enumerator.nextObject() as? String {
            // Check if this file matches our filename
            if file.hasSuffix(filename) || file.contains(filename) {
                let fullPath = directory + "/" + file
                if let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)) {
                    Logger.noteQuery.debug("Successfully loaded file from: \(fullPath)")
                    return data
                }
            }
        }

        return nil
    }

    // MARK: - Table and URL Parsing

    /// Parse a table attachment and return HTML representation
    func parseTableHTML(attachmentId: String) -> String? {
        guard let database = db else { return nil }
        let parser = TableParser(database: database)
        guard let table = parser.parseTable(uuid: attachmentId) else {
            return nil
        }
        return table.toHTML()
    }

    /// Parse a table attachment and return Markdown representation
    func parseTableMarkdown(attachmentId: String) -> String? {
        guard let database = db else { return nil }
        let parser = TableParser(database: database)
        guard let table = parser.parseTable(uuid: attachmentId) else {
            return nil
        }
        return table.toMarkdown()
    }

    /// Parse a table attachment and return plain text representation
    func parseTablePlainText(attachmentId: String) -> String? {
        guard let database = db else { return nil }
        let parser = TableParser(database: database)
        guard let table = parser.parseTable(uuid: attachmentId) else {
            return nil
        }
        return table.toPlainText()
    }

    /// Fetch URL link card information
    func fetchURLLinkCard(attachmentId: String) -> (url: String, title: String?)? {
        // URL link cards are stored in ZMERGEABLEDATA1 as well
        let query = """
        SELECT ZMERGEABLEDATA1, ZTITLE, ZALTTEXT
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE ZIDENTIFIER = ?
        AND (ZMARKEDFORDELETION = 0 OR ZMARKEDFORDELETION IS NULL);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (attachmentId as NSString).utf8String, -1, nil)

        if sqlite3_step(statement) == SQLITE_ROW {
            // Try to get title from ZTITLE or ZALTTEXT columns
            let title = sqlite3_column_text(statement, 1).flatMap { String(cString: $0) }
                ?? sqlite3_column_text(statement, 2).flatMap { String(cString: $0) }

            // Try to extract URL from mergeable data
            if let blob = sqlite3_column_blob(statement, 0) {
                let size = sqlite3_column_bytes(statement, 0)
                let data = Data(bytes: blob, count: Int(size))

                // Try to parse as protobuf and extract URL
                if let url = extractURLFromMergeableData(data) {
                    return (url: url, title: title)
                }
            }
        }

        return nil
    }

    /// Extract URL from mergeable data protobuf
    private func extractURLFromMergeableData(_ data: Data) -> String? {
        // Decompress if gzipped
        if let decompressed = data.gunzipped() {
            return extractURLFromProtobuf(decompressed)
        }

        // Try parsing directly if not gzipped
        return extractURLFromProtobuf(data)
    }

    /// Extract URL string from protobuf data
    private func extractURLFromProtobuf(_ data: Data) -> String? {
        do {
            let proto = try MergableDataProto(serializedBytes: data)
            let objectData = proto.mergableDataObject.mergeableDataObjectData

            // Look for URL in the note text or string values
            for entry in objectData.mergeableDataObjectEntry {
                if entry.hasNote {
                    let text = entry.note.noteText
                    // Check if it looks like a URL
                    if text.hasPrefix("http://") || text.hasPrefix("https://") {
                        return text
                    }
                }
            }
        } catch {
            Logger.noteQuery.debug("Failed to parse URL protobuf: \(error.localizedDescription)")
        }

        return nil
    }

    // MARK: - Paper/Drawing Attachments

    /// Fetch fallback image for com.apple.paper (drawing/sketch) attachments
    func fetchFallbackImage(attachmentId: String, accountId: String) -> Data? {
        // First, get the ZFALLBACKIMAGEGENERATION
        let generationQuery = """
        SELECT ZFALLBACKIMAGEGENERATION
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE ZIDENTIFIER = ?
        AND (ZMARKEDFORDELETION = 0 OR ZMARKEDFORDELETION IS NULL);
        """

        var generation: String?
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, generationQuery, -1, &statement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, (attachmentId as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) == SQLITE_ROW {
                generation = sqlite3_column_text(statement, 0).flatMap { String(cString: $0) }
            }
        }

        // Try to find the fallback image file
        let groupContainer = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes"
        let fallbackImagesPath = groupContainer + "/Accounts/" + accountId + "/FallbackImages"

        // Try different file extensions and locations
        let extensions = ["jpeg", "png", "jpg"]
        let searchPaths: [String]

        if let gen = generation, !gen.isEmpty {
            // iOS 17+ with generation
            searchPaths = extensions.flatMap { ext in
                [
                    "\(fallbackImagesPath)/\(attachmentId)/\(gen)/FallbackImage.\(ext)"
                ]
            }
        } else {
            // Older format
            searchPaths = extensions.map { ext in
                "\(fallbackImagesPath)/\(attachmentId).\(ext)"
            }
        }

        for path in searchPaths {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                Logger.noteQuery.debug("Found fallback image at: \(path)")
                return data
            }
        }

        Logger.noteQuery.debug("Could not find fallback image for \(attachmentId)")
        return nil
    }

    /// Fetch filename for an attachment by its ID
    func fetchAttachmentFilename(attachmentId: String) -> String? {
        // First, find the attachment row to get the ZMEDIA reference
        let attachmentQuery = """
        SELECT att.ZMEDIA
        FROM ZICCLOUDSYNCINGOBJECT att
        WHERE att.Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICAttachment')
        AND att.ZIDENTIFIER = ?
        AND (att.ZMARKEDFORDELETION = 0 OR att.ZMARKEDFORDELETION IS NULL);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, attachmentQuery, -1, &statement, nil) == SQLITE_OK else {
            Logger.noteQuery.error("Failed to prepare attachment filename query")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (attachmentId as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            Logger.noteQuery.debug("No attachment found with ZIDENTIFIER=\(attachmentId)")
            return nil
        }

        // Check if ZMEDIA is NULL
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else {
            Logger.noteQuery.debug("Attachment \(attachmentId) has NULL ZMEDIA, cannot fetch filename")
            return nil
        }

        // Get the ZMEDIA foreign key
        let mediaId = sqlite3_column_int64(statement, 0)

        // Now fetch the ZFILENAME from the media object
        let mediaQuery = """
        SELECT ZFILENAME
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE Z_PK = ?;
        """

        var mediaStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, mediaQuery, -1, &mediaStatement, nil) == SQLITE_OK else {
            Logger.noteQuery.error("Failed to prepare media filename query")
            return nil
        }
        defer { sqlite3_finalize(mediaStatement) }

        sqlite3_bind_int64(mediaStatement, 1, mediaId)

        guard sqlite3_step(mediaStatement) == SQLITE_ROW else {
            Logger.noteQuery.debug("No media object row found with Z_PK=\(mediaId)")
            return nil
        }

        // Get the filename from ZFILENAME column
        if let filenamePtr = sqlite3_column_text(mediaStatement, 0) {
            let filename = String(cString: filenamePtr)
            Logger.noteQuery.debug("Found filename for attachment \(attachmentId): \(filename)")
            return filename
        }

        Logger.noteQuery.debug("No ZFILENAME found for media object \(mediaId)")
        return nil
    }

    /// Fetch fallback PDF for com.apple.paper.doc.pdf (scanned document) attachments
    func fetchFallbackPDF(attachmentId: String, accountId: String) -> Data? {
        // First, get the ZFALLBACKPDFGENERATION
        let generationQuery = """
        SELECT ZFALLBACKPDFGENERATION
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE ZIDENTIFIER = ?
        AND (ZMARKEDFORDELETION = 0 OR ZMARKEDFORDELETION IS NULL);
        """

        var generation: String?
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, generationQuery, -1, &statement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, (attachmentId as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) == SQLITE_ROW {
                generation = sqlite3_column_text(statement, 0).flatMap { String(cString: $0) }
            }
        }

        // Try to find the fallback PDF file
        let groupContainer = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes"
        let fallbackPDFsPath = groupContainer + "/Accounts/" + accountId + "/FallbackPDFs"

        let searchPaths: [String]

        if let gen = generation, !gen.isEmpty {
            // iOS 17+ with generation
            searchPaths = [
                "\(fallbackPDFsPath)/\(attachmentId)/\(gen)/FallbackPDF.pdf"
            ]
        } else {
            // Older format
            searchPaths = [
                "\(fallbackPDFsPath)/\(attachmentId).pdf"
            ]
        }

        for path in searchPaths {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                Logger.noteQuery.debug("Found fallback PDF at: \(path)")
                return data
            }
        }

        Logger.noteQuery.debug("Could not find fallback PDF for \(attachmentId)")
        return nil
    }
}
