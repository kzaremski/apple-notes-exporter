//
//  NotesNote+Export.swift
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

// MARK: - Export Format Converters

extension NotesNote {

    // MARK: - Public Export Methods

    /// Convert note to plain text format
    /// Converts HTML to plain text, preserving structure without markdown syntax
    /// Includes tables (converted to plain text), links (with URLs in parentheses), hashtags
    /// Requires htmlBody to be available
    func toPlainText() -> String {
        return HTMLToPlainTextConverter.convert(htmlBody ?? "")
    }

    /// Convert note to Markdown format
    /// Preserves headings, lists, bold, italic, links, etc.
    /// Requires htmlBody to be available
    func toMarkdown() -> String {
        return HTMLToMarkdownConverter.convert(htmlBody ?? "")
    }

    /// Convert note to RTF format
    /// Preserves formatting with RTF control codes
    /// Requires htmlBody to be available
    func toRTF(fontFamily: String = "Helvetica", fontSize: Double = 12) -> String {
        return HTMLToRTFConverter.convert(htmlBody ?? "", fontFamily: fontFamily, fontSize: fontSize)
    }

    /// Convert note to LaTeX format with template
    /// Preserves formatting with LaTeX commands and replaces placeholders
    /// Requires htmlBody to be available
    func toLatex(template: String = LaTeXConfiguration.defaultTemplate) -> String {
        let content = HTMLToLatexConverter.convert(htmlBody ?? "")

        // Date formatters
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short

        // Get user's full name from system
        let userName = NSFullUserName()

        // Replace all placeholders
        var output = template
        output = output.replacingOccurrences(of: "APPLE_NOTES_EXPORTER_NOTE_CONTENT", with: content)
        output = output.replacingOccurrences(of: "APPLE_NOTES_EXPORTER_NOTE_TITLE", with: title.latexEscaped)
        output = output.replacingOccurrences(of: "APPLE_NOTES_EXPORTER_NOTE_CREATION_DATE", with: dateFormatter.string(from: creationDate))
        output = output.replacingOccurrences(of: "APPLE_NOTES_EXPORTER_NOTE_MODIFICATION_DATE", with: dateFormatter.string(from: modificationDate))
        output = output.replacingOccurrences(of: "APPLE_NOTES_EXPORTER_USER_FULL_NAME", with: userName.latexEscaped)

        return output
    }

    /// Convert note to JSON format
    /// Includes title, body text, creation/modification dates, folder ID, account ID, and attachment manifest
    func toJSON(folderName: String? = nil, accountName: String? = nil) -> String {
        return HTMLToJSONConverter.convert(self, folderName: folderName, accountName: accountName)
    }

    /// Convert note to JSONL format (single line of JSON)
    /// Same structure as JSON but compact single-line output
    func toJSONL(folderName: String? = nil, accountName: String? = nil) -> String {
        return HTMLToJSONLConverter.convert(self, folderName: folderName, accountName: accountName)
    }

    /// Convert note to XML format
    /// Structured note data with title, body, dates, folder, account, attachments
    func toXML(folderName: String? = nil, accountName: String? = nil) -> String {
        return HTMLToXMLConverter.convert(self, folderName: folderName, accountName: accountName)
    }

    /// Convert note to CSV row format
    /// Returns a single CSV row: title, folder, account, created, modified, body, attachment count
    /// Call `csvHeader()` separately for the header row
    func toCSV(folderName: String? = nil, accountName: String? = nil) -> String {
        return HTMLToCSVConverter.convertRow(self, folderName: folderName, accountName: accountName)
    }

    /// Get CSV header row
    static func csvHeader() -> String {
        return HTMLToCSVConverter.header()
    }

    /// Convert note to OPML format
    /// Outline with note title as top-level element and headings as children
    func toOPML() -> String {
        return HTMLToOPMLConverter.convert(self)
    }

    /// Convert note to Org-mode format
    /// Emacs Org-mode with headings, markup, timestamps
    func toOrg() -> String {
        return HTMLToOrgConverter.convert(htmlBody ?? "", title: title, creationDate: creationDate, modificationDate: modificationDate)
    }

    /// Convert note to reStructuredText format
    /// Sphinx/Python documentation format
    func toRST() -> String {
        return HTMLToRSTConverter.convert(htmlBody ?? "", title: title)
    }

    /// Convert note to AsciiDoc format
    /// Technical documentation format
    func toAsciiDoc() -> String {
        return HTMLToAsciiDocConverter.convert(htmlBody ?? "", title: title)
    }

    /// Convert note to ENEX (Evernote export) format
    /// Compatible with Evernote, Joplin, and other importers
    func toENEX() -> String {
        return HTMLToENEXConverter.convert(self)
    }

    /// Convert note to DOCX format (returns raw ZIP data)
    /// Microsoft Word Open XML format
    func toDOCX() -> Data {
        return HTMLToDOCXConverter.convert(self)
    }

    /// Convert note to ODT format (returns raw ZIP data)
    /// OpenDocument Text format for LibreOffice
    func toODT() -> Data {
        return HTMLToODTConverter.convert(self)
    }

    /// Convert note to EPUB format (returns raw ZIP data)
    /// E-book format for readers
    func toEPUB() -> Data {
        return HTMLToEPUBConverter.convert(self)
    }
}

// MARK: - JSON Converter

private struct HTMLToJSONConverter {
    static func convert(_ note: NotesNote, folderName: String?, accountName: String?) -> String {
        let plainText = HTMLToPlainTextConverter.convert(note.htmlBody ?? "")
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let dict: [(String, String)] = [
            ("title", escapeJSON(note.title)),
            ("body", escapeJSON(plainText)),
            ("created", escapeJSON(isoFormatter.string(from: note.creationDate))),
            ("modified", escapeJSON(isoFormatter.string(from: note.modificationDate))),
            ("folder", escapeJSON(folderName ?? note.folderId)),
            ("account", escapeJSON(accountName ?? note.accountId)),
            ("attachment_count", "\(note.attachments.count)")
        ]

        // Build attachments array
        let attachmentEntries = note.attachments.map { attachment -> String in
            let parts = [
                "\"id\": \"\(escapeJSON(attachment.id))\"",
                "\"type\": \"\(escapeJSON(attachment.typeUTI))\"",
                "\"filename\": \(attachment.filename != nil ? "\"\(escapeJSON(attachment.filename!))\"" : "null")"
            ]
            return "{ \(parts.joined(separator: ", ")) }"
        }

        var lines: [String] = []
        lines.append("{")
        for (i, (key, value)) in dict.enumerated() {
            let comma = i < dict.count - 1 || !attachmentEntries.isEmpty ? "," : ""
            if key == "attachment_count" {
                lines.append("  \"\(key)\": \(value)\(comma)")
            } else {
                lines.append("  \"\(key)\": \"\(value)\"\(comma)")
            }
        }
        if !attachmentEntries.isEmpty {
            lines.append("  \"attachments\": [")
            for (i, entry) in attachmentEntries.enumerated() {
                let comma = i < attachmentEntries.count - 1 ? "," : ""
                lines.append("    \(entry)\(comma)")
            }
            lines.append("  ]")
        } else {
            // Replace trailing comma on attachment_count if no attachments array
            if let lastIdx = lines.indices.last {
                lines[lastIdx] = lines[lastIdx].replacingOccurrences(of: ",", with: "", options: .backwards, range: nil)
            }
        }
        lines.append("}")

        return lines.joined(separator: "\n")
    }

    static func escapeJSON(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "\"", with: "\\\"")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "\\r")
        result = result.replacingOccurrences(of: "\t", with: "\\t")
        return result
    }
}

// MARK: - JSONL Converter

private struct HTMLToJSONLConverter {
    static func convert(_ note: NotesNote, folderName: String?, accountName: String?) -> String {
        let plainText = HTMLToPlainTextConverter.convert(note.htmlBody ?? "")
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let esc = HTMLToJSONConverter.escapeJSON

        let attachmentEntries = note.attachments.map { attachment -> String in
            let parts = [
                "\"id\":\"\(esc(attachment.id))\"",
                "\"type\":\"\(esc(attachment.typeUTI))\"",
                "\"filename\":\(attachment.filename != nil ? "\"\(esc(attachment.filename!))\"" : "null")"
            ]
            return "{\(parts.joined(separator: ","))}"
        }

        let parts: [String] = [
            "\"title\":\"\(esc(note.title))\"",
            "\"body\":\"\(esc(plainText))\"",
            "\"created\":\"\(esc(isoFormatter.string(from: note.creationDate)))\"",
            "\"modified\":\"\(esc(isoFormatter.string(from: note.modificationDate)))\"",
            "\"folder\":\"\(esc(folderName ?? note.folderId))\"",
            "\"account\":\"\(esc(accountName ?? note.accountId))\"",
            "\"attachment_count\":\(note.attachments.count)",
            "\"attachments\":[\(attachmentEntries.joined(separator: ","))]"
        ]

        return "{\(parts.joined(separator: ","))}"
    }
}

// MARK: - XML Converter

