//
//  ExportConfiguration.swift
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
    /// Write index.html in each exported HTML folder so the tree is browsable.
    var writeFolderIndexes: Bool

    enum CodingKeys: String, CodingKey {
        case fontSizePoints, fontFamily, marginSize, marginUnit
        case embedImagesInline, linkEmbeddedImages, writeFolderIndexes
    }

    init(
        fontSizePoints: Double,
        fontFamily: FontFamily,
        marginSize: Double,
        marginUnit: MarginUnit,
        embedImagesInline: Bool,
        linkEmbeddedImages: Bool,
        writeFolderIndexes: Bool = false
    ) {
        self.fontSizePoints = fontSizePoints
        self.fontFamily = fontFamily
        self.marginSize = marginSize
        self.marginUnit = marginUnit
        self.embedImagesInline = embedImagesInline
        self.linkEmbeddedImages = linkEmbeddedImages
        self.writeFolderIndexes = writeFolderIndexes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSizePoints = try c.decode(Double.self, forKey: .fontSizePoints)
        fontFamily = try c.decode(FontFamily.self, forKey: .fontFamily)
        marginSize = try c.decode(Double.self, forKey: .marginSize)
        marginUnit = try c.decode(MarginUnit.self, forKey: .marginUnit)
        embedImagesInline = try c.decodeIfPresent(Bool.self, forKey: .embedImagesInline) ?? true
        linkEmbeddedImages = try c.decodeIfPresent(Bool.self, forKey: .linkEmbeddedImages) ?? false
        writeFolderIndexes = try c.decodeIfPresent(Bool.self, forKey: .writeFolderIndexes) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontSizePoints, forKey: .fontSizePoints)
        try c.encode(fontFamily, forKey: .fontFamily)
        try c.encode(marginSize, forKey: .marginSize)
        try c.encode(marginUnit, forKey: .marginUnit)
        try c.encode(embedImagesInline, forKey: .embedImagesInline)
        try c.encode(linkEmbeddedImages, forKey: .linkEmbeddedImages)
        try c.encode(writeFolderIndexes, forKey: .writeFolderIndexes)
    }

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

    /// Convert margin settings to NSEdgeInsets (in points) for CSS calculations
    func toNSEdgeInsets() -> NSEdgeInsets {
        // Convert margin to points based on unit (same logic as toPDFEdgeInsets)
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

        return NSEdgeInsets(
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
            linkEmbeddedImages: false,
            writeFolderIndexes: false
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

    /// Page sizes as named on the command line, case-insensitively.
    ///
    /// Shared by the PDF and Vector PDF exports so `--page-size legal` means
    /// the same thing whichever one is running.
    static func pageSize(argument: String) -> PageSize? {
        PageSize.allCases.first { $0.rawValue.lowercased() == argument.lowercased() }
    }

    static var advertisedPageSizes: String {
        PageSize.allCases.map { $0.rawValue.lowercased() }.joined(separator: ", ")
    }

    static var defaultConfiguration: PDFConfiguration {
        // Locale-aware default: Letter for US, A4 for rest of world
        let isUS: Bool
        if #available(macOS 13, *) {
            isUS = Locale.current.region?.identifier == "US"
        } else {
            isUS = Locale.current.regionCode == "US"
        }
        let defaultPageSize: PageSize = isUS ? .letter : .a4

        return PDFConfiguration(
            htmlConfiguration: .defaultConfiguration,
            pageSize: defaultPageSize
        )
    }
}

// MARK: - Vector PDF Configuration

