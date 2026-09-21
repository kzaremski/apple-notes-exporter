//
//  PaperVectorTests.swift
//  Apple Notes ExporterTests
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

import XCTest
import CoreGraphics
@testable import Apple_Notes_Exporter

final class PaperVectorTests: XCTestCase {

    // MARK: - Stroke point layout
    //
    // The per-point blob has no length prefix per attribute: everything hangs
    // off the two bitmasks and this width table. Getting a width wrong shifts
    // every attribute after it, which does not fail loudly -- it renders the
    // handwriting as hairlines, or silently drops the stroke because the
    // derived stride no longer divides the blob.

    /// Each case is (per-point mask, constant mask, stride, constants length)
    /// as observed in a real library. Together they over-determine the twelve
    /// attribute widths, so any change to the table breaks several at once.
    private static let observedLayouts: [(mask: Int, constantMask: Int, stride: Int, constantLength: Int)] = [
        (1, 1022, 8, 24),       // location only; everything else constant
        (3, 2044, 12, 22),      // the common pen stroke: location + time
        (7, 1016, 16, 16),      // location + time + size
        (35, 988, 14, 18),
        (39, 984, 18, 14),      // location + time + size + one quantized
        (67, 956, 14, 18),
        (99, 924, 16, 16),
        (103, 920, 20, 12),
        (131, 892, 14, 18),
        (163, 860, 16, 16),
        (167, 856, 20, 12),
        (195, 828, 16, 16),
        (227, 796, 18, 14),
        (231, 792, 22, 10),     // every quantized attribute varies
        (291, 732, 16, 16),
        (355, 668, 18, 14),
        (483, 540, 20, 12),
        (495, 528, 26, 6),      // a marker stroke
        (551, 472, 22, 10),
        (615, 408, 24, 8),
        (743, 280, 26, 6),
        (3, 4092, 12, 26),      // the widest constants blob seen
    ]

    func test_pointLayout_derivesTheStrideEveryRealStrokeWasWrittenWith() {
        for layout in Self.observedLayouts {
            let derived = PaperBundleReader.layout(mask: layout.mask, constantMask: layout.constantMask)
            XCTAssertEqual(
                derived.stride, layout.stride,
                "mask \(layout.mask): stride \(derived.stride), expected \(layout.stride)"
            )
            let constantLength = derived.constant.values.max().map { maxOffset -> Int in
                let lastBit = derived.constant.first { $0.value == maxOffset }!.key
                return maxOffset + PaperBundleReader.PointAttribute.widths[lastBit]
            } ?? 0
            XCTAssertEqual(
                constantLength, layout.constantLength,
                "mask \(layout.mask): constants \(constantLength), expected \(layout.constantLength)"
            )
        }
    }

    func test_pointLayout_findsSizeInTheConstantsWhenItDoesNotVary() {
        // A stroke drawn at an even pressure stores its width once. Time comes
        // before it in the constants blob whenever time is constant too, so
        // reading size from offset zero is only right by accident.
        let varying = PaperBundleReader.layout(mask: 39, constantMask: 984)
        XCTAssertEqual(varying.perPoint[PaperBundleReader.PointAttribute.size], 12)
        XCTAssertNil(varying.constant[PaperBundleReader.PointAttribute.size])

        let constantSize = PaperBundleReader.layout(mask: 3, constantMask: 2044)
        XCTAssertNil(constantSize.perPoint[PaperBundleReader.PointAttribute.size])
        XCTAssertEqual(constantSize.constant[PaperBundleReader.PointAttribute.size], 0)

        // Location-only: time is constant as well and leads the blob, so size
        // sits four bytes in.
        let timeAlsoConstant = PaperBundleReader.layout(mask: 1, constantMask: 1022)
        XCTAssertEqual(timeAlsoConstant.constant[PaperBundleReader.PointAttribute.size], 4)
    }

    // MARK: - Stroke outline