private struct HTMLToXMLConverter {
    static func convert(_ note: NotesNote, folderName: String?, accountName: String?) -> String {
        let plainText = HTMLToPlainTextConverter.convert(note.htmlBody ?? "")
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<note>")
        lines.append("  <title>\(escapeXML(note.title))</title>")
        lines.append("  <body>\(escapeXML(plainText))</body>")
        lines.append("  <created>\(isoFormatter.string(from: note.creationDate))</created>")
        lines.append("  <modified>\(isoFormatter.string(from: note.modificationDate))</modified>")
        lines.append("  <folder>\(escapeXML(folderName ?? note.folderId))</folder>")
        lines.append("  <account>\(escapeXML(accountName ?? note.accountId))</account>")
        lines.append("  <attachments count=\"\(note.attachments.count)\">")
        for attachment in note.attachments {
            lines.append("    <attachment>")
            lines.append("      <id>\(escapeXML(attachment.id))</id>")
            lines.append("      <type>\(escapeXML(attachment.typeUTI))</type>")
            if let filename = attachment.filename {
                lines.append("      <filename>\(escapeXML(filename))</filename>")
            }
            lines.append("    </attachment>")
        }
        lines.append("  </attachments>")
        lines.append("</note>")

        return lines.joined(separator: "\n")
    }

    static func escapeXML(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        return result
    }
}

// MARK: - CSV Converter

private struct HTMLToCSVConverter {
    static func header() -> String {
        return "\"Title\",\"Folder\",\"Account\",\"Created\",\"Modified\",\"Body\",\"Attachment Count\""
    }

    static func convertRow(_ note: NotesNote, folderName: String?, accountName: String?) -> String {
        let plainText = HTMLToPlainTextConverter.convert(note.htmlBody ?? "")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let fields = [
            escapeCSV(note.title),
            escapeCSV(folderName ?? note.folderId),
            escapeCSV(accountName ?? note.accountId),
            escapeCSV(dateFormatter.string(from: note.creationDate)),
            escapeCSV(dateFormatter.string(from: note.modificationDate)),
            escapeCSV(plainText),
            "\(note.attachments.count)"
        ]

        return fields.joined(separator: ",")
    }

    static func escapeCSV(_ string: String) -> String {
        // CSV fields with commas, quotes, or newlines must be quoted
        let escaped = string.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

// MARK: - OPML Converter

private struct HTMLToOPMLConverter {
    static func convert(_ note: NotesNote) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<opml version=\"2.0\">")
        lines.append("  <head>")
        lines.append("    <title>\(HTMLToXMLConverter.escapeXML(note.title))</title>")
        lines.append("    <dateCreated>\(dateFormatter.string(from: note.creationDate))</dateCreated>")
        lines.append("    <dateModified>\(dateFormatter.string(from: note.modificationDate))</dateModified>")
        lines.append("  </head>")
        lines.append("  <body>")

        // Parse HTML body into outline elements
        let outlineLines = parseHTMLToOutline(note.htmlBody ?? "")
        for line in outlineLines {
            lines.append("    \(line)")
        }

        lines.append("  </body>")
        lines.append("</opml>")

        return lines.joined(separator: "\n")
    }

    private static func parseHTMLToOutline(_ html: String) -> [String] {
        guard let bodyContent = extractBodyContent(html) else {
            return ["<outline text=\"\(HTMLToXMLConverter.escapeXML(html))\" />"]
        }

        var outlines: [String] = []

        // Simple line-based parsing
        let lines = bodyContent
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .components(separatedBy: "\n")

        for line in lines {
            var stripped = line.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)

            if stripped.isEmpty { continue }

            // Check if it was a heading
            if line.contains("<h1>") || line.contains("<h2>") || line.contains("<h3>") {
                outlines.append("<outline text=\"\(HTMLToXMLConverter.escapeXML(stripped))\" />")
            } else if line.contains("<li>") {
                outlines.append("<outline text=\"\(HTMLToXMLConverter.escapeXML(stripped))\" />")
            } else {
                outlines.append("<outline text=\"\(HTMLToXMLConverter.escapeXML(stripped))\" />")
            }
        }

        if outlines.isEmpty {
            // Fallback: single outline with all plain text
            let plainText = bodyContent.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            outlines.append("<outline text=\"\(HTMLToXMLConverter.escapeXML(plainText))\" />")
        }

        return outlines
    }

    private static func extractBodyContent(_ html: String) -> String? {
        guard let bodyStart = html.range(of: "<body>"),
              let bodyEnd = html.range(of: "</body>") else {
            return html
        }
        return String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
    }
}

// MARK: - Org-mode Converter

private struct HTMLToOrgConverter {
    static func convert(_ html: String, title: String, creationDate: Date, modificationDate: Date) -> String {
        guard let bodyContent = extractBodyContent(html) else {
            return "#+TITLE: \(title)\n\n\(html)"
        }

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd EEE HH:mm"

        var result = ""

        // Org-mode header
        result += "#+TITLE: \(title)\n"
        result += "#+DATE: [\(isoFormatter.string(from: creationDate))]\n"
        result += "#+MODIFIED: [\(isoFormatter.string(from: modificationDate))]\n\n"

        var body = bodyContent

        // Convert headings: <h1> -> *, <h2> -> **, <h3> -> ***
        body = body.replacingOccurrences(of: "<h1>", with: "\n* ")
        body = body.replacingOccurrences(of: "</h1>", with: "\n")
        body = body.replacingOccurrences(of: "<h2>", with: "\n** ")
        body = body.replacingOccurrences(of: "</h2>", with: "\n")
        body = body.replacingOccurrences(of: "<h3>", with: "\n*** ")
        body = body.replacingOccurrences(of: "</h3>", with: "\n")

        // Convert bold
        body = body.replacingOccurrences(of: "<b>", with: "*")
        body = body.replacingOccurrences(of: "</b>", with: "*")
        body = body.replacingOccurrences(of: "<strong>", with: "*")
        body = body.replacingOccurrences(of: "</strong>", with: "*")

        // Convert italic
        body = body.replacingOccurrences(of: "<i>", with: "/")
        body = body.replacingOccurrences(of: "</i>", with: "/")
        body = body.replacingOccurrences(of: "<em>", with: "/")
        body = body.replacingOccurrences(of: "</em>", with: "/")

        // Convert underline
        body = body.replacingOccurrences(of: "<u>", with: "_")
        body = body.replacingOccurrences(of: "</u>", with: "_")

        // Convert strikethrough
        body = body.replacingOccurrences(of: "<s>", with: "+")
        body = body.replacingOccurrences(of: "</s>", with: "+")

        // Convert inline code
        body = body.replacingOccurrences(of: "<code>", with: "~")
        body = body.replacingOccurrences(of: "</code>", with: "~")

        // Convert code blocks
        body = body.replacingOccurrences(of: "<pre[^>]*>", with: "\n#+BEGIN_SRC\n", options: .regularExpression)
        body = body.replacingOccurrences(of: "</pre>", with: "\n#+END_SRC\n")

        // Convert links
        body = body.replacingOccurrences(of: "<a href='([^']*)'[^>]*>([^<]*)</a>",
                                         with: "[[$1][$2]]",
                                         options: .regularExpression)

        // Convert lists
        body = body.replacingOccurrences(of: "<ul>", with: "")
        body = body.replacingOccurrences(of: "</ul>", with: "\n")
        body = body.replacingOccurrences(of: "<ul style='list-style-type: square;'>", with: "")
        body = body.replacingOccurrences(of: "<ul style='list-style-type: none;'>", with: "")
        body = body.replacingOccurrences(of: "<ol>", with: "")
        body = body.replacingOccurrences(of: "</ol>", with: "\n")
        body = body.replacingOccurrences(of: "<li>", with: "- ")
        body = body.replacingOccurrences(of: "</li>", with: "\n")

        // Line breaks
        body = body.replacingOccurrences(of: "<br>", with: "\n")
        body = body.replacingOccurrences(of: "<br/>", with: "\n")
        body = body.replacingOccurrences(of: "<br />", with: "\n")

        // Strip remaining tags
        body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Clean up multiple newlines
        body = body.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)

        result += body.trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }

    private static func extractBodyContent(_ html: String) -> String? {
        guard let bodyStart = html.range(of: "<body>"),
              let bodyEnd = html.range(of: "</body>") else {
            return html
        }
        return String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
    }
}

// MARK: - reStructuredText Converter

