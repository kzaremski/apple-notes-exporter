//
//  NoteHTMLGenerator.swift
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
import OSLog

// MARK: - Note Attachment Model

/// Lightweight attachment descriptor extracted from protobuf data
struct NoteAttachment {
    let id: String
    let typeUTI: String
    let filepath: String?
}

// MARK: - Note HTML Generator

/// Generates HTML from protobuf Note objects and handles inline attachment queries.
/// Extracted from AppleNotesDatabaseParser to work with the C parser backend.
class NoteHTMLGenerator {
    private let db: OpaquePointer?  // ane_db handle for C API calls

    init(database: OpaquePointer?) {
        self.db = database
    }

    // MARK: - Public API

    /// Generate HTML for a note from its raw gzipped protobuf data.
    /// Returns nil if decompression or protobuf parsing fails.
    func generateHTML(fromProtobufData data: Data) -> String? {
        guard let decompressed = data.gunzipped() else {
            Logger.noteQuery.error("Failed to decompress gzip data")
            return nil
        }

        do {
            let proto = try NoteStoreProto(serializedBytes: decompressed)
            guard proto.hasDocument, proto.document.hasNote else {
                Logger.noteQuery.error("Protobuf has no document/note")
                return nil
            }
            return generateHTML(from: proto.document.note)
        } catch {
            Logger.noteQuery.error("Failed to parse protobuf: \(error)")
            return nil
        }
    }

    /// Extract plaintext from gzipped protobuf data.
    func extractPlaintext(fromProtobufData data: Data) -> String? {
        guard let decompressed = data.gunzipped() else { return nil }

        do {
            let proto = try NoteStoreProto(serializedBytes: decompressed)
            guard proto.hasDocument, proto.document.hasNote else { return nil }
            return proto.document.note.noteText
        } catch {
            return nil
        }
    }

    /// Extract attachment info from gzipped protobuf data.
    func extractAttachments(fromProtobufData data: Data) -> [NoteAttachment] {
        guard let decompressed = data.gunzipped() else { return [] }

        do {
            let proto = try NoteStoreProto(serializedBytes: decompressed)
            guard proto.hasDocument, proto.document.hasNote else { return [] }
            return extractAttachments(from: proto.document.note)
        } catch {
            return []
        }
    }

    // MARK: - HTML Generation (from protobuf Note)