/// Settings for vector handwriting export.
///
/// Deliberately not a `PDFConfiguration`: nothing in this path renders HTML, so
/// the font, margin-unit and image-embedding knobs the HTML-to-PDF pipeline
/// needs have no meaning here, and the two would only be confusing if merged.
struct PDFVectorConfiguration: ExportConfigurable {
    var pageSize: PDFConfiguration.PageSize
    var orientation: Orientation
    /// Page margin in points.
    var margin: Double
    /// Trim the blank canvas around writing and scale what is left to the
    /// full text width. This is what makes the handwriting bigger on the page
    /// than it was in Notes rather than smaller.
    var maximizeContent: Bool
    /// Break pages between strokes instead of at a fixed offset, so no line of
    /// writing is cut in half.
    var avoidSplittingStrokes: Bool
    /// Ceiling on the magnification `maximizeContent` applies, so a two-word
    /// note does not fill a page with two enormous words.
    var maximumScale: Double
    /// How much canvas each page carries.
    var splitMode: SplitMode
    /// Which iPad the `.iPadScreen` split imitates.
    var iPadModel: IPadModel
    var iPadOrientation: Orientation

    enum Orientation: String, Codable, CaseIterable {
        case portrait = "Portrait"
        case landscape = "Landscape"
    }

    enum SplitMode: String, Codable, CaseIterable {
        /// Fill each sheet of paper with as much writing as it holds. The
        /// right choice for Letter or A4: nothing is wasted.
        case fitPage = "Fit Page"
        /// Give each page exactly one iPad screen's worth of canvas, so the
        /// pages break where they would on the iPad the note was written on.
        /// Leaves bands of white when the paper is a different shape.
        case iPadScreen = "iPad Screen"

        var displayName: String { rawValue }

        var blurb: String {
            switch self {
            case .fitPage:
                return "Fit as much writing on each page as it will hold."
            case .iPadScreen:
                return "One iPad screen of canvas per page, letterboxed to fit the paper."
            }
        }
    }

    /// Screen sizes in logical points. Exact values differ a little between
    /// models; only the shape matters here, since the page is scaled to it.
    enum IPadModel: String, Codable, CaseIterable {
        case elevenInch = "11-inch"
        case thirteenInch = "13-inch"

        var points: (width: Double, height: Double) {
            switch self {
            case .elevenInch:   return (834, 1194)
            case .thirteenInch: return (1024, 1366)
            }
        }

        var displayName: String { rawValue }
    }

    /// Page dimensions with the orientation applied.
    var pageDimensions: (width: CGFloat, height: CGFloat) {
        let base = pageSize.dimensions
        switch orientation {
        case .portrait:  return base
        case .landscape: return (base.height, base.width)
        }
    }

    enum CodingKeys: String, CodingKey {
        case pageSize, orientation, margin, maximizeContent, avoidSplittingStrokes, maximumScale
        case splitMode, iPadModel, iPadOrientation
    }

    init(pageSize: PDFConfiguration.PageSize,
         orientation: Orientation = .portrait,
         margin: Double = 28,
         maximizeContent: Bool = true,
         avoidSplittingStrokes: Bool = true,
         maximumScale: Double = 4,
         splitMode: SplitMode = .fitPage,
         iPadModel: IPadModel = .elevenInch,
         iPadOrientation: Orientation = .portrait) {
        self.pageSize = pageSize
        self.orientation = orientation
        self.margin = margin
        self.maximizeContent = maximizeContent
        self.avoidSplittingStrokes = avoidSplittingStrokes
        self.maximumScale = maximumScale
        self.splitMode = splitMode
        self.iPadModel = iPadModel
        self.iPadOrientation = iPadOrientation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageSize = try c.decodeIfPresent(PDFConfiguration.PageSize.self, forKey: .pageSize)
            ?? PDFVectorConfiguration.defaultConfiguration.pageSize
        orientation = try c.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .portrait
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? 28
        maximizeContent = try c.decodeIfPresent(Bool.self, forKey: .maximizeContent) ?? true
        avoidSplittingStrokes = try c.decodeIfPresent(Bool.self, forKey: .avoidSplittingStrokes) ?? true
        maximumScale = try c.decodeIfPresent(Double.self, forKey: .maximumScale) ?? 4
        splitMode = try c.decodeIfPresent(SplitMode.self, forKey: .splitMode) ?? .fitPage
        iPadModel = try c.decodeIfPresent(IPadModel.self, forKey: .iPadModel) ?? .elevenInch
        iPadOrientation = try c.decodeIfPresent(Orientation.self, forKey: .iPadOrientation) ?? .portrait
    }

