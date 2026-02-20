//
//  HTMLAttachmentProcessor.swift
//  Apple Notes Exporter
//
//  Processes HTML to replace attachment placeholders with actual content
//

import Foundation
import SQLite3
import OSLog
import AppKit

/// Processes HTML to replace attachment placeholders with inline content or links
class HTMLAttachmentProcessor {
    private let db: OpaquePointer
    private let tableParser: TableParser
    private var exportDirectory: String?

    init(database: OpaquePointer) {
        self.db = database
        self.tableParser = TableParser(database: database)
    }

    /// Process HTML to replace attachment markers with actual content
    /// - Parameters:
    ///   - html: Raw HTML from the database
    ///   - attachments: List of attachments for this note
    ///   - attachmentPaths: Map of attachment IDs to relative file paths
    ///   - exportDirectory: Base directory where files are being exported (for resolving relative paths)
    ///   - embedImages: Whether to embed images inline as base64
    ///   - linkEmbeddedImages: Whether to wrap embedded images in <a> tags linking to files
    /// - Returns: Processed HTML with attachments replaced
    func processHTML(
        html: String,
        attachments: [NotesAttachment],
        attachmentPaths: [String: String],
        exportDirectory: String? = nil,
        embedImages: Bool,
        linkEmbeddedImages: Bool
    ) -> String {
        // Store export directory for later use
        self.exportDirectory = exportDirectory

        var processedHTML = html

        // Create attachment lookup by ID
        var attachmentMap: [String: NotesAttachment] = [:]
        for attachment in attachments {
            attachmentMap[attachment.id] = attachment
        }

        // Find and replace attachment markers
        // Pattern matches: [Attachment: <type>] or object-replacement-character followed by attachment
        // For now, we'll look for the object replacement character (U+FFFC) which Apple Notes uses

        // First, try to match object replacement characters which might be followed by attachment data
        // In Apple Notes HTML, attachments are often represented by <object> tags
        processedHTML = replaceObjectTags(
            in: processedHTML,
            attachmentMap: attachmentMap,
            attachmentPaths: attachmentPaths,
            embedImages: embedImages,
            linkEmbeddedImages: linkEmbeddedImages
        )

        return processedHTML
    }