    func test_outline_capsTheEndsOfAStrokeInsteadOfBitingIntoThem() throws {
        // Regression: the caps were drawn with `CGContext.addArc`, whose
        // `clockwise` flag is read relative to the current transform. The page
        // context is y-flipped to put the canvas the right way up, which
        // inverts it, so each cap swept back through the body of the stroke
        // rather than past its tip. The fill then cancelled along the overlap
        // and took a crescent out of both ends of every stroke -- about a
        // quarter of its ink.
        let width = 20.0
        let stroke = (0 ... 10).map { PaperStrokePoint(x: 60 + Double($0) * 12, y: 60, width: width) }

        let size = (width: 240, height: 120)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size.width, height: size.height,
            bitsPerComponent: 8, bytesPerRow: size.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        PaperVectorPDF.addOutline(of: stroke, to: context)
        context.fillPath()

        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func inked(_ x: Int, _ y: Int) -> Bool { pixels[(y * size.width + x) * 4] < 128 }

        // A round cap is a half-disk centred on the end point, so the end
        // point and the tip half a width beyond it are both inside the ink.
        XCTAssertTrue(inked(60, 60), "the first point of the stroke is not inked")
        XCTAssertTrue(inked(180, 60), "the last point of the stroke is not inked")
        XCTAssertTrue(inked(52, 60), "the start cap does not reach the tip")
        XCTAssertTrue(inked(188, 60), "the end cap does not reach the tip")
        XCTAssertFalse(inked(46, 60), "ink past the start cap's radius")
        XCTAssertFalse(inked(194, 60), "ink past the end cap's radius")

        // And the total area is a rectangle plus the two half-disks.
        var inkedPixels = 0
        for y in 0 ..< size.height {
            for x in 0 ..< size.width where inked(x, y) { inkedPixels += 1 }
        }
        let expected = 120.0 * width + Double.pi * (width / 2) * (width / 2)
        XCTAssertEqual(Double(inkedPixels) / expected, 1, accuracy: 0.05,
                       "filled area does not match a rectangle plus two round caps")
    }

    // MARK: - Pagination

    /// `lines` horizontal strokes, one per 100pt of canvas, each 400pt wide.
    private func ruledDocument(lines: Int) -> PaperDocument {
        var strokes: [PaperStroke] = []
        for line in 0 ..< lines {
            let y = Double(line) * 100 + 50
            let points = (0 ... 8).map {
                PaperStrokePoint(x: 100 + Double($0) * 50, y: y, width: 3)
            }
            strokes.append(PaperStroke(points: points, color: (0, 0, 0, 1),
                                       inkIdentifier: "com.apple.ink.pen", transform: .identity))
        }
        return PaperDocument(bounds: CGRect(x: 0, y: 0, width: 768, height: Double(lines) * 100 + 100),
                             strokes: strokes, images: [])
    }