    static var defaultConfiguration: PDFVectorConfiguration {
        PDFVectorConfiguration(pageSize: PDFConfiguration.defaultConfiguration.pageSize)
    }

    /// How a `--split` argument names a split. One token carries the mode and,
    /// for the iPad splits, which iPad and which way up, because those three
    /// are only meaningful together.
    enum SplitToken: String, CaseIterable {
        case fitPage = "fit-page"
        case iPad11Portrait = "ipad-11-portrait"
        case iPad11Landscape = "ipad-11-landscape"
        case iPad13Portrait = "ipad-13-portrait"
        case iPad13Landscape = "ipad-13-landscape"

        /// Accepts the advertised spelling plus the obvious short forms. The
        /// CLI switches over arbitrary user text, so this cannot be
        /// exhaustive; `advertisedTokens` is what we print.
        init?(argument: String) {
            switch argument.lowercased() {
            case "fit-page", "fit", "page":     self = .fitPage
            case "ipad-11-portrait", "ipad-11": self = .iPad11Portrait
            case "ipad-11-landscape":           self = .iPad11Landscape
            case "ipad-13-portrait", "ipad-13": self = .iPad13Portrait
            case "ipad-13-landscape":           self = .iPad13Landscape
            default:                            return nil
            }
        }

        /// Derived rather than written out, so a token added here reaches the
        /// help text and the error message without being listed again.
        static var advertisedTokens: String {
            allCases.map(\.rawValue).joined(separator: ", ")
        }
    }

    /// Adopt the split a token names.
    ///
    /// Exhaustive on purpose: a token added to `SplitToken` has to say what it
    /// means here rather than silently falling back to filling the page.
    mutating func apply(_ token: SplitToken) {
        switch token {
        case .fitPage:
            splitMode = .fitPage
        case .iPad11Portrait:
            splitMode = .iPadScreen; iPadModel = .elevenInch;   iPadOrientation = .portrait
        case .iPad11Landscape:
            splitMode = .iPadScreen; iPadModel = .elevenInch;   iPadOrientation = .landscape
        case .iPad13Portrait:
            splitMode = .iPadScreen; iPadModel = .thirteenInch; iPadOrientation = .portrait
        case .iPad13Landscape:
            splitMode = .iPadScreen; iPadModel = .thirteenInch; iPadOrientation = .landscape
        }
    }

    /// Height-to-width ratio of one page of canvas, or nil to fill the page.
    var sliceAspectRatio: Double? {
        guard splitMode == .iPadScreen else { return nil }
        let screen = iPadModel.points
        switch iPadOrientation {
        case .portrait:  return screen.height / screen.width
        case .landscape: return screen.width / screen.height
        }
    }