private struct HTMLToRSTConverter {
    static func convert(_ html: String, title: String) -> String {
        guard let bodyContent = extractBodyContent(html) else {
            return "\(title)\n\(String(repeating: "=", count: title.count))\n\n\(html)"
        }

        var result = ""

        // RST title with overline/underline
        let titleLine = String(repeating: "=", count: max(title.count, 4))
        result += "\(titleLine)\n\(title)\n\(titleLine)\n\n"

        var body = bodyContent

        // Convert headings
        // H1 -> section (=), H2 -> subsection (-), H3 -> subsubsection (~)
        if let regex = try? NSRegularExpression(pattern: "<h([1-3])>([^<]*)</h[1-3]>", options: []) {
            let nsBody = body as NSString
            let matches = regex.matches(in: body, options: [], range: NSRange(location: 0, length: nsBody.length))
            for match in matches.reversed() {
                guard let levelRange = Range(match.range(at: 1), in: body),
                      let textRange = Range(match.range(at: 2), in: body),
                      let fullRange = Range(match.range, in: body) else { continue }
                let level = String(body[levelRange])
                let text = String(body[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let underlineChar: Character = level == "1" ? "=" : (level == "2" ? "-" : "~")
                let underline = String(repeating: underlineChar, count: max(text.count, 4))
                body.replaceSubrange(fullRange, with: "\n\(text)\n\(underline)\n")
            }
        }

        // Convert bold
        body = body.replacingOccurrences(of: "<b>", with: "**")
        body = body.replacingOccurrences(of: "</b>", with: "**")
        body = body.replacingOccurrences(of: "<strong>", with: "**")
        body = body.replacingOccurrences(of: "</strong>", with: "**")

        // Convert italic
        body = body.replacingOccurrences(of: "<i>", with: "*")
        body = body.replacingOccurrences(of: "</i>", with: "*")
        body = body.replacingOccurrences(of: "<em>", with: "*")
        body = body.replacingOccurrences(of: "</em>", with: "*")

        // Convert inline code
        body = body.replacingOccurrences(of: "<code>", with: "``")
        body = body.replacingOccurrences(of: "</code>", with: "``")

        // Convert code blocks
        body = body.replacingOccurrences(of: "<pre[^>]*>", with: "\n.. code-block::\n\n   ", options: .regularExpression)
        body = body.replacingOccurrences(of: "</pre>", with: "\n")

        // Convert links
        body = body.replacingOccurrences(of: "<a href='([^']*)'[^>]*>([^<]*)</a>",
                                         with: "`$2 <$1>`_",
                                         options: .regularExpression)

        // Convert lists
        body = body.replacingOccurrences(of: "<ul>", with: "")
        body = body.replacingOccurrences(of: "</ul>", with: "\n")
        body = body.replacingOccurrences(of: "<ul style='list-style-type: square;'>", with: "")
        body = body.replacingOccurrences(of: "<ul style='list-style-type: none;'>", with: "")
        body = body.replacingOccurrences(of: "<ol>", with: "")
        body = body.replacingOccurrences(of: "</ol>", with: "\n")
        body = body.replacingOccurrences(of: "<li>", with: "- ")
        body = body.replacingOccurrences(of: "</li>", with: "\n")

        // Line breaks
        body = body.replacingOccurrences(of: "<br>", with: "\n")
        body = body.replacingOccurrences(of: "<br/>", with: "\n")
        body = body.replacingOccurrences(of: "<br />", with: "\n")

        // Strip remaining tags
        body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Clean up multiple newlines
        body = body.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)

        result += body.trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }

    private static func extractBodyContent(_ html: String) -> String? {
        guard let bodyStart = html.range(of: "<body>"),
              let bodyEnd = html.range(of: "</body>") else {
            return html
        }
        return String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
    }
}

// MARK: - AsciiDoc Converter

private struct HTMLToAsciiDocConverter {
    static func convert(_ html: String, title: String) -> String {
        guard let bodyContent = extractBodyContent(html) else {
            return "= \(title)\n\n\(html)"
        }

        var result = ""

        // AsciiDoc document title
        result += "= \(title)\n\n"

        var body = bodyContent

        // Convert headings: <h1> -> ==, <h2> -> ===, <h3> -> ====
        body = body.replacingOccurrences(of: "<h1>", with: "\n== ")
        body = body.replacingOccurrences(of: "</h1>", with: "\n")
        body = body.replacingOccurrences(of: "<h2>", with: "\n=== ")
        body = body.replacingOccurrences(of: "</h2>", with: "\n")
        body = body.replacingOccurrences(of: "<h3>", with: "\n==== ")
        body = body.replacingOccurrences(of: "</h3>", with: "\n")

        // Convert bold
        body = body.replacingOccurrences(of: "<b>", with: "*")
        body = body.replacingOccurrences(of: "</b>", with: "*")
        body = body.replacingOccurrences(of: "<strong>", with: "*")
        body = body.replacingOccurrences(of: "</strong>", with: "*")

        // Convert italic
        body = body.replacingOccurrences(of: "<i>", with: "_")
        body = body.replacingOccurrences(of: "</i>", with: "_")
        body = body.replacingOccurrences(of: "<em>", with: "_")
        body = body.replacingOccurrences(of: "</em>", with: "_")

        // Convert underline (AsciiDoc uses [.underline]# but simpler to use underscores)
        body = body.replacingOccurrences(of: "<u>", with: "[.underline]#")
        body = body.replacingOccurrences(of: "</u>", with: "#")

        // Convert strikethrough
        body = body.replacingOccurrences(of: "<s>", with: "[.line-through]#")
        body = body.replacingOccurrences(of: "</s>", with: "#")

        // Convert inline code
        body = body.replacingOccurrences(of: "<code>", with: "`")
        body = body.replacingOccurrences(of: "</code>", with: "`")

        // Convert code blocks
        body = body.replacingOccurrences(of: "<pre[^>]*>", with: "\n----\n", options: .regularExpression)
        body = body.replacingOccurrences(of: "</pre>", with: "\n----\n")

        // Convert links
        body = body.replacingOccurrences(of: "<a href='([^']*)'[^>]*>([^<]*)</a>",
                                         with: "$1[$2]",
                                         options: .regularExpression)

        // Convert lists
        body = body.replacingOccurrences(of: "<ul>", with: "")
        body = body.replacingOccurrences(of: "</ul>", with: "\n")
        body = body.replacingOccurrences(of: "<ul style='list-style-type: square;'>", with: "")
        body = body.replacingOccurrences(of: "<ul style='list-style-type: none;'>", with: "")
        body = body.replacingOccurrences(of: "<ol>", with: "")
        body = body.replacingOccurrences(of: "</ol>", with: "\n")
        body = body.replacingOccurrences(of: "<li>", with: "* ")
        body = body.replacingOccurrences(of: "</li>", with: "\n")

        // Line breaks
        body = body.replacingOccurrences(of: "<br>", with: "\n")
        body = body.replacingOccurrences(of: "<br/>", with: "\n")
        body = body.replacingOccurrences(of: "<br />", with: "\n")

        // Strip remaining tags
        body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Clean up multiple newlines
        body = body.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)

        result += body.trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }

    private static func extractBodyContent(_ html: String) -> String? {
        guard let bodyStart = html.range(of: "<body>"),
              let bodyEnd = html.range(of: "</body>") else {
            return html
        }
        return String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
    }
}

// MARK: - LaTeX String Extension