    private func renderURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("paper-vector-\(UUID().uuidString).pdf")
    }

    func test_write_splitsATallCanvasAcrossPages() throws {
        let url = renderURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let pages = try PaperVectorPDF.write(ruledDocument(lines: 60), to: url, title: "Tall")
        XCTAssertGreaterThan(pages, 1, "a 6000pt canvas has to span more than one page")

        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(document.numberOfPages, pages)
    }

    func test_write_drawsEveryStrokeExactlyOnce() throws {
        // Pages are packed by top edge rather than sliced at a fixed offset, so
        // the bug to guard against is a stroke landing on two pages (drawn
        // twice, cut in half on both) or on none.
        let url = renderURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let document = ruledDocument(lines: 60)
        try PaperVectorPDF.write(document, to: url, title: "Tall")

        let pdf = try XCTUnwrap(CGPDFDocument(url as CFURL))
        var drawn = 0
        for index in 1 ... pdf.numberOfPages {
            drawn += Self.fillOperatorCount(in: try XCTUnwrap(pdf.page(at: index)))
        }
        XCTAssertEqual(drawn, document.strokes.count)
    }

    func test_write_isVectorRatherThanAnImage() throws {
        let url = renderURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try PaperVectorPDF.write(ruledDocument(lines: 4), to: url, title: "Short")
        let raw = try Data(contentsOf: url)
        // The whole point of this exporter: no rasterised ink anywhere.
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("/Subtype /Image"),
                       "handwriting was rasterised into the PDF")
    }

    func test_write_sliceShapeDecidesHowMuchCanvasEachPageCarries() throws {
        // The slice ratio is height-over-width, so a landscape iPad asks for a
        // short wide band and needs more pages than an upright one.
        let document = ruledDocument(lines: 60)

        let portraitURL = renderURL()
        let landscapeURL = renderURL()
        defer {
            try? FileManager.default.removeItem(at: portraitURL)
            try? FileManager.default.removeItem(at: landscapeURL)
        }

        var portrait = PaperVectorPDFOptions.default
        portrait.sliceAspectRatio = 1194.0 / 834.0        // 11-inch, upright
        let portraitPages = try PaperVectorPDF.write(document, to: portraitURL, title: "Portrait", options: portrait)

        var landscape = PaperVectorPDFOptions.default
        landscape.sliceAspectRatio = 834.0 / 1194.0       // 11-inch, on its side
        let landscapePages = try PaperVectorPDF.write(document, to: landscapeURL, title: "Landscape", options: landscape)

        XCTAssertGreaterThan(landscapePages, portraitPages)
    }

    func test_write_refusesAnEmptyCanvas() {
        // Blank paper attachments are common -- Notes creates one whenever a
        // note is started with the pencil and abandoned. The caller uses this
        // to fall back to the ordinary PDF pipeline.
        let url = renderURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let empty = PaperDocument(bounds: CGRect(x: 0, y: 0, width: 768, height: 128),
                                  strokes: [], images: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertThrowsError(try PaperVectorPDF.write(empty, to: url, title: "Blank"))
    }

    func test_strokeTransform_scalesThePenWidthWithTheGeometry() {
        let points = [PaperStrokePoint(x: 0, y: 0, width: 4),
                      PaperStrokePoint(x: 10, y: 0, width: 4)]
        let stroke = PaperStroke(points: points, color: (0, 0, 0, 1), inkIdentifier: nil,
                                 transform: CGAffineTransform(scaleX: 2, y: 2))
        let transformed = stroke.transformedPoints
        XCTAssertEqual(transformed[1].x, 20, accuracy: 0.001)
        XCTAssertEqual(transformed[0].width, 8, accuracy: 0.001,
                       "a scaled stroke keeps its shape but drops to a hairline if the width is left alone")
    }

    // MARK: - Format wiring

    func test_pdfVectorFormat_writesAPDFAndCannotBeConcatenated() {
        XCTAssertEqual(ExportFormat.pdfVector.fileExtension, "pdf")
        XCTAssertTrue(ExportFormat.pdfVector.isBinaryFormat)
        XCTAssertFalse(ExportFormat.pdfVector.supportsConcatenation)
        XCTAssertTrue(ExportFormat.pdfVector.hasOptionsSheet)
        // "pdf" already belongs to the HTML-rendered export, so this one needs
        // a token of its own.
        XCTAssertEqual(ExportFormat.pdfVector.cliToken, "pdf-vector")
        XCTAssertEqual(ExportFormat(cliString: "pdf"), .pdf)
    }

    func test_pdfVectorConfiguration_mapsSplitModesToASliceShape() throws {
        var config = PDFVectorConfiguration.defaultConfiguration
        XCTAssertNil(config.sliceAspectRatio, "Fit Page fills the paper and has no fixed shape")

        config.splitMode = .iPadScreen
        config.iPadModel = .elevenInch
        config.iPadOrientation = .portrait
        XCTAssertEqual(try XCTUnwrap(config.sliceAspectRatio), 1194.0 / 834.0, accuracy: 0.0001)

        config.iPadOrientation = .landscape
        XCTAssertEqual(try XCTUnwrap(config.sliceAspectRatio), 834.0 / 1194.0, accuracy: 0.0001)

        config.iPadModel = .thirteenInch
        config.iPadOrientation = .portrait
        XCTAssertEqual(try XCTUnwrap(config.sliceAspectRatio), 1366.0 / 1024.0, accuracy: 0.0001)
    }

    func test_splitToken_parsesEveryAdvertisedSpellingAndItsShortForm() {
        // The CLI switches over arbitrary user text, so a token added to the
        // enum but not to the parser would be unreachable from the command
        // line with nothing failing to compile.
        for token in PDFVectorConfiguration.SplitToken.allCases {
            XCTAssertEqual(
                PDFVectorConfiguration.SplitToken(argument: token.rawValue), token,
                "\(token.rawValue) is not reachable by its advertised spelling"
            )
            XCTAssertEqual(
                PDFVectorConfiguration.SplitToken(argument: token.rawValue.uppercased()), token,
                "\(token.rawValue) is case-sensitive"
            )
            XCTAssertTrue(
                PDFVectorConfiguration.SplitToken.advertisedTokens.contains(token.rawValue),
                "\(token.rawValue) is missing from the advertised list"
            )
        }
        XCTAssertEqual(PDFVectorConfiguration.SplitToken(argument: "ipad-11"), .iPad11Portrait)
        XCTAssertEqual(PDFVectorConfiguration.SplitToken(argument: "ipad-13"), .iPad13Portrait)
        XCTAssertEqual(PDFVectorConfiguration.SplitToken(argument: "fit"), .fitPage)
        XCTAssertNil(PDFVectorConfiguration.SplitToken(argument: "ipad-12"))
        XCTAssertNil(PDFVectorConfiguration.SplitToken(argument: ""))
    }

    func test_splitToken_setsTheModeTheIPadAndTheOrientationTogether() throws {
        var config = PDFVectorConfiguration.defaultConfiguration

        config.apply(.iPad13Landscape)
        XCTAssertEqual(config.splitMode, .iPadScreen)
        XCTAssertEqual(config.iPadModel, .thirteenInch)
        XCTAssertEqual(config.iPadOrientation, .landscape)
        XCTAssertEqual(try XCTUnwrap(config.sliceAspectRatio), 1024.0 / 1366.0, accuracy: 0.0001)

        // Going back to fit-page has to drop the fixed slice shape, or the
        // pages would still be letterboxed.
        config.apply(.fitPage)
        XCTAssertEqual(config.splitMode, .fitPage)
        XCTAssertNil(config.sliceAspectRatio)
    }

    func test_pageSize_parsesTheAdvertisedNames() {
        for size in PDFConfiguration.PageSize.allCases {
            XCTAssertEqual(PDFConfiguration.pageSize(argument: size.rawValue.lowercased()), size)
            XCTAssertEqual(PDFConfiguration.pageSize(argument: size.rawValue.uppercased()), size)
            XCTAssertTrue(PDFConfiguration.advertisedPageSizes.contains(size.rawValue.lowercased()))
        }
        XCTAssertNil(PDFConfiguration.pageSize(argument: "a3"))
    }

    func test_pdfVectorConfiguration_appliesOrientationToThePaper() {
        var config = PDFVectorConfiguration.defaultConfiguration
        config.pageSize = .letter
        config.orientation = .portrait
        XCTAssertEqual(config.pageDimensions.width, 612)
        XCTAssertEqual(config.pageDimensions.height, 792)

        config.orientation = .landscape
        XCTAssertEqual(config.pageDimensions.width, 792)
        XCTAssertEqual(config.pageDimensions.height, 612)
    }

    func test_pdfVectorConfiguration_survivesSettingsSavedBeforeItExisted() throws {
        // Decoding has to tolerate an older ExportConfigurations blob, which
        // carries no pdfVector key at all.
        let legacy = """
        {"html":\(try encoded(ExportConfigurations.default.html)),\
        "pdf":\(try encoded(ExportConfigurations.default.pdf)),\
        "latex":\(try encoded(ExportConfigurations.default.latex)),\
        "rtf":\(try encoded(ExportConfigurations.default.rtf))}
        """
        let decoded = try JSONDecoder().decode(ExportConfigurations.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.pdfVector.splitMode, .fitPage)
        XCTAssertTrue(decoded.pdfVector.maximizeContent)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "{}"
    }

    // MARK: - Helpers

    /// Count `f` (fill) operators in a page's content stream. Each stroke is
    /// emitted as exactly one filled outline.
    private static func fillOperatorCount(in page: CGPDFPage) -> Int {
        var count = 0
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "f") { _, info in
            info!.assumingMemoryBound(to: Int.self).pointee += 1
        }
        withUnsafeMutablePointer(to: &count) { pointer in
            let scanner = CGPDFScannerCreate(CGPDFContentStreamCreateWithPage(page), table, pointer)
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
        }
        CGPDFOperatorTableRelease(table)
        return count
    }
}