    /// Bridge to the renderer, which knows nothing about user defaults.
    ///
    /// Values are clamped here rather than trusted: the GUI steppers keep them
    /// sane, but the CLI, MCP and Shortcuts all reach the same settings, and a
    /// margin wider than half the page would leave a negative text column.
    func renderOptions() -> PaperVectorPDFOptions {
        let size = pageDimensions
        let safeMargin = max(0, min(margin, Double(min(size.width, size.height)) / 3))
        return PaperVectorPDFOptions(
            pageSize: CGSize(width: size.width, height: size.height),
            margin: safeMargin,
            maximizeContent: maximizeContent,
            cropToContent: maximizeContent,
            breakAtWhitespace: avoidSplittingStrokes,
            maximumScale: max(1, maximumScale),
            sliceAspectRatio: sliceAspectRatio
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

// MARK: - Filename Date Format

enum FilenameDateFormat: String, Codable, CaseIterable {
    case iso = "yyyy-MM-dd"
    case isoTime = "yyyy-MM-dd HHmm"
    case usDate = "MM-dd-yyyy"
    case usDateTime = "MM-dd-yyyy HHmm"
    case euDate = "dd-MM-yyyy"
    case euDateTime = "dd-MM-yyyy HHmm"

    var displayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = rawValue
        let example = formatter.string(from: Date())
        return "\(rawValue) (\(example))"
    }
}

// MARK: - Export Configuration Container

/// Where and how an export is delivered: a layout (one tree of files, or one
/// joined file) inside a container (a plain folder, or an archive).
///
/// The two axes are independent. A single joined file inside a .zip is a
/// supported combination, so they cannot be collapsed into one enum.
struct ExportDestination: Codable, Equatable {
    enum Layout: String, Codable, CaseIterable {
        case tree
        case singleFile
    }

    enum Container: String, Codable, CaseIterable {
        case folder
        case zip
        case tar
    }

    var layout: Layout = .tree
    var container: Container = .folder

    /// Exhaustive: a fourth container has to state its archive format rather
    /// than silently resolving to "no archive".
    var archiveFormat: ExportArchiveFormat? {
        switch container {
        case .folder: return nil
        case .zip:    return .zip
        case .tar:    return .tar
        }
    }

    var isConcatenated: Bool { layout == .singleFile }
}

struct ExportConfigurations: Codable {
    var html: HTMLConfiguration
    var pdf: PDFConfiguration
    var pdfVector: PDFVectorConfiguration
    var latex: LaTeXConfiguration
    var rtf: RTFConfiguration

    // General export options
    var addDateToFilename: Bool = false
    var filenameDateFormat: FilenameDateFormat = .iso
    var includeAttachments: Bool = true
    /// When true, write every attachment under <output>/Attachments/ instead of
    /// a per-note " (Attachments)" folder beside the note file.
    var sharedAttachmentsFolder: Bool = false
    var incrementalSync: Bool = false

    /// How the export is delivered.
    ///
    /// Replaces three independent booleans that could express nonsense
    /// (`zipOutput && tarOutput`) and that four separate places each derived a
    /// precedence from by hand. It is deliberately two axes rather than one
    /// list of destinations: `--zip --concatenate` is a supported combination,
    /// one joined file inside an archive, which a single four-case enum would
    /// have made unrepresentable.
    var destination: ExportDestination = ExportDestination()

    // The booleans stay as accessors so call sites keep reading naturally,
    // but they now project a state that cannot be self-contradictory.

    var concatenateOutput: Bool {
        get { destination.layout == .singleFile }
        set { destination.layout = newValue ? .singleFile : .tree }
    }

    /// Deliver the export as a single .zip instead of a folder tree.
    var zipOutput: Bool {
        get { destination.container == .zip }
        set {
            if newValue { destination.container = .zip }
            else if destination.container == .zip { destination.container = .folder }
        }
    }

    /// Deliver the export as a single .tar instead of a folder tree.
    var tarOutput: Bool {
        get { destination.container == .tar }
        set {
            if newValue { destination.container = .tar }
            else if destination.container == .tar { destination.container = .folder }
        }
    }

    /// The archive being produced, or nil when writing a folder tree.
    var archiveFormat: ExportArchiveFormat? { destination.archiveFormat }

    static var `default`: ExportConfigurations {
        ExportConfigurations(
            html: .defaultConfiguration,
            pdf: .defaultConfiguration,
            pdfVector: .defaultConfiguration,
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

    enum CodingKeys: String, CodingKey {
        case html, pdf, pdfVector, latex, rtf
        case addDateToFilename, filenameDateFormat, includeAttachments
        case sharedAttachmentsFolder, incrementalSync
        case destination
        // Read-only now: settings saved before the destination became one
        // value still decode. Nothing writes them any more.
        case concatenateOutput, zipOutput, tarOutput
    }

    init(html: HTMLConfiguration, pdf: PDFConfiguration,
         pdfVector: PDFVectorConfiguration = .defaultConfiguration,
         latex: LaTeXConfiguration, rtf: RTFConfiguration,
         addDateToFilename: Bool = false, filenameDateFormat: FilenameDateFormat = .iso,
         includeAttachments: Bool = true, sharedAttachmentsFolder: Bool = false,
         concatenateOutput: Bool = false, incrementalSync: Bool = false,
         zipOutput: Bool = false, tarOutput: Bool = false) {
        self.html = html
        self.pdf = pdf
        self.pdfVector = pdfVector
        self.latex = latex
        self.rtf = rtf
        self.addDateToFilename = addDateToFilename
        self.filenameDateFormat = filenameDateFormat
        self.includeAttachments = includeAttachments
        self.sharedAttachmentsFolder = sharedAttachmentsFolder
        self.concatenateOutput = concatenateOutput
        self.incrementalSync = incrementalSync
        self.zipOutput = zipOutput
        self.tarOutput = tarOutput
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        html = try c.decode(HTMLConfiguration.self, forKey: .html)
        pdf = try c.decode(PDFConfiguration.self, forKey: .pdf)
        // Added after the first release, so settings saved by an older build
        // decode without it.
        pdfVector = try c.decodeIfPresent(PDFVectorConfiguration.self, forKey: .pdfVector) ?? .defaultConfiguration
        latex = try c.decode(LaTeXConfiguration.self, forKey: .latex)
        rtf = try c.decode(RTFConfiguration.self, forKey: .rtf)
        addDateToFilename = try c.decodeIfPresent(Bool.self, forKey: .addDateToFilename) ?? false
        filenameDateFormat = try c.decodeIfPresent(FilenameDateFormat.self, forKey: .filenameDateFormat) ?? .iso
        includeAttachments = try c.decodeIfPresent(Bool.self, forKey: .includeAttachments) ?? true
        sharedAttachmentsFolder = try c.decodeIfPresent(Bool.self, forKey: .sharedAttachmentsFolder) ?? false
        incrementalSync = try c.decodeIfPresent(Bool.self, forKey: .incrementalSync) ?? false

        // Prefer the current key; fall back to the three legacy booleans so a
        // ZIP or Single File choice saved by an earlier build survives.
        if let stored = try c.decodeIfPresent(ExportDestination.self, forKey: .destination) {
            destination = stored
        } else {
            let legacyZip = try c.decodeIfPresent(Bool.self, forKey: .zipOutput) ?? false
            let legacyTar = try c.decodeIfPresent(Bool.self, forKey: .tarOutput) ?? false
            let legacySingle = try c.decodeIfPresent(Bool.self, forKey: .concatenateOutput) ?? false
            destination = ExportDestination(
                layout: legacySingle ? .singleFile : .tree,
                // zip won over tar when both were somehow set, so preserve that.
                container: legacyZip ? .zip : (legacyTar ? .tar : .folder)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(html, forKey: .html)
        try c.encode(pdf, forKey: .pdf)
        try c.encode(pdfVector, forKey: .pdfVector)
        try c.encode(latex, forKey: .latex)
        try c.encode(rtf, forKey: .rtf)
        try c.encode(addDateToFilename, forKey: .addDateToFilename)
        try c.encode(filenameDateFormat, forKey: .filenameDateFormat)
        try c.encode(includeAttachments, forKey: .includeAttachments)
        try c.encode(sharedAttachmentsFolder, forKey: .sharedAttachmentsFolder)
        try c.encode(incrementalSync, forKey: .incrementalSync)
        // One key, one source of truth. The legacy booleans are still decoded
        // above but are no longer written, so they cannot come back and
        // contradict the destination.
        try c.encode(destination, forKey: .destination)
    }
}