    /// Replace <object> tags with actual attachment content
    private func replaceObjectTags(
        in html: String,
        attachmentMap: [String: NotesAttachment],
        attachmentPaths: [String: String],
        embedImages: Bool,
        linkEmbeddedImages: Bool
    ) -> String {
        var result = html

        // Pattern to match <span data-attachment-id="..." data-attachment-type="...">...</span>
        let spanPattern = #"<span\s+data-attachment-id="([^"]+)"\s+data-attachment-type="([^"]+)">.*?</span>"#

        guard let regex = try? NSRegularExpression(pattern: spanPattern, options: [.dotMatchesLineSeparators]) else {
            Logger.noteQuery.error("Failed to create span tag regex")
            return html
        }

        let nsString = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))

        // Process matches in reverse to maintain string indices
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }

            let fullRange = match.range(at: 0)
            let uuidRange = match.range(at: 1)
            let typeRange = match.range(at: 2)

            let uuid = nsString.substring(with: uuidRange)
            let typeUti = nsString.substring(with: typeRange)

            // Create a NotesAttachment if we don't have one in the map
            let attachment = attachmentMap[uuid] ?? NotesAttachment(
                id: uuid,
                typeUTI: typeUti,
                filename: nil
            )

            let replacement = generateReplacementHTML(
                for: attachment,
                uuid: uuid,
                relativePath: attachmentPaths[uuid],
                embedImages: embedImages,
                linkEmbeddedImages: linkEmbeddedImages
            )

            result = (result as NSString).replacingCharacters(in: fullRange, with: replacement)
        }

        return result
    }

    /// Generate replacement HTML for an attachment
    private func generateReplacementHTML(
        for attachment: NotesAttachment,
        uuid: String,
        relativePath: String?,
        embedImages: Bool,
        linkEmbeddedImages: Bool
    ) -> String {
        // Check if this is an image
        // Also treat drawings/sketches as images since they have fallback image data
        if attachment.typeUTI.hasPrefix("public.image") ||
           attachment.typeUTI.hasPrefix("public.jpeg") ||
           attachment.typeUTI.hasPrefix("public.png") ||
           attachment.typeUTI.hasPrefix("public.heic") ||
           attachment.typeUTI.hasPrefix("public.tiff") ||
           attachment.typeUTI.hasPrefix("com.compuserve.gif") ||
           attachment.typeUTI == "com.compuserve.gif" ||
           attachment.typeUTI == "com.apple.paper" ||
           attachment.typeUTI == "com.apple.drawing" ||
           attachment.typeUTI == "com.apple.drawing.2" ||
           attachment.typeUTI == "com.apple.notes.gallery" {
            return generateImageHTML(
                attachment: attachment,
                uuid: uuid,
                relativePath: relativePath,
                embedInline: embedImages,
                wrapInLink: linkEmbeddedImages
            )
        }

        // Check if this is a table
        if attachment.typeUTI == "com.apple.notes.table" {
            return generateTableHTML(uuid: uuid)
        }

        // Check if this is a URL link card
        if attachment.typeUTI == "public.url" {
            return generateURLCardHTML(uuid: uuid)
        }

        // Check if this is a PDF
        if attachment.typeUTI == "com.adobe.pdf" || attachment.typeUTI == "public.pdf" {
            return generatePDFLinkHTML(attachment: attachment, relativePath: relativePath)
        }

        // For other attachments, generate a styled link
        if let path = relativePath {
            // Extract filename from the relative path if attachment.filename is not available
            let filename = attachment.filename ?? (path as NSString).lastPathComponent
            return generateGenericAttachmentHTML(filename: filename, path: path, typeUTI: attachment.typeUTI)
        }

        // Fallback: return placeholder
        return "[Attachment: \(attachment.typeUTI)]"
    }

    /// Generate HTML for image attachments
    private func generateImageHTML(
        attachment: NotesAttachment,
        uuid: String,
        relativePath: String?,
        embedInline: Bool,
        wrapInLink: Bool
    ) -> String {
        // Try to get base64-encoded image data first (works for both embedded and external images)
        if let base64 = getImageBase64(uuid: uuid, typeUTI: attachment.typeUTI, relativePath: relativePath) {
            let mimeType = utiToMimeType(attachment.typeUTI)
            let imgTag = "<img src=\"data:\(mimeType);base64,\(base64)\" alt=\"\(attachment.filename ?? "image")\" />"

            // If embedInline is false but we have a relativePath, use the path instead
            if !embedInline, let path = relativePath {
                return "<img src=\"\(path)\" alt=\"\(attachment.filename ?? "image")\" />"
            }

            // Optionally wrap embedded image in link to file
            if embedInline && wrapInLink, let path = relativePath {
                return "<a href=\"\(path)\">\(imgTag)</a>"
            }

            return imgTag
        }

        // Fall back to linking to the file if base64 failed
        if let path = relativePath {
            return "<img src=\"\(path)\" alt=\"\(attachment.filename ?? "image")\" />"
        }

        // Last resort: show placeholder
        Logger.noteQuery.warning("Could not embed or link to image \(uuid) - no base64 data or file path available")
        return "[Image: \(attachment.filename ?? uuid)]"
    }

    /// Generate HTML for table attachments by parsing protobuf
    private func generateTableHTML(uuid: String) -> String {
        Logger.noteQuery.info("Processing table attachment with UUID: \(uuid)")

        if let parsedTable = tableParser.parseTable(uuid: uuid) {
            Logger.noteQuery.info("Successfully rendered table \(uuid) with \(parsedTable.rowCount) rows and \(parsedTable.columnCount) columns")
            return parsedTable.toHTML()
        }

        Logger.noteQuery.warning("Failed to render table \(uuid) - TableParser.parseTable() returned nil")
        return "[Table could not be rendered]"
    }

    /// Generate HTML for URL link card attachments
    private func generateURLCardHTML(uuid: String) -> String {
        Logger.noteQuery.debug("Processing URL link card with UUID: \(uuid)")

        // Try to fetch URL and title from database
        if let (url, title) = fetchURLLinkCard(uuid: uuid) {
            Logger.noteQuery.debug("Successfully fetched URL link card: url=\(url), title=\(title ?? "nil")")
            let displayTitle = title ?? url
            return """
            <div style="border: 1px solid #ddd; border-radius: 8px; padding: 12px; margin: 8px 0; background: #f9f9f9; display: flex; align-items: center; font-size: 14px; font-weight: normal; font-style: normal; text-decoration: none;">
                <div style="font-size: 24px; margin-right: 12px; line-height: 1;">🔗</div>
                <div style="flex: 1; min-width: 0;">
                    <a href="\(url.htmlEscaped)" target="_blank" style="text-decoration: none; color: #007AFF; font-weight: 500; display: block; font-size: 14px; overflow-wrap: break-word; word-break: break-all;">\(displayTitle.htmlEscaped)</a>
                    <div style="font-size: 12px; color: #666; margin-top: 4px; font-weight: normal; overflow-wrap: break-word; word-break: break-all;">\(url.htmlEscaped)</div>
                </div>
            </div>
            """
        }

        Logger.noteQuery.warning("Could not fetch URL data for link card \(uuid)")
        return "<div style=\"color: #999; font-style: italic;\">[URL Link Card]</div>"
    }

    /// Generate HTML for PDF attachments
    private func generatePDFLinkHTML(attachment: NotesAttachment, relativePath: String?) -> String {
        guard let path = relativePath else {
            return "[PDF: \(attachment.filename ?? "document")]"
        }

        // Extract filename from the relative path if attachment.filename is not available
        let filename = attachment.filename ?? (path as NSString).lastPathComponent
        return """
        <div style="border: 1px solid #ddd; border-radius: 8px; padding: 12px; margin: 8px 0; background: #fff5f5; display: flex; align-items: center; font-size: 14px; font-weight: normal; font-style: normal; text-decoration: none;">
            <div style="font-size: 24px; margin-right: 12px; line-height: 1;">📄</div>
            <div style="flex: 1;">
                <a href="\(path.htmlEscaped)" target="_blank" style="text-decoration: none; color: #d32f2f; font-weight: 500; display: block; font-size: 14px;">\(filename.htmlEscaped)</a>
                <div style="font-size: 12px; color: #666; margin-top: 4px; font-weight: normal;">PDF Document</div>
            </div>
        </div>
        """
    }

    /// Generate HTML for generic file attachments
    private func generateGenericAttachmentHTML(filename: String, path: String, typeUTI: String) -> String {
        let icon = getFileIcon(for: typeUTI)
        let typeDescription = getTypeDescription(for: typeUTI)

        return """
        <div style="border: 1px solid #ddd; border-radius: 8px; padding: 12px; margin: 8px 0; background: #f9f9f9; display: flex; align-items: center; font-size: 14px; font-weight: normal; font-style: normal; text-decoration: none;">
            <div style="font-size: 24px; margin-right: 12px; line-height: 1;">\(icon)</div>
            <div style="flex: 1;">
                <a href="\(path.htmlEscaped)" target="_blank" style="text-decoration: none; color: #333; font-weight: 500; display: block; font-size: 14px;">\(filename.htmlEscaped)</a>
                <div style="font-size: 12px; color: #666; margin-top: 4px; font-weight: normal;">\(typeDescription)</div>
            </div>
        </div>
        """
    }

    /// Get an appropriate emoji icon for a file type
    private func getFileIcon(for typeUTI: String) -> String {
        if typeUTI.contains("video") || typeUTI.contains("movie") || typeUTI.contains("mp4") || typeUTI.contains("mov") {
            return "🎬"
        } else if typeUTI.contains("audio") || typeUTI.contains("music") || typeUTI.contains("mp3") {
            return "🎵"
        } else if typeUTI.contains("zip") || typeUTI.contains("archive") {
            return "📦"
        } else if typeUTI.contains("text") || typeUTI.contains("txt") {
            return "📝"
        } else {
            return "📎"
        }
    }

    /// Get a user-friendly description for a file type
    private func getTypeDescription(for typeUTI: String) -> String {
        let descriptions: [String: String] = [
            "public.movie": "Video",
            "com.apple.quicktime-movie": "QuickTime Movie",
            "public.mpeg-4": "MP4 Video",
            "public.mp3": "MP3 Audio",
            "public.text": "Text File",
            "public.plain-text": "Plain Text",
            "public.zip-archive": "ZIP Archive"
        ]

        if let description = descriptions[typeUTI] {
            return description
        }

        // Extract last component of UTI as fallback
        let components = typeUTI.components(separatedBy: ".")
        if let last = components.last {
            return last.capitalized + " File"
        }

        return "File"
    }

    /// Fetch URL link card data from database
    private func fetchURLLinkCard(uuid: String) -> (url: String, title: String?)? {
        let query = """
        SELECT ZURLSTRING, ZTITLE, ZALTTEXT
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE ZIDENTIFIER = ?
        AND (ZMARKEDFORDELETION = 0 OR ZMARKEDFORDELETION IS NULL);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            Logger.noteQuery.error("Failed to prepare URL link card query for UUID \(uuid)")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (uuid as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            Logger.noteQuery.debug("No data found in database for URL link card UUID \(uuid)")
            return nil
        }

        // Get the URL from ZURLSTRING column
        guard let urlString = sqlite3_column_text(statement, 0).flatMap({ String(cString: $0) }) else {
            Logger.noteQuery.warning("URL link card \(uuid): ZURLSTRING is NULL")
            return nil
        }

        // Try to get title from ZTITLE or ZALTTEXT columns
        let title = sqlite3_column_text(statement, 1).flatMap { String(cString: $0) }
            ?? sqlite3_column_text(statement, 2).flatMap { String(cString: $0) }

        Logger.noteQuery.debug("URL link card \(uuid): url=\(urlString), title=\(title ?? "nil")")

        return (url: urlString, title: title)
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
            let proto = try MergableDataProto(serializedBytes: data, extensions: nil, partial: true)
            let objectData = proto.mergableDataObject.mergeableDataObjectData

            Logger.noteQuery.debug("URL protobuf has \(objectData.mergeableDataObjectEntry.count) entries")

            // Look for URL in the note text or string values
            for (index, entry) in objectData.mergeableDataObjectEntry.enumerated() {
                if entry.hasNote {
                    let text = entry.note.noteText
                    Logger.noteQuery.debug("Entry[\(index)] has Note with text: '\(text)'")
                    // Check if it looks like a URL
                    if text.hasPrefix("http://") || text.hasPrefix("https://") {
                        Logger.noteQuery.debug("Found URL in entry[\(index)]: \(text)")
                        return text
                    }
                }
            }

            Logger.noteQuery.debug("No URL found in any Note entries")
        } catch {
            Logger.noteQuery.warning("Failed to parse URL protobuf: \(error.localizedDescription)")
        }

        return nil
    }

    /// Get base64-encoded image data from database or exported file
    private func getImageBase64(uuid: String, typeUTI: String, relativePath: String?) -> String? {
        // Query for the media blob
        let query = """
        SELECT ZMEDIA
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE ZIDENTIFIER = ?
        AND (ZMARKEDFORDELETION = 0 OR ZMARKEDFORDELETION IS NULL);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            Logger.noteQuery.error("Failed to prepare image query for UUID \(uuid)")
            return tryLoadFromFile(relativePath: relativePath, uuid: uuid)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (uuid as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            Logger.noteQuery.debug("No media data found in ZMEDIA for UUID \(uuid), trying external file")
            return tryLoadFromFile(relativePath: relativePath, uuid: uuid, typeUTI: typeUTI)
        }

        // Get the blob data
        if let blob = sqlite3_column_blob(statement, 0) {
            let size = sqlite3_column_bytes(statement, 0)

            // If size is very small (< 100 bytes), it's likely just a reference, not actual image data
            if size < 100 {
                Logger.noteQuery.debug("ZMEDIA has only \(size) bytes for UUID \(uuid) - likely a reference, trying external file")
                return tryLoadFromFile(relativePath: relativePath, uuid: uuid, typeUTI: typeUTI)
            }

            let data = Data(bytes: blob, count: Int(size))
            Logger.noteQuery.debug("Successfully retrieved \(size) bytes of image data from ZMEDIA for UUID \(uuid)")

            // Convert HEIC to JPEG to avoid WebKit rendering issues
            if typeUTI.contains("heic") || typeUTI.contains("HEIC") {
                if let convertedData = convertHEICToJPEG(data) {
                    Logger.noteQuery.debug("Converted HEIC to JPEG for UUID \(uuid), new size: \(convertedData.count) bytes")
                    return convertedData.base64EncodedString()
                } else {
                    Logger.noteQuery.warning("Failed to convert HEIC to JPEG for UUID \(uuid), using original data")
                }
            }

            return data.base64EncodedString()
        }

        Logger.noteQuery.warning("ZMEDIA column was NULL for UUID \(uuid), trying external file")
        return tryLoadFromFile(relativePath: relativePath, uuid: uuid, typeUTI: typeUTI)
    }

    /// Try to load image data from the exported file
    private func tryLoadFromFile(relativePath: String?, uuid: String, typeUTI: String = "") -> String? {
        guard let relativePath = relativePath, let exportDir = exportDirectory else {
            Logger.noteQuery.debug("Cannot load from file - no relativePath or exportDirectory for UUID \(uuid)")
            return nil
        }

        // Combine export directory with relative path
        let fullPath = (exportDir as NSString).appendingPathComponent(relativePath)

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: fullPath))
            Logger.noteQuery.debug("Successfully loaded \(data.count) bytes from external file for UUID \(uuid)")

            // Convert HEIC to JPEG to avoid WebKit rendering issues
            if typeUTI.contains("heic") || typeUTI.contains("HEIC") || fullPath.hasSuffix(".heic") || fullPath.hasSuffix(".HEIC") {
                if let convertedData = convertHEICToJPEG(data) {
                    Logger.noteQuery.debug("Converted external HEIC to JPEG for UUID \(uuid), new size: \(convertedData.count) bytes")
                    return convertedData.base64EncodedString()
                } else {
                    Logger.noteQuery.warning("Failed to convert external HEIC to JPEG for UUID \(uuid), using original data")
                }
            }

            return data.base64EncodedString()
        } catch {
            Logger.noteQuery.warning("Failed to load image from file \(fullPath): \(error.localizedDescription)")
            return nil
        }
    }

    /// Convert HEIC image data to JPEG to avoid WebKit rendering issues
    /// Returns nil if conversion fails
    private func convertHEICToJPEG(_ heicData: Data) -> Data? {
        guard let image = NSImage(data: heicData) else {
            Logger.noteQuery.error("Failed to create NSImage from HEIC data")
            return nil
        }

        guard let tiffData = image.tiffRepresentation else {
            Logger.noteQuery.error("Failed to get TIFF representation from NSImage")
            return nil
        }

        guard let bitmap = NSBitmapImageRep(data: tiffData) else {
            Logger.noteQuery.error("Failed to create bitmap from TIFF data")
            return nil
        }

        // Convert to JPEG with quality 0.9 (good balance between quality and size)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            Logger.noteQuery.error("Failed to convert bitmap to JPEG")
            return nil
        }

        return jpegData
    }

    /// Convert UTI to MIME type
    private func utiToMimeType(_ uti: String) -> String {
        let mimeTypes: [String: String] = [
            "public.jpeg": "image/jpeg",
            "public.png": "image/png",
            "public.heic": "image/jpeg",  // Return JPEG MIME type for HEIC since we convert it
            "public.image": "image/png",
            "public.tiff": "image/tiff",
            "com.compuserve.gif": "image/gif"
        ]

        return mimeTypes[uti] ?? "image/png"
    }
}