private extension String {
    var latexEscaped: String {
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

// MARK: - Plain Text Converter

private struct HTMLToPlainTextConverter {
    static func convert(_ html: String) -> String {
        var listDepth = 0

        // Extract content between <body> tags
        guard let bodyContent = extractBodyContent(html) else {
            return html
        }

        // Simple HTML parsing - process tag by tag
        var currentText = bodyContent

        // Handle tables first - convert to plain text format
        currentText = processTables(currentText)

        // Handle headings - just extract text, add newline after (no # symbols)
        currentText = processHeadings(currentText)

        // Handle lists - use simple bullets (no - or * prefixes)
        currentText = processLists(currentText, listDepth: &listDepth)

        // Handle line breaks
        currentText = currentText.replacingOccurrences(of: "<br>", with: "\n")
        currentText = currentText.replacingOccurrences(of: "<br/>", with: "\n")
        currentText = currentText.replacingOccurrences(of: "<br />", with: "\n")

        // Handle pre/code blocks - just preserve content without backticks
        currentText = currentText.replacingOccurrences(of: "<pre[^>]*>", with: "", options: .regularExpression)
        currentText = currentText.replacingOccurrences(of: "</pre>", with: "\n")
        currentText = currentText.replacingOccurrences(of: "<code>", with: "")
        currentText = currentText.replacingOccurrences(of: "</code>", with: "")

        // Strip remaining HTML tags but keep content
        currentText = stripHTMLTags(currentText)

        // Clean up multiple consecutive newlines
        currentText = currentText.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)

        return currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractBodyContent(_ html: String) -> String? {
        // Extract content between <body> and </body>
        guard let bodyStart = html.range(of: "<body>"),
              let bodyEnd = html.range(of: "</body>") else {
            return html
        }
        return String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
    }

    private static func processTables(_ html: String) -> String {
        var result = html

        // Convert table rows to newlines, cells to tab-separated values
        result = result.replacingOccurrences(of: "<table[^>]*>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "</table>", with: "\n")
        result = result.replacingOccurrences(of: "<thead>", with: "")
        result = result.replacingOccurrences(of: "</thead>", with: "")
        result = result.replacingOccurrences(of: "<tbody>", with: "")
        result = result.replacingOccurrences(of: "</tbody>", with: "")
        result = result.replacingOccurrences(of: "<tr>", with: "")
        result = result.replacingOccurrences(of: "</tr>", with: "\n")
        result = result.replacingOccurrences(of: "<th[^>]*>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "</th>", with: "\t")
        result = result.replacingOccurrences(of: "<td[^>]*>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "</td>", with: "\t")

        return result
    }

    private static func processHeadings(_ html: String) -> String {
        var result = html

        // Replace heading tags with just their content and newlines (no # symbols)
        for i in 1...6 {
            let openTag = "<h\(i)>"
            let closeTag = "</h\(i)>"
            result = result.replacingOccurrences(of: openTag, with: "")
            result = result.replacingOccurrences(of: closeTag, with: "\n")
        }

        return result
    }

    private static func processLists(_ html: String, listDepth: inout Int) -> String {
        var result = html

        // Process unordered lists
        result = result.replacingOccurrences(of: "<ul>", with: "")
        result = result.replacingOccurrences(of: "</ul>", with: "\n")
        result = result.replacingOccurrences(of: "<ul style='list-style-type: square;'>", with: "")
        result = result.replacingOccurrences(of: "<ul style='list-style-type: none;'>", with: "")

        // Process ordered lists
        result = result.replacingOccurrences(of: "<ol>", with: "")
        result = result.replacingOccurrences(of: "</ol>", with: "\n")

        // Process list items - use bullet • for plain text (no *, -, or numbers)
        result = result.replacingOccurrences(of: "<li>", with: "• ")
        result = result.replacingOccurrences(of: "</li>", with: "\n")

        return result
    }

    private static func stripHTMLTags(_ html: String) -> String {
        var result = html

        // Remove common formatting tags but keep content
        let tagsToStrip = ["b", "i", "u", "s", "a", "strong", "em", "span", "div"]
        for tag in tagsToStrip {
            result = result.replacingOccurrences(of: "<\(tag)>", with: "", options: .caseInsensitive)
            result = result.replacingOccurrences(of: "</\(tag)>", with: "", options: .caseInsensitive)
            // Handle tags with attributes
            result = result.replacingOccurrences(of: "<\(tag) [^>]*>", with: "", options: .regularExpression)
        }

        // Handle anchor tags specially to preserve URLs
        result = result.replacingOccurrences(of: "<a href='([^']*)'[^>]*>([^<]*)</a>",
                                            with: "$2 ($1)",
                                            options: .regularExpression)

        return result
    }
}

// MARK: - Markdown Converter

private struct HTMLToMarkdownConverter {
    static func convert(_ html: String) -> String {
        guard let bodyContent = extractBodyContent(html) else {
            return html
        }

        var result = bodyContent

        // Convert code blocks FIRST (before other transformations strip inner tags)
        // Handles <pre> with optional style attributes (e.g. from Apple Notes monospaced blocks)
        result = processCodeBlocks(result)

        // Convert inline code
        result = result.replacingOccurrences(of: "<code>([^<]*)</code>",
                                            with: "`$1`",
                                            options: .regularExpression)

        // Convert headings
        result = result.replacingOccurrences(of: "<h1>", with: "# ")
        result = result.replacingOccurrences(of: "</h1>", with: "\n")
        result = result.replacingOccurrences(of: "<h2>", with: "## ")
        result = result.replacingOccurrences(of: "</h2>", with: "\n")
        result = result.replacingOccurrences(of: "<h3>", with: "### ")
        result = result.replacingOccurrences(of: "</h3>", with: "\n")

        // Convert bold
        result = result.replacingOccurrences(of: "<b>", with: "**")
        result = result.replacingOccurrences(of: "</b>", with: "**")
        result = result.replacingOccurrences(of: "<strong>", with: "**")
        result = result.replacingOccurrences(of: "</strong>", with: "**")

        // Convert italic
        result = result.replacingOccurrences(of: "<i>", with: "*")
        result = result.replacingOccurrences(of: "</i>", with: "*")
        result = result.replacingOccurrences(of: "<em>", with: "*")
        result = result.replacingOccurrences(of: "</em>", with: "*")

        // Convert underline (approximate with italic)
        result = result.replacingOccurrences(of: "<u>", with: "_")
        result = result.replacingOccurrences(of: "</u>", with: "_")

        // Convert strikethrough
        result = result.replacingOccurrences(of: "<s>", with: "~~")
        result = result.replacingOccurrences(of: "</s>", with: "~~")

        // Convert links
        result = result.replacingOccurrences(of: "<a href='([^']*)'[^>]*>([^<]*)</a>",
                                            with: "[$2]($1)",
                                            options: .regularExpression)

        // Convert lists
        result = result.replacingOccurrences(of: "<ul>", with: "")
        result = result.replacingOccurrences(of: "</ul>", with: "\n")
        result = result.replacingOccurrences(of: "<ul style='list-style-type: square;'>", with: "")
        result = result.replacingOccurrences(of: "<ul style='list-style-type: none;'>", with: "")
        result = result.replacingOccurrences(of: "<ol>", with: "")
        result = result.replacingOccurrences(of: "</ol>", with: "\n")

        // List items
        result = result.replacingOccurrences(of: "<li>", with: "- ")
        result = result.replacingOccurrences(of: "</li>", with: "\n")

        // Line breaks
        result = result.replacingOccurrences(of: "<br>", with: "\n")
        result = result.replacingOccurrences(of: "<br/>", with: "\n")
        result = result.replacingOccurrences(of: "<br />", with: "\n")

        // Clean up remaining tags
        result = stripRemainingTags(result)

        // Clean up multiple newlines
        result = result.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Convert <pre> blocks (with optional style attributes) to Markdown fenced code blocks.
    /// Apple Notes generates: <pre style='white-space: pre-wrap; font-family: monospace; ...'>content</pre>
    private static func processCodeBlocks(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<pre[^>]*>(.*?)</pre>",
            options: [.dotMatchesLineSeparators]
        ) else {
            return html
        }

        let nsString = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))

        // Process matches in reverse order to preserve string indices
        var result = html
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let contentRange = Range(match.range(at: 1), in: result) else {
                continue
            }

            // Extract the code content, strip any inner HTML tags (like <br>, <b>, etc.)
            var codeContent = String(result[contentRange])
            // Convert <br> variants to newlines within code blocks
            codeContent = codeContent.replacingOccurrences(of: "<br>", with: "\n")
            codeContent = codeContent.replacingOccurrences(of: "<br/>", with: "\n")
            codeContent = codeContent.replacingOccurrences(of: "<br />", with: "\n")
            // Strip any remaining HTML tags inside the code block
            codeContent = codeContent.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

            // Build the fenced code block
            let fencedBlock = "\n```\n\(codeContent)\n```\n"

            result.replaceSubrange(fullRange, with: fencedBlock)
        }

        return result
    }

    private static func extractBodyContent(_ html: String) -> String? {
        guard let bodyStart = html.range(of: "<body>"),
              let bodyEnd = html.range(of: "</body>") else {
            return html
        }
        return String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
    }

    private static func stripRemainingTags(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return result
    }
}

// MARK: - RTF Converter

private struct HTMLToRTFConverter {
    static func convert(_ html: String, fontFamily: String = "Helvetica", fontSize: Double = 12) -> String {
        // Build RTF header with font table and Unicode support
        let rtfHeader = """
        {\\rtf1\\ansi\\ansicpg1252\\deff0
        {\\fonttbl{\\f0\\fnil \(fontFamily);}}

        """
        let rtfFooter = "\n}"

        guard let bodyContent = extractBodyContent(html) else {
            return rtfHeader + escapeRTFText(html) + rtfFooter
        }

        // IMPORTANT: We must escape text content BEFORE converting HTML tags to RTF codes.
        // Otherwise escapeRTF would destroy the RTF control characters we insert.
        // Strategy: first extract and protect HTML tags, escape the text between them,
        // then convert HTML tags to RTF codes.

        // Step 1: Escape text content between HTML tags (preserving the tags themselves)
        var escaped = escapeTextBetweenTags(bodyContent)

        // Step 2: Decode HTML entities (after escaping RTF special chars but before RTF conversion)
        escaped = decodeHTMLEntities(escaped)

        // RTF uses half-points for font size (fs = fontSize * 2)
        let baseFontSize = Int(fontSize * 2)
        let h1FontSize = Int(fontSize * 2.67)  // ~32pt for 12pt base
        let h2FontSize = Int(fontSize * 2.33)  // ~28pt for 12pt base
        let h3FontSize = Int(fontSize * 2.0)   // ~24pt for 12pt base

        var result = escaped

        // Step 3: Convert HTML tags to RTF control codes (text is already escaped)

        // Convert headings (larger font size)
        result = result.replacingOccurrences(of: "<h1>", with: "{\\b\\fs\(h1FontSize) ")
        result = result.replacingOccurrences(of: "</h1>", with: "}\\par\n")
        result = result.replacingOccurrences(of: "<h2>", with: "{\\b\\fs\(h2FontSize) ")
        result = result.replacingOccurrences(of: "</h2>", with: "}\\par\n")
        result = result.replacingOccurrences(of: "<h3>", with: "{\\b\\fs\(h3FontSize) ")
        result = result.replacingOccurrences(of: "</h3>", with: "}\\par\n")

        // Convert formatting
        result = result.replacingOccurrences(of: "<b>", with: "{\\b ")
        result = result.replacingOccurrences(of: "</b>", with: "}")
        result = result.replacingOccurrences(of: "<strong>", with: "{\\b ")
        result = result.replacingOccurrences(of: "</strong>", with: "}")
        result = result.replacingOccurrences(of: "<i>", with: "{\\i ")
        result = result.replacingOccurrences(of: "</i>", with: "}")
        result = result.replacingOccurrences(of: "<em>", with: "{\\i ")
        result = result.replacingOccurrences(of: "</em>", with: "}")
        result = result.replacingOccurrences(of: "<u>", with: "{\\ul ")
        result = result.replacingOccurrences(of: "</u>", with: "}")
        result = result.replacingOccurrences(of: "<s>", with: "{\\strike ")
        result = result.replacingOccurrences(of: "</s>", with: "}")

        // Convert lists
        result = result.replacingOccurrences(of: "<ul>", with: "")
        result = result.replacingOccurrences(of: "</ul>", with: "\\par\n")
        result = result.replacingOccurrences(of: "<ul style='list-style-type: square;'>", with: "")
        result = result.replacingOccurrences(of: "<ul style='list-style-type: none;'>", with: "")
        result = result.replacingOccurrences(of: "<ol>", with: "")
        result = result.replacingOccurrences(of: "</ol>", with: "\\par\n")
        result = result.replacingOccurrences(of: "<li>", with: "{\\pard\\li720 \\'95 ")
        result = result.replacingOccurrences(of: "</li>", with: "\\par}\n")

        // Line breaks
        result = result.replacingOccurrences(of: "<br>", with: "\\par\n")
        result = result.replacingOccurrences(of: "<br/>", with: "\\par\n")
        result = result.replacingOccurrences(of: "<br />", with: "\\par\n")

        // Strip remaining HTML tags
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Step 4: Convert non-ASCII Unicode characters to RTF unicode escapes
        result = encodeUnicode(result)

        // Apply default font and font size (RTF uses half-points)
        return rtfHeader + "\\f0\\fs\(baseFontSize) " + result + rtfFooter
    }

    private static func extractBodyContent(_ html: String) -> String? {
        guard let bodyStart = html.range(of: "<body>"),
              let bodyEnd = html.range(of: "</body>") else {
            return html
        }
        return String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
    }

    /// Escape RTF special characters in plain text (not containing RTF codes)
    private static func escapeRTFText(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "{", with: "\\{")
        result = result.replacingOccurrences(of: "}", with: "\\}")
        return encodeUnicode(result)
    }

    /// Escape RTF special characters only in text segments between HTML tags.
    /// HTML tags themselves are preserved intact for later conversion to RTF codes.
    private static func escapeTextBetweenTags(_ html: String) -> String {
        var result = ""
        var index = html.startIndex

        while index < html.endIndex {
            if html[index] == "<" {
                // Find end of tag
                if let tagEnd = html[index...].firstIndex(of: ">") {
                    // Append the tag as-is (don't escape it)
                    result.append(contentsOf: html[index...tagEnd])
                    index = html.index(after: tagEnd)
                } else {
                    // Malformed tag, escape the < and continue
                    result.append("\\<")
                    index = html.index(after: index)
                }
            } else {
                // Text content: escape RTF special characters
                let ch = html[index]
                switch ch {
                case "\\":
                    result.append("\\\\")
                case "{":
                    result.append("\\{")
                case "}":
                    result.append("\\}")
                default:
                    result.append(ch)
                }
                index = html.index(after: index)
            }
        }

        return result
    }

    /// Decode common HTML entities to their character equivalents
    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")

        // Decode numeric HTML entities (&#NNN; and &#xHHH;)
        // Decimal entities
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            // Process in reverse to preserve string indices
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[codeRange]),
                   let scalar = Unicode.Scalar(codePoint) {
                    let replacement = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: replacement)
                    }
                }
            }
        }

        // Hex entities
        if let regex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);", options: []) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: result),
                   let codePoint = UInt32(result[codeRange], radix: 16),
                   let scalar = Unicode.Scalar(codePoint) {
                    let replacement = String(Character(scalar))
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: replacement)
                    }
                }
            }
        }

        return result
    }

    /// Convert non-ASCII Unicode characters to RTF unicode escape sequences (\uN?)
    /// RTF format: \uN? where N is the signed 16-bit Unicode code point and ? is a
    /// single-byte fallback character (we use '?' as the fallback).
    /// Characters in the supplementary planes (above U+FFFF) are encoded as surrogate pairs.
    private static func encodeUnicode(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        for scalar in text.unicodeScalars {
            if scalar.value < 128 {
                // ASCII - pass through directly
                result.append(Character(scalar))
            } else if scalar.value <= 0x7FFF {
                // BMP character that fits in signed 16-bit positive
                result.append("\\u\(scalar.value)?")
            } else if scalar.value <= 0xFFFF {
                // BMP character that needs signed 16-bit representation
                // RTF uses signed Int16, so values > 32767 must be negative
                let signedValue = Int16(bitPattern: UInt16(scalar.value))
                result.append("\\u\(signedValue)?")
            } else {
                // Supplementary plane character - encode as UTF-16 surrogate pair
                let high = 0xD800 + ((scalar.value - 0x10000) >> 10)
                let low = 0xDC00 + ((scalar.value - 0x10000) & 0x3FF)
                let highSigned = Int16(bitPattern: UInt16(high))
                let lowSigned = Int16(bitPattern: UInt16(low))
                result.append("\\u\(highSigned)?\\u\(lowSigned)?")
            }
        }

        return result
    }
}

