//
//  AppleNotesDatabaseParser.swift
//  Apple Notes Exporter
//
//  Database-based parser for Apple Notes (replaces AppleScript approach)
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

                var accountTypeName = "Unknown"
                if hasAccountType {
                    let accountType = Int(sqlite3_column_int64(statement, 3))
                    accountTypeName = switch accountType {
                        case 0: "Local"
                        case 1: "Exchange"
                        case 2: "IMAP"
                        case 3: "iCloud"
                        case 4: "Google"
                        default: "Unknown(\(accountType))"
                    }
                }

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
                var htmlBody = ""
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

                                        // Generate HTML from protobuf
                                        htmlBody = generateHTML(from: noteProto)

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

    /// Generates HTML from a protobuf Note (from notestore.pb.swift)
    private func generateHTML(from note: Note) -> String {
        var html = "<html><body>"

        let text = note.noteText
        var currentPos = 0

        for run in note.attributeRun {
            let length = Int(run.length)
            let endPos = min(currentPos + length, text.count)

            let startIndex = text.index(text.startIndex, offsetBy: currentPos)
            let endIndex = text.index(text.startIndex, offsetBy: endPos)
            var segment = String(text[startIndex..<endIndex])

            // Determine if this is a list item
            var isListItem = false
            var listStyleType = ""
            var checkboxPrefix = ""

            if run.hasParagraphStyle {
                let style = run.paragraphStyle

                switch style.styleType {
                case 100: // Dotted list
                    isListItem = true
                    listStyleType = "disc"
                case 101: // Dashed list
                    isListItem = true
                    listStyleType = "square"
                case 102: // Numbered list
                    isListItem = true
                    listStyleType = "decimal"
                case 103: // Checkbox
                    isListItem = true
                    listStyleType = "none"
                    let checked = style.hasChecklist && style.checklist.done != 0
                    checkboxPrefix = checked ? "☑ " : "☐ "
                default:
                    break
                }
            }

            // Handle list items specially - newlines separate list items
            if isListItem {
                let listItems = segment.components(separatedBy: "\n")
                for (index, item) in listItems.enumerated() {
                    // Skip empty items except the last one (which is just the trailing newline)
                    if item.isEmpty && index < listItems.count - 1 {
                        continue
                    }

                    // Don't create a list item for the final trailing newline
                    if item.isEmpty && index == listItems.count - 1 {
                        continue
                    }

                    // Apply text styling
                    var styledText = item
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

                    // Attachment placeholder
                    if run.hasAttachmentInfo {
                        styledText = "[Attachment: \(run.attachmentInfo.typeUti)]"
                    }

                    html += "<li style='list-style-type: \(listStyleType);'>"
                    html += checkboxPrefix + openTags.joined() + styledText + closeTags.joined()
                    html += "</li>"
                }
            } else {
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
                        openTags.append("<code>")
                        closeTags.insert("</code>", at: 0)
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

                // Attachment placeholder
                if run.hasAttachmentInfo {
                    segment = "[Attachment: \(run.attachmentInfo.typeUti)]"
                }

                html += openTags.joined() + segment.replacingOccurrences(of: "\n", with: "<br>") + closeTags.joined()
            }

            currentPos = endPos
        }

        html += "</body></html>"
        return html
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
