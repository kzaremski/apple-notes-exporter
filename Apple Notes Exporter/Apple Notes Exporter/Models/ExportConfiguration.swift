//
//  ExportConfiguration.swift
//  Apple Notes Exporter
//
//  Configuration models for export formats
//

import Foundation
import HtmlToPdf

// MARK: - Base Configuration Protocol

protocol ExportConfigurable: Codable {
    static var defaultConfiguration: Self { get }
}

// MARK: - HTML Configuration

struct HTMLConfiguration: ExportConfigurable {
    var fontSizePoints: Double
    var fontFamily: FontFamily
    var marginSize: Double
    var marginUnit: MarginUnit
    var embedImagesInline: Bool
    var linkEmbeddedImages: Bool

    enum FontFamily: String, Codable, CaseIterable {
        case system = "System"
        case serif = "Serif"
        case sansSerif = "Sans-Serif"
        case monospace = "Monospace"

        var cssFontStack: String {
            switch self {
            case .system:
                return "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
            case .serif:
                return "Georgia, 'Times New Roman', Times, serif"
            case .sansSerif:
                return "Helvetica, Arial, 'Helvetica Neue', sans-serif"
            case .monospace:
                return "'SF Mono', Monaco, 'Courier New', Consolas, monospace"
            }
        }
    }

    enum MarginUnit: String, Codable, CaseIterable {
        case px, pt, em, rem, percent = "%"

        var displayName: String {
            self == .percent ? "%" : rawValue
        }
    }

    /// Convert margin settings to PDF EdgeInsets (in points)
    func toPDFEdgeInsets() -> HtmlToPdf.EdgeInsets {
        // Convert margin to points based on unit
        let marginInPoints: CGFloat
        switch marginUnit {
        case .pt:
            marginInPoints = CGFloat(marginSize)
        case .px:
            // Assuming 72 DPI: 1px ≈ 0.75pt
            marginInPoints = CGFloat(marginSize) * 0.75
        case .em, .rem:
            // Approximate: use font size as base (1em = font size)
            marginInPoints = CGFloat(marginSize * fontSizePoints)
        case .percent:
            // For PDF, percent doesn't make sense for margins
            // Default to 0.5 inches (36pt)
            marginInPoints = 36
        }

        return HtmlToPdf.EdgeInsets(
            top: marginInPoints,
            left: marginInPoints,
            bottom: marginInPoints,
            right: marginInPoints
        )
    }

    static var defaultConfiguration: HTMLConfiguration {
        HTMLConfiguration(
            fontSizePoints: 14,
            fontFamily: .system,
            marginSize: 36,  // 0.5 inches at 72 DPI
            marginUnit: .pt,
            embedImagesInline: true,
            linkEmbeddedImages: false
        )
    }
}

// MARK: - PDF Configuration

struct PDFConfiguration: ExportConfigurable {
    var htmlConfiguration: HTMLConfiguration
    var pageSize: PageSize

    enum PageSize: String, Codable, CaseIterable {
        case letter = "Letter"
        case a4 = "A4"
        case a5 = "A5"
        case legal = "Legal"
        case tabloid = "Tabloid"

        var dimensions: (width: CGFloat, height: CGFloat) {
            switch self {
            case .letter:
                return (612, 792)  // 8.5" x 11"
            case .a4:
                return (595, 842)  // 210mm x 297mm
            case .a5:
                return (420, 595)  // 148mm x 210mm
            case .legal:
                return (612, 1008) // 8.5" x 14"
            case .tabloid:
                return (792, 1224) // 11" x 17"
            }
        }
    }

    static var defaultConfiguration: PDFConfiguration {
        // Locale-aware default: Letter for US, A4 for rest of world
        let defaultPageSize: PageSize = Locale.current.regionCode == "US" ? .letter : .a4

        return PDFConfiguration(
            htmlConfiguration: .defaultConfiguration,
            pageSize: defaultPageSize
        )
    }
}

// MARK: - LaTeX Configuration

struct LaTeXConfiguration: ExportConfigurable {
    var template: String

    static var defaultConfiguration: LaTeXConfiguration {
        LaTeXConfiguration(template: defaultTemplate)
    }

    static let defaultTemplate = """
\\documentclass[11pt,a4paper]{article}
\\usepackage[utf8]{inputenc}
\\usepackage[T1]{fontenc}
\\usepackage{lmodern}
\\usepackage{geometry}
\\usepackage{graphicx}
\\usepackage{hyperref}
\\usepackage{xcolor}

\\geometry{margin=1in}

\\title{APPLE_NOTES_EXPORTER_NOTE_TITLE}
\\author{APPLE_NOTES_EXPORTER_USER_FULL_NAME}
\\date{APPLE_NOTES_EXPORTER_NOTE_MODIFICATION_DATE}

\\begin{document}

\\maketitle

APPLE_NOTES_EXPORTER_NOTE_CONTENT

\\vfill
\\footnotesize
Created: APPLE_NOTES_EXPORTER_NOTE_CREATION_DATE

\\end{document}
"""

    // Available placeholders for template
    static let placeholders = [
        "APPLE_NOTES_EXPORTER_NOTE_CONTENT",
        "APPLE_NOTES_EXPORTER_NOTE_TITLE",
        "APPLE_NOTES_EXPORTER_NOTE_CREATION_DATE",
        "APPLE_NOTES_EXPORTER_NOTE_MODIFICATION_DATE",
        "APPLE_NOTES_EXPORTER_USER_FULL_NAME"
    ]
}

// MARK: - RTF Configuration

struct RTFConfiguration: ExportConfigurable {
    var fontFamily: FontFamily
    var fontSizePoints: Double

    enum FontFamily: String, Codable, CaseIterable {
        case system = "System"
        case serif = "Serif"
        case sansSerif = "Sans-Serif"
        case monospace = "Monospace"

        var rtfFontName: String {
            switch self {
            case .system:
                return "Helvetica"
            case .serif:
                return "Times New Roman"
            case .sansSerif:
                return "Helvetica"
            case .monospace:
                return "Courier New"
            }
        }
    }

    static var defaultConfiguration: RTFConfiguration {
        RTFConfiguration(fontFamily: .system, fontSizePoints: 12)
    }
}

// MARK: - Export Configuration Container

struct ExportConfigurations: Codable {
    var html: HTMLConfiguration
    var pdf: PDFConfiguration
    var latex: LaTeXConfiguration
    var rtf: RTFConfiguration

    static var `default`: ExportConfigurations {
        ExportConfigurations(
            html: .defaultConfiguration,
            pdf: .defaultConfiguration,
            latex: .defaultConfiguration,
            rtf: .defaultConfiguration
        )
    }

    // MARK: - UserDefaults Persistence

    private static let userDefaultsKey = "ExportConfigurations"

    static func load() -> ExportConfigurations {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let configurations = try? JSONDecoder().decode(ExportConfigurations.self, from: data) else {
            return .default
        }
        return configurations
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