// MARK: - LaTeX Converter

private struct HTMLToLatexConverter {
    static func convert(_ html: String) -> String {
        let latexHeader = """
        \\documentclass{article}
        \\usepackage[utf8]{inputenc}
        \\usepackage{ulem}
        \\usepackage{hyperref}

        \\begin{document}

        """
        let latexFooter = "\n\\end{document}\n"

        guard let bodyContent = extractBodyContent(html) else {
            return latexHeader + escapeLatex(html) + latexFooter
        }

        var result = bodyContent

        // Convert headings
        result = result.replacingOccurrences(of: "<h1>", with: "\\section{")
        result = result.replacingOccurrences(of: "</h1>", with: "}\n")
        result = result.replacingOccurrences(of: "<h2>", with: "\\subsection{")
        result = result.replacingOccurrences(of: "</h2>", with: "}\n")
        result = result.replacingOccurrences(of: "<h3>", with: "\\subsubsection{")
        result = result.replacingOccurrences(of: "</h3>", with: "}\n")

        // Convert formatting
        result = result.replacingOccurrences(of: "<b>", with: "\\textbf{")
        result = result.replacingOccurrences(of: "</b>", with: "}")
        result = result.replacingOccurrences(of: "<i>", with: "\\textit{")
        result = result.replacingOccurrences(of: "</i>", with: "}")
        result = result.replacingOccurrences(of: "<u>", with: "\\underline{")
        result = result.replacingOccurrences(of: "</u>", with: "}")
        result = result.replacingOccurrences(of: "<s>", with: "\\sout{")
        result = result.replacingOccurrences(of: "</s>", with: "}")

        // Convert links
        result = result.replacingOccurrences(of: "<a href='([^']*)'[^>]*>([^<]*)</a>",
                                            with: "\\href{$1}{$2}",
                                            options: .regularExpression)

        // Convert lists
        result = result.replacingOccurrences(of: "<ul>", with: "\\begin{itemize}\n")
        result = result.replacingOccurrences(of: "</ul>", with: "\\end{itemize}\n")
        result = result.replacingOccurrences(of: "<ul style='list-style-type: square;'>", with: "\\begin{itemize}\n")
        result = result.replacingOccurrences(of: "<ul style='list-style-type: none;'>", with: "\\begin{itemize}\n")
        result = result.replacingOccurrences(of: "<ol>", with: "\\begin{enumerate}\n")
        result = result.replacingOccurrences(of: "</ol>", with: "\\end{enumerate}\n")
        result = result.replacingOccurrences(of: "<li>", with: "\\item ")
        result = result.replacingOccurrences(of: "</li>", with: "\n")

        // Line breaks
        result = result.replacingOccurrences(of: "<br>", with: "\\\\\n")
        result = result.replacingOccurrences(of: "<br/>", with: "\\\\\n")
        result = result.replacingOccurrences(of: "<br />", with: "\\\\\n")

        // Strip remaining HTML tags
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Escape LaTeX special characters
        result = escapeLatex(result)

        return latexHeader + result + latexFooter
    }

    private static func extractBodyContent(_ html: String) -> String? {
        guard let bodyStart = html.range(of: "<body>"),
              let bodyEnd = html.range(of: "</body>") else {
            return html
        }
        return String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
    }

