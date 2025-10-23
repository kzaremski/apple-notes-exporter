//
//  NotesNote+Export.swift
//  Apple Notes Exporter
//
//  Export format converters for NotesNote
//  Converts HTML body to various export formats
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
        // Build RTF header with font table
        let rtfHeader = """
        {\\rtf1\\ansi\\deff0
        {\\fonttbl{\\f0\\fnil \(fontFamily);}}

        """
        let rtfFooter = "\n}"

        guard let bodyContent = extractBodyContent(html) else {
            return rtfHeader + escapeRTF(html) + rtfFooter
        }

        var result = bodyContent

        // RTF uses half-points for font size (fs = fontSize * 2)
        let baseFontSize = Int(fontSize * 2)
        let h1FontSize = Int(fontSize * 2.67)  // ~32pt for 12pt base
        let h2FontSize = Int(fontSize * 2.33)  // ~28pt for 12pt base
        let h3FontSize = Int(fontSize * 2.0)   // ~24pt for 12pt base

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
        result = result.replacingOccurrences(of: "<i>", with: "{\\i ")
        result = result.replacingOccurrences(of: "</i>", with: "}")
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

        // Escape RTF special characters
        result = escapeRTF(result)

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

    private static func escapeRTF(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "{", with: "\\{")
        result = result.replacingOccurrences(of: "}", with: "\\}")
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