    /// Generates HTML from a protobuf Note
    private func generateHTML(from note: Note) -> String {
        var html = "<html><body>"

        let text = note.noteText
        var currentPos = 0

        // Condense consecutive attribute runs with the same style
        var condensedRuns: [AttributeRun] = []
        var i = 0
        while i < note.attributeRun.count {
            let currentRun = note.attributeRun[i]
            var combinedLength = currentRun.length

            while i + 1 < note.attributeRun.count && isSameStyle(currentRun, note.attributeRun[i + 1]) {
                i += 1
                combinedLength += note.attributeRun[i].length
            }

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
        var listStack: [(type: Int32, indentLevel: Int32)] = []
        var currentListItemHTML = ""
        var inListItem = false

        for (_, run) in condensedRuns.enumerated() {
            let length = Int(run.length)
            let utf16View = text.utf16
            let endPos = min(currentPos + length, utf16View.count)

            guard let startIndex = utf16View.index(utf16View.startIndex, offsetBy: currentPos, limitedBy: utf16View.endIndex),
                  let endIndex = utf16View.index(utf16View.startIndex, offsetBy: endPos, limitedBy: utf16View.endIndex) else {
                currentPos = endPos
                continue
            }

            let utf16Slice = utf16View[startIndex..<endIndex]
            var segment = String(utf16Slice) ?? ""

            // Determine list item properties
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

            // Handle list nesting
            if isListItem {
                while !listStack.isEmpty && listStack.last!.indentLevel >= indentLevel &&
                      (listStack.last!.indentLevel > indentLevel || listStack.last!.type != listType) {
                    let closed = listStack.removeLast()
                    html += (closed.type == 102) ? "</ol>" : "</ul>"
                }

                while listStack.isEmpty || listStack.last!.indentLevel < indentLevel {
                    let newIndent = listStack.isEmpty ? 0 : listStack.last!.indentLevel + 1
                    if newIndent > indentLevel { break }

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
                while !listStack.isEmpty {
                    let closed = listStack.removeLast()
                    html += (closed.type == 102) ? "</ol>" : "</ul>"
                }
            }

            // Handle list items
            if isListItem {
                var styledText = segment
                var openTags: [String] = []
                var closeTags: [String] = []

                if run.fontWeight == 1 || run.fontWeight == 3 { openTags.append("<b>"); closeTags.insert("</b>", at: 0) }
                if run.fontWeight == 2 || run.fontWeight == 3 { openTags.append("<i>"); closeTags.insert("</i>", at: 0) }
                if run.underlined != 0 { openTags.append("<u>"); closeTags.insert("</u>", at: 0) }
                if run.strikethrough != 0 { openTags.append("<s>"); closeTags.insert("</s>", at: 0) }
                if !run.link.isEmpty { openTags.append("<a href='\(run.link)'>"); closeTags.insert("</a>", at: 0) }

                if run.hasAttachmentInfo {
                    styledText = processAttachmentRun(run: run)
                }

                let parts = styledText.components(separatedBy: "\n")
                for (partIndex, part) in parts.enumerated() {
                    let isLastPart = (partIndex == parts.count - 1)
                    if isLastPart && part.isEmpty { continue }

                    if !inListItem {
                        inListItem = true
                        currentListItemHTML = checkboxPrefix
                    }

                    if !part.isEmpty {
                        currentListItemHTML += openTags.joined() + part + closeTags.joined()
                    }

                    if !isLastPart {
                        html += "<li>" + currentListItemHTML + "</li>"
                        currentListItemHTML = ""
                        inListItem = false
                    }
                }
            } else {
                // Close pending list item
                if inListItem {
                    let hasContent = currentListItemHTML.trimmingCharacters(in: .whitespacesAndNewlines).count > 2
                    if hasContent { html += "<li>" + currentListItemHTML + "</li>" }
                    currentListItemHTML = ""
                    inListItem = false
                }

                // Non-list content
                var openTags: [String] = []
                var closeTags: [String] = []

                if run.hasParagraphStyle {
                    let style = run.paragraphStyle
                    switch style.styleType {
                    case 0: openTags.append("<h1>"); closeTags.insert("</h1>", at: 0)
                    case 1: openTags.append("<h2>"); closeTags.insert("</h2>", at: 0)
                    case 2: openTags.append("<h3>"); closeTags.insert("</h3>", at: 0)
                    case 4: openTags.append("<pre style='white-space: pre-wrap; font-family: monospace; background: #f5f5f5; padding: 8px; border-radius: 4px; margin: 4px 0;'>"); closeTags.insert("</pre>", at: 0)
                    default: break
                    }
                }

                if run.fontWeight == 1 || run.fontWeight == 3 { openTags.append("<b>"); closeTags.insert("</b>", at: 0) }
                if run.fontWeight == 2 || run.fontWeight == 3 { openTags.append("<i>"); closeTags.insert("</i>", at: 0) }
                if run.underlined != 0 { openTags.append("<u>"); closeTags.insert("</u>", at: 0) }
                if run.strikethrough != 0 { openTags.append("<s>"); closeTags.insert("</s>", at: 0) }
                if !run.link.isEmpty { openTags.append("<a href='\(run.link)'>"); closeTags.insert("</a>", at: 0) }

                if run.hasAttachmentInfo {
                    segment = processAttachmentRun(run: run)
                }

                html += openTags.joined() + segment.replacingOccurrences(of: "\n", with: "<br>") + closeTags.joined()
            }

            currentPos = endPos
        }

        // Close pending list items and lists
        if inListItem {
            let hasContent = currentListItemHTML.trimmingCharacters(in: .whitespacesAndNewlines).count > 2
            if hasContent { html += "<li>" + currentListItemHTML + "</li>" }
        }
        while !listStack.isEmpty {
            let closed = listStack.removeLast()
            html += (closed.type == 102) ? "</ol>" : "</ul>"
        }

        html += "</body></html>"
        return html
    }

    // MARK: - Attachment Processing

    /// Process an attachment run into HTML (marker spans or inline text)
    private func processAttachmentRun(run: AttributeRun) -> String {
        let typeUti = run.attachmentInfo.typeUti
        let attachmentId = run.attachmentInfo.attachmentIdentifier

        // Table marker
        if typeUti == "com.apple.notes.table" {
            return "<span data-attachment-id=\"\(attachmentId)\" data-attachment-type=\"\(typeUti)\">&#xFFFC;</span>"
        }
        // Image marker
        if typeUti.hasPrefix("public.image") || typeUti.hasPrefix("public.jpeg") ||
           typeUti.hasPrefix("public.png") || typeUti.hasPrefix("public.heic") {
            return "<span data-attachment-id=\"\(attachmentId)\" data-attachment-type=\"\(typeUti)\">&#xFFFC;</span>"
        }
        // Inline text attachments (hashtags, mentions, links, etc.)
        if typeUti.hasPrefix("com.apple.notes.inlinetextattachment") {
            if let inlineText = getInlineAttachmentText(uuid: attachmentId, typeUti: typeUti) {
                return inlineText
            }
            return ""
        }
        // All other file attachments
        return "<span data-attachment-id=\"\(attachmentId)\" data-attachment-type=\"\(typeUti)\">[File: \(typeUti)]</span>"
    }

    /// Query inline attachment text using the C parser API
    private func getInlineAttachmentText(uuid: String, typeUti: String) -> String? {
        guard let db = db else { return nil }

        let result = ane_fetch_inline_attachment(db, uuid)
        guard let att = result else { return nil }
        defer { ane_free_inline_attachment(att) }

        guard let altTextPtr = att.pointee.alt_text else { return nil }
        let altText = String(cString: altTextPtr)

        // For mentions and links, append the token identifier
        if typeUti == "com.apple.notes.inlinetextattachment.mention" ||
           typeUti == "com.apple.notes.inlinetextattachment.link" {
            if let tokenPtr = att.pointee.token_identifier {
                let token = String(cString: tokenPtr)
                return "\(altText) [\(token)]"
            }
        }

        return altText
    }

    // MARK: - Helpers

    /// Check if two attribute runs have the same style (for merging)
    private func isSameStyle(_ run1: AttributeRun, _ run2: AttributeRun) -> Bool {
        if run1.hasAttachmentInfo || run2.hasAttachmentInfo { return false }
        if run1.fontWeight != run2.fontWeight { return false }
        if run1.underlined != run2.underlined { return false }
        if run1.strikethrough != run2.strikethrough { return false }
        if run1.link != run2.link { return false }
        if run1.hasParagraphStyle != run2.hasParagraphStyle { return false }
        if run1.hasParagraphStyle && run2.hasParagraphStyle {
            if run1.paragraphStyle.styleType != run2.paragraphStyle.styleType { return false }
            if run1.paragraphStyle.indentAmount != run2.paragraphStyle.indentAmount { return false }
        }
        return true
    }

    /// Extract attachment info from protobuf Note
    private func extractAttachments(from note: Note) -> [NoteAttachment] {
        var attachments: [NoteAttachment] = []
        for run in note.attributeRun where run.hasAttachmentInfo {
            let info = run.attachmentInfo
            attachments.append(NoteAttachment(
                id: info.attachmentIdentifier,
                typeUTI: info.typeUti,
                filepath: nil
            ))
        }
        return attachments
    }
}