    private static func escapeLatex(_ text: String) -> String {
        var result = text
        // Must escape backslash first
        result = result.replacingOccurrences(of: "\\", with: "\\textbackslash{}")
        result = result.replacingOccurrences(of: "&", with: "\\&")
        result = result.replacingOccurrences(of: "%", with: "\\%")
        result = result.replacingOccurrences(of: "$", with: "\\$")
        result = result.replacingOccurrences(of: "#", with: "\\#")
        result = result.replacingOccurrences(of: "_", with: "\\_")
        result = result.replacingOccurrences(of: "{", with: "\\{")
        result = result.replacingOccurrences(of: "}", with: "\\}")
        result = result.replacingOccurrences(of: "~", with: "\\textasciitilde{}")
        result = result.replacingOccurrences(of: "^", with: "\\textasciicircum{}")
        return result
    }
}

// MARK: - ENEX (Evernote Export) Converter

private struct HTMLToENEXConverter {
    static func convert(_ note: NotesNote) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        // ENEX uses a specific date format: yyyyMMdd'T'HHmmss'Z'
        let enexFormatter = DateFormatter()
        enexFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        enexFormatter.timeZone = TimeZone(identifier: "UTC")

        let bodyContent: String
        if let html = note.htmlBody {
            // Extract body content or use the whole thing
            if let bodyStart = html.range(of: "<body>"),
               let bodyEnd = html.range(of: "</body>") {
                bodyContent = String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
            } else {
                bodyContent = html
            }
        } else {
            bodyContent = note.plaintext.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        // Build ENEX-compatible XHTML content
        // Evernote requires en-note wrapper with specific DTD
        let enContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd">
        <en-note>\(bodyContent)</en-note>
        """

        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<!DOCTYPE en-export SYSTEM \"http://xml.evernote.com/pub/evernote-export4.dtd\">")
        lines.append("<en-export export-date=\"\(enexFormatter.string(from: Date()))\" application=\"Apple Notes Exporter\">")
        lines.append("  <note>")
        lines.append("    <title>\(HTMLToXMLConverter.escapeXML(note.title))</title>")
        lines.append("    <content><![CDATA[\(enContent)]]></content>")
        lines.append("    <created>\(enexFormatter.string(from: note.creationDate))</created>")
        lines.append("    <updated>\(enexFormatter.string(from: note.modificationDate))</updated>")
        lines.append("    <note-attributes>")
        lines.append("      <source>apple-notes-exporter</source>")
        lines.append("    </note-attributes>")
        lines.append("  </note>")
        lines.append("</en-export>")

        return lines.joined(separator: "\n")
    }
}

// MARK: - DOCX Converter

private struct HTMLToDOCXConverter {
    static func convert(_ note: NotesNote) -> Data {
        // Parse HTML body and convert to WordprocessingML with formatting
        let html = note.htmlBody ?? "<p>\(HTMLToXMLConverter.escapeXML(note.plaintext))</p>"
        let wordMLBody = HTMLToWordMLParser.parse(html: html)

        // Build the required XML files for a minimal valid DOCX
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
        \(wordMLBody)<w:sectPr>
        <w:pgSz w:w="12240" w:h="15840"/>
        <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
        </w:sectPr>
        </w:body>
        </w:document>
        """

        let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:spacing w:before="240" w:after="60"/></w:pPr><w:rPr><w:b/><w:sz w:val="48"/><w:szCs w:val="48"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:pPr><w:spacing w:before="200" w:after="60"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:pPr><w:spacing w:before="160" w:after="40"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:pPr><w:ind w:left="720"/></w:pPr></w:style>
        </w:styles>
        """

        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """

        let relsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

        let wordRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """

        let entries: [ZIPArchive.Entry] = [
            .init(path: "[Content_Types].xml", data: Data(contentTypesXML.utf8), compress: true),
            .init(path: "_rels/.rels", data: Data(relsXML.utf8), compress: true),
            .init(path: "word/_rels/document.xml.rels", data: Data(wordRelsXML.utf8), compress: true),
            .init(path: "word/document.xml", data: Data(documentXML.utf8), compress: true),
            .init(path: "word/styles.xml", data: Data(stylesXML.utf8), compress: true),
        ]

        return ZIPArchive.build(entries: entries)
    }
}

// MARK: - HTML to WordprocessingML Parser

/// Converts HTML to WordprocessingML paragraphs with formatting.
/// Handles: h1-h3, b/strong, i/em, u, s/strike, a, ul/ol/li, br, p, table/tr/td, div, pre.
/// Used by both DOCX and ODT converters (ODT has its own wrapper that calls this for structure).
private struct HTMLToWordMLParser {
    /// Active inline formatting state
    struct RunStyle {
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
    }

    /// Parse HTML and return WordprocessingML paragraph elements
    static func parse(html: String) -> String {
        // Extract body content if wrapped in full HTML document
        var content = html
        if let bodyStart = content.range(of: "<body>", options: .caseInsensitive),
           let bodyEnd = content.range(of: "</body>", options: .caseInsensitive) {
            content = String(content[bodyStart.upperBound..<bodyEnd.lowerBound])
        }
        // Strip <div class="content"> wrapper
        content = content.replacingOccurrences(of: "<div class=\"content\">", with: "")
        if content.hasSuffix("</div>") {
            content = String(content.dropLast(6))
        }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = ""
        var pos = content.startIndex
        var currentText = ""
        var style = RunStyle()
        var inParagraph = false // Track whether we're inside a <w:p>
        var inListItem = false
        var inTable = false
        var listDepth = 0
        var isOrderedList = false
        var listItemNumber = 0
        var headingLevel = 0

        // Flush accumulated text as a WordML run
        func flushRun() {
            guard !currentText.isEmpty else { return }
            let escaped = escapeXML(currentText)
            var rpr = ""
            if style.bold { rpr += "<w:b/>" }
            if style.italic { rpr += "<w:i/>" }
            if style.underline { rpr += "<w:u w:val=\"single\"/>" }
            if style.strikethrough { rpr += "<w:strike/>" }
            let rprXML = rpr.isEmpty ? "" : "<w:rPr>\(rpr)</w:rPr>"
            result += "<w:r>\(rprXML)<w:t xml:space=\"preserve\">\(escaped)</w:t></w:r>"
            currentText = ""
        }

        // Ensure we're inside a paragraph before emitting content
        func ensureParagraph() {
            if !inParagraph && !inTable {
                result += "<w:p>"
                inParagraph = true
            }
        }

        // Close current paragraph if open
        func closeParagraph() {
            flushRun()
            if inParagraph {
                result += "</w:p>\n"
                inParagraph = false
            }
        }

        while pos < content.endIndex {
            let ch = content[pos]

            if ch == "<" {
                guard let tagEnd = content[pos...].firstIndex(of: ">") else {
                    currentText.append(ch)
                    pos = content.index(after: pos)
                    continue
                }

                let tagStr = String(content[content.index(after: pos)..<tagEnd]).trimmingCharacters(in: .whitespaces)
                let tagLower = tagStr.lowercased()
                let nextPos = content.index(after: tagEnd)

                // <br>
                if tagLower == "br" || tagLower == "br/" || tagLower == "br /" {
                    flushRun()
                    ensureParagraph()
                    result += "<w:r><w:br/></w:r>"
                    pos = nextPos; continue
                }

                // Inline formatting
                if tagLower == "b" || tagLower == "strong" { flushRun(); style.bold = true }
                else if tagLower == "/b" || tagLower == "/strong" { flushRun(); style.bold = false }
                else if tagLower == "i" || tagLower == "em" { flushRun(); style.italic = true }
                else if tagLower == "/i" || tagLower == "/em" { flushRun(); style.italic = false }
                else if tagLower == "u" { flushRun(); style.underline = true }
                else if tagLower == "/u" { flushRun(); style.underline = false }
                else if tagLower == "s" || tagLower == "strike" || tagLower == "del" { flushRun(); style.strikethrough = true }
                else if tagLower == "/s" || tagLower == "/strike" || tagLower == "/del" { flushRun(); style.strikethrough = false }
                else if tagLower.hasPrefix("a ") || tagLower == "a" { flushRun(); style.underline = true }
                else if tagLower == "/a" { flushRun(); style.underline = false }

                // Headings
                else if tagLower == "h1" || tagLower == "h2" || tagLower == "h3" {
                    closeParagraph()
                    headingLevel = tagLower == "h1" ? 1 : tagLower == "h2" ? 2 : 3
                    let styleName = "Heading\(headingLevel)"
                    result += "<w:p><w:pPr><w:pStyle w:val=\"\(styleName)\"/></w:pPr>"
                    inParagraph = true
                }
                else if tagLower == "/h1" || tagLower == "/h2" || tagLower == "/h3" {
                    flushRun(); headingLevel = 0
                    result += "</w:p>\n"; inParagraph = false
                }

                // Paragraphs
                else if tagLower == "p" || tagLower.hasPrefix("p ") {
                    if !inListItem && !inTable {
                        closeParagraph()
                        result += "<w:p>"; inParagraph = true
                    }
                }
                else if tagLower == "/p" {
                    if !inListItem && !inTable {
                        flushRun()
                        result += "</w:p>\n"; inParagraph = false
                    }
                }

                // Lists
                else if tagLower == "ul" { closeParagraph(); listDepth += 1; isOrderedList = false; listItemNumber = 0 }
                else if tagLower == "/ul" { listDepth = max(0, listDepth - 1) }
                else if tagLower == "ol" { closeParagraph(); listDepth += 1; isOrderedList = true; listItemNumber = 0 }
                else if tagLower == "/ol" { listDepth = max(0, listDepth - 1); isOrderedList = false }
                else if tagLower == "li" {
                    closeParagraph(); inListItem = true; listItemNumber += 1
                    let indent = listDepth * 720
                    let bullet = isOrderedList ? "\(listItemNumber). " : "\u{2022} "
                    result += "<w:p><w:pPr><w:ind w:left=\"\(indent)\"/></w:pPr>"
                    result += "<w:r><w:t xml:space=\"preserve\">\(bullet)</w:t></w:r>"
                    inParagraph = true
                }
                else if tagLower == "/li" {
                    flushRun(); inListItem = false
                    result += "</w:p>\n"; inParagraph = false
                }

                // Tables
                else if tagLower == "table" || tagLower.hasPrefix("table ") {
                    closeParagraph(); inTable = true
                    result += "<w:tbl><w:tblPr><w:tblBorders>"
                    result += "<w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                    result += "<w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                    result += "<w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                    result += "<w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                    result += "<w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                    result += "<w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                    result += "</w:tblBorders></w:tblPr>"
                }
                else if tagLower == "/table" { flushRun(); result += "</w:tbl>\n"; inTable = false }
                else if tagLower == "tr" || tagLower.hasPrefix("tr ") { flushRun(); result += "<w:tr>" }
                else if tagLower == "/tr" { flushRun(); result += "</w:tr>" }
                else if tagLower == "td" || tagLower.hasPrefix("td ") || tagLower == "th" || tagLower.hasPrefix("th ") {
                    flushRun(); result += "<w:tc><w:p>"; inParagraph = true
                    if tagLower.hasPrefix("th") { style.bold = true }
                }
                else if tagLower == "/td" || tagLower == "/th" {
                    flushRun()
                    if tagLower == "/th" { style.bold = false }
                    result += "</w:p></w:tc>"; inParagraph = false
                }

                // Preformatted
                else if tagLower == "pre" || tagLower.hasPrefix("pre ") {
                    closeParagraph()
                    result += "<w:p><w:pPr><w:rPr><w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\"/></w:rPr></w:pPr>"
                    inParagraph = true
                }
                else if tagLower == "/pre" { flushRun(); result += "</w:p>\n"; inParagraph = false }

                // Structural: ignore
                else if tagLower.hasPrefix("div") || tagLower == "/div" { /* skip */ }

                // Images
                else if tagLower.hasPrefix("img") {
                    if let altRange = tagStr.range(of: "alt=\""),
                       let altEnd = tagStr[altRange.upperBound...].firstIndex(of: "\"") {
                        currentText += "[Image: \(String(tagStr[altRange.upperBound..<altEnd]))]"
                    } else {
                        currentText += "[Image]"
                    }
                }

                // Document structure: skip
                else if tagLower.hasPrefix("style") && !tagLower.hasSuffix("/") {
                    if let styleEnd = content[nextPos...].range(of: "</style>", options: .caseInsensitive) {
                        pos = content.index(after: styleEnd.upperBound); continue
                    }
                }
                else if tagLower == "title" {
                    if let titleEnd = content[nextPos...].range(of: "</title>", options: .caseInsensitive) {
                        pos = content.index(after: titleEnd.upperBound); continue
                    }
                }
                // else: skip unknown tags (head, meta, html, doctype, comments, etc.)

                pos = nextPos
                continue
            }

            // HTML entities
            if ch == "&" {
                if let semiIdx = content[pos...].firstIndex(of: ";") {
                    let entity = String(content[pos...semiIdx])
                    switch entity {
                    case "&amp;":  currentText += "&"
                    case "&lt;":   currentText += "<"
                    case "&gt;":   currentText += ">"
                    case "&quot;": currentText += "\""
                    case "&#39;":  currentText += "'"
                    case "&nbsp;": currentText += " "
                    default:       currentText += entity
                    }
                    pos = content.index(after: semiIdx)
                    continue
                }
            }

            // Skip \r, normalize \n to space
            if ch == "\r" { pos = content.index(after: pos); continue }
            if ch == "\n" {
                if !currentText.isEmpty && !currentText.hasSuffix(" ") { currentText += " " }
                pos = content.index(after: pos); continue
            }

            // Regular character -- ensure we're in a paragraph
            ensureParagraph()
            currentText.append(ch)
            pos = content.index(after: pos)
        }

        // Flush remaining content
        closeParagraph()

        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = "<w:p/>\n"
        }

        return result
    }

    private static func escapeXML(_ string: String) -> String {
        return HTMLToXMLConverter.escapeXML(string)
    }
}

// MARK: - ODT Converter

private struct HTMLToODTConverter {
    static func convert(_ note: NotesNote) -> Data {
        // Parse HTML body and convert to ODF content with formatting
        let html = note.htmlBody ?? "<p>\(HTMLToXMLConverter.escapeXML(note.plaintext))</p>"
        let odtBody = HTMLToODFParser.parse(html: html)

        let contentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" office:version="1.2">
        <office:automatic-styles>
        <style:style style:name="H1" style:family="paragraph"><style:text-properties fo:font-size="24pt" fo:font-weight="bold"/></style:style>
        <style:style style:name="H2" style:family="paragraph"><style:text-properties fo:font-size="18pt" fo:font-weight="bold"/></style:style>
        <style:style style:name="H3" style:family="paragraph"><style:text-properties fo:font-size="14pt" fo:font-weight="bold"/></style:style>
        <style:style style:name="Bold" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>
        <style:style style:name="Italic" style:family="text"><style:text-properties fo:font-style="italic"/></style:style>
        <style:style style:name="Underline" style:family="text"><style:text-properties style:text-underline-style="solid" style:text-underline-width="auto"/></style:style>
        <style:style style:name="Strikethrough" style:family="text"><style:text-properties style:text-line-through-style="solid"/></style:style>
        <style:style style:name="ListIndent" style:family="paragraph"><style:paragraph-properties fo:margin-left="1.27cm"/></style:style>
        <style:style style:name="Mono" style:family="text"><style:text-properties style:font-name="Courier New"/></style:style>
        </office:automatic-styles>
        <office:body>
        <office:text>
        \(odtBody)</office:text>
        </office:body>
        </office:document-content>
        """

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        let metaXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" office:version="1.2">
        <office:meta>
        <dc:title>\(HTMLToXMLConverter.escapeXML(note.title))</dc:title>
        <meta:creation-date>\(isoFormatter.string(from: note.creationDate))</meta:creation-date>
        <dc:date>\(isoFormatter.string(from: note.modificationDate))</dc:date>
        <meta:generator>Apple Notes Exporter</meta:generator>
        </office:meta>
        </office:document-meta>
        """

        let manifestXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
        <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.text"/>
        <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
        <manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/>
        </manifest:manifest>
        """

        let mimetypeData = Data("application/vnd.oasis.opendocument.text".utf8)

        let entries: [ZIPArchive.Entry] = [
            .init(path: "mimetype", data: mimetypeData, compress: false),
            .init(path: "META-INF/manifest.xml", data: Data(manifestXML.utf8), compress: true),
            .init(path: "content.xml", data: Data(contentXML.utf8), compress: true),
            .init(path: "meta.xml", data: Data(metaXML.utf8), compress: true),
        ]

        return ZIPArchive.build(entries: entries)
    }
}

// MARK: - HTML to ODF Content Parser

/// Converts HTML to OpenDocument Format text:p/text:span elements with formatting.
private struct HTMLToODFParser {
    struct RunStyle {
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false

        var isEmpty: Bool { !bold && !italic && !underline && !strikethrough }

        /// Return the text:style-name for a text:span, or nil if plain
        var styleName: String? {
            // Combine styles -- use first match for simplicity
            if bold && italic { return "Bold" } // ODF doesn't easily combine, just pick primary
            if bold { return "Bold" }
            if italic { return "Italic" }
            if underline { return "Underline" }
            if strikethrough { return "Strikethrough" }
            return nil
        }
    }

    static func parse(html: String) -> String {
        var content = html
        if let bodyStart = content.range(of: "<body>", options: .caseInsensitive),
           let bodyEnd = content.range(of: "</body>", options: .caseInsensitive) {
            content = String(content[bodyStart.upperBound..<bodyEnd.lowerBound])
        }
        content = content.replacingOccurrences(of: "<div class=\"content\">", with: "")
        if content.hasSuffix("</div>") { content = String(content.dropLast(6)) }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = ""
        var pos = content.startIndex
        var currentText = ""
        var style = RunStyle()
        var inListItem = false
        var listDepth = 0
        var isOrderedList = false
        var listItemNumber = 0
        var headingLevel = 0

        func flushSpan() {
            guard !currentText.isEmpty else { return }
            let escaped = escapeXML(currentText)
            if let sn = style.styleName {
                result += "<text:span text:style-name=\"\(sn)\">\(escaped)</text:span>"
            } else {
                result += escaped
            }
            currentText = ""
        }

        while pos < content.endIndex {
            let ch = content[pos]

            if ch == "<" {
                guard let tagEnd = content[pos...].firstIndex(of: ">") else {
                    currentText.append(ch)
                    pos = content.index(after: pos)
                    continue
                }

                let tagContent = String(content[content.index(after: pos)..<tagEnd]).trimmingCharacters(in: .whitespaces)
                let tagLower = tagContent.lowercased()
                let nextPos = content.index(after: tagEnd)

                if tagLower == "br" || tagLower == "br/" || tagLower == "br /" {
                    flushSpan()
                    result += "<text:line-break/>"
                    pos = nextPos; continue
                }

                if tagLower == "b" || tagLower == "strong" { flushSpan(); style.bold = true }
                else if tagLower == "/b" || tagLower == "/strong" { flushSpan(); style.bold = false }
                else if tagLower == "i" || tagLower == "em" { flushSpan(); style.italic = true }
                else if tagLower == "/i" || tagLower == "/em" { flushSpan(); style.italic = false }
                else if tagLower == "u" || tagLower.hasPrefix("a ") || tagLower == "a" { flushSpan(); style.underline = true }
                else if tagLower == "/u" || tagLower == "/a" { flushSpan(); style.underline = false }
                else if tagLower == "s" || tagLower == "strike" || tagLower == "del" { flushSpan(); style.strikethrough = true }
                else if tagLower == "/s" || tagLower == "/strike" || tagLower == "/del" { flushSpan(); style.strikethrough = false }
                else if tagLower == "h1" { flushSpan(); headingLevel = 1; result += "<text:p text:style-name=\"H1\">" }
                else if tagLower == "h2" { flushSpan(); headingLevel = 2; result += "<text:p text:style-name=\"H2\">" }
                else if tagLower == "h3" { flushSpan(); headingLevel = 3; result += "<text:p text:style-name=\"H3\">" }
                else if tagLower == "/h1" || tagLower == "/h2" || tagLower == "/h3" { flushSpan(); headingLevel = 0; result += "</text:p>\n" }
                else if tagLower == "p" || tagLower.hasPrefix("p ") {
                    flushSpan()
                    if !inListItem { result += "<text:p>" }
                }
                else if tagLower == "/p" {
                    flushSpan()
                    if !inListItem { result += "</text:p>\n" }
                }
                else if tagLower == "ul" { flushSpan(); listDepth += 1; isOrderedList = false; listItemNumber = 0 }
                else if tagLower == "/ul" { flushSpan(); listDepth = max(0, listDepth - 1) }
                else if tagLower == "ol" { flushSpan(); listDepth += 1; isOrderedList = true; listItemNumber = 0 }
                else if tagLower == "/ol" { flushSpan(); listDepth = max(0, listDepth - 1); isOrderedList = false }
                else if tagLower == "li" {
                    flushSpan(); inListItem = true; listItemNumber += 1
                    let bullet = isOrderedList ? "\(listItemNumber). " : "\u{2022} "
                    result += "<text:p text:style-name=\"ListIndent\">\(bullet)"
                }
                else if tagLower == "/li" { flushSpan(); inListItem = false; result += "</text:p>\n" }
                else if tagLower == "table" || tagLower.hasPrefix("table ") {
                    flushSpan()
                    result += "<table:table>"
                }
                else if tagLower == "/table" { flushSpan(); result += "</table:table>\n" }
                else if tagLower == "tr" || tagLower.hasPrefix("tr ") { flushSpan(); result += "<table:table-row>" }
                else if tagLower == "/tr" { flushSpan(); result += "</table:table-row>" }
                else if tagLower == "td" || tagLower.hasPrefix("td ") || tagLower == "th" || tagLower.hasPrefix("th ") {
                    flushSpan(); result += "<table:table-cell><text:p>"
                    if tagLower.hasPrefix("th") { style.bold = true }
                }
                else if tagLower == "/td" || tagLower == "/th" {
                    flushSpan()
                    if tagLower == "/th" { style.bold = false }
                    result += "</text:p></table:table-cell>"
                }
                else if tagLower == "pre" || tagLower.hasPrefix("pre ") { flushSpan(); result += "<text:p>" }
                else if tagLower == "/pre" { flushSpan(); result += "</text:p>\n" }
                else if tagLower.hasPrefix("img") {
                    if let altRange = tagContent.range(of: "alt=\""),
                       let altEnd = tagContent[altRange.upperBound...].firstIndex(of: "\"") {
                        currentText += "[Image: \(String(tagContent[altRange.upperBound..<altEnd]))]"
                    } else { currentText += "[Image]" }
                }
                else if tagLower.hasPrefix("style") && !tagLower.hasSuffix("/") {
                    if let styleEnd = content[nextPos...].range(of: "</style>", options: .caseInsensitive) {
                        pos = content.index(after: styleEnd.upperBound); continue
                    }
                }
                else if tagLower == "title" {
                    if let titleEnd = content[nextPos...].range(of: "</title>", options: .caseInsensitive) {
                        pos = content.index(after: titleEnd.upperBound); continue
                    }
                }
                // else: skip unknown tags

                pos = nextPos; continue
            }

            // HTML entities
            if ch == "&" {
                if let semiIdx = content[pos...].firstIndex(of: ";") {
                    let entity = String(content[pos...semiIdx])
                    switch entity {
                    case "&amp;": currentText += "&"
                    case "&lt;": currentText += "<"
                    case "&gt;": currentText += ">"
                    case "&quot;": currentText += "\""
                    case "&#39;": currentText += "'"
                    case "&nbsp;": currentText += " "
                    default: currentText += entity
                    }
                    pos = content.index(after: semiIdx); continue
                }
            }

            if ch == "\r" { pos = content.index(after: pos); continue }
            if ch == "\n" {
                if !currentText.isEmpty && !currentText.hasSuffix(" ") { currentText += " " }
                pos = content.index(after: pos); continue
            }

            currentText.append(ch)
            pos = content.index(after: pos)
        }

        if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "<text:p>"
            flushSpan()
            result += "</text:p>\n"
        }

        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = "<text:p/>\n"
        }

        return result
    }

    private static func escapeXML(_ string: String) -> String {
        return HTMLToXMLConverter.escapeXML(string)
    }
}

// MARK: - EPUB Converter

private struct HTMLToEPUBConverter {
    static func convert(_ note: NotesNote) -> Data {
        let noteId = note.id.replacingOccurrences(of: "/", with: "-")

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        isoFormatter.timeZone = TimeZone(identifier: "UTC")

        // Build XHTML chapter content
        let bodyContent: String
        if let html = note.htmlBody,
           let bodyStart = html.range(of: "<body>"),
           let bodyEnd = html.range(of: "</body>") {
            bodyContent = String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
        } else {
            bodyContent = "<p>\(HTMLToXMLConverter.escapeXML(note.plaintext))</p>"
        }

        let chapterXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
        <head>
          <meta charset="UTF-8"/>
          <title>\(HTMLToXMLConverter.escapeXML(note.title))</title>
          <style>
            body { font-family: serif; line-height: 1.4; margin: 1em; }
            h1, h2, h3 { margin-top: 1em; }
          </style>
        </head>
        <body>
          \(bodyContent)
        </body>
        </html>
        """

        // OPF package document
        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(noteId)</dc:identifier>
            <dc:title>\(HTMLToXMLConverter.escapeXML(note.title))</dc:title>
            <dc:language>en</dc:language>
            <dc:date>\(isoFormatter.string(from: note.creationDate))</dc:date>
            <meta property="dcterms:modified">\(isoFormatter.string(from: note.modificationDate))</meta>
          </metadata>
          <manifest>
            <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          </manifest>
          <spine>
            <itemref idref="chapter1"/>
          </spine>
        </package>
        """

        // Navigation document (required for EPUB 3)
        let navXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
        <head>
          <meta charset="UTF-8"/>
          <title>Table of Contents</title>
        </head>
        <body>
          <nav epub:type="toc">
            <h1>Table of Contents</h1>
            <ol>
              <li><a href="chapter1.xhtml">\(HTMLToXMLConverter.escapeXML(note.title))</a></li>
            </ol>
          </nav>
        </body>
        </html>
        """

        // Container XML
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

        let mimetypeData = Data("application/epub+zip".utf8)

        let entries: [ZIPArchive.Entry] = [
            // mimetype MUST be first entry and MUST be STORED (not compressed) per EPUB spec
            .init(path: "mimetype", data: mimetypeData, compress: false),
            .init(path: "META-INF/container.xml", data: Data(containerXML.utf8), compress: true),
            .init(path: "OEBPS/content.opf", data: Data(opfXML.utf8), compress: true),
            .init(path: "OEBPS/nav.xhtml", data: Data(navXHTML.utf8), compress: true),
            .init(path: "OEBPS/chapter1.xhtml", data: Data(chapterXHTML.utf8), compress: true),
        ]

        return ZIPArchive.build(entries: entries)
    }
}
