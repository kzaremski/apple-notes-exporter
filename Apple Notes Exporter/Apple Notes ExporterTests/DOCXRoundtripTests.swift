//
//  DOCXRoundtripTests.swift
//  Apple Notes ExporterTests
//
//  Regression tests for issue #34 (corrupted DOCX / ODT). These don't fully
//  validate Word's strict parser, but they pin the structural invariants
//  that earlier versions broke: bare text outside <text:p>, missing
//  docProps, epoch-zero ZIP timestamps, missing Normal style, etc.
//

import XCTest
import Foundation
import Compression
@testable import Apple_Notes_Exporter

final class DOCXRoundtripTests: XCTestCase {

    private func sampleNote(html: String, title: String = "DOCX Sample") -> NotesNote {
        return NotesNote(
            id: "test-note-id",
            title: title,
            plaintext: "fallback text",
            htmlBody: html,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            folderId: "f1",
            accountId: "a1",
            attachments: []
        )
    }

    /// Read a single named entry from an in-memory ZIP (only LOC + DEFLATE/STORE).
    /// Minimal reader, just enough for these tests.
    private func readZIPEntry(_ archive: Data, named path: String) -> Data? {
        // Find End of Central Directory record
        let bytes = [UInt8](archive)
        guard bytes.count > 22 else { return nil }
        var eocdOffset = -1
        for i in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
            if bytes[i] == 0x50, bytes[i+1] == 0x4b, bytes[i+2] == 0x05, bytes[i+3] == 0x06 {
                eocdOffset = i; break
            }
        }
        guard eocdOffset >= 0 else { return nil }

        func u16(_ off: Int) -> Int { return Int(bytes[off]) | (Int(bytes[off+1]) << 8) }
        func u32(_ off: Int) -> Int {
            return Int(bytes[off]) | (Int(bytes[off+1]) << 8) | (Int(bytes[off+2]) << 16) | (Int(bytes[off+3]) << 24)
        }

        let cdSize = u32(eocdOffset + 12)
        let cdOffset = u32(eocdOffset + 16)
        var cd = cdOffset
        let cdEnd = cdOffset + cdSize
        while cd < cdEnd {
            guard bytes[cd] == 0x50, bytes[cd+1] == 0x4b, bytes[cd+2] == 0x01, bytes[cd+3] == 0x02 else { return nil }
            let method = u16(cd + 10)
            let compressedSize = u32(cd + 20)
            let uncompressedSize = u32(cd + 24)
            let nameLen = u16(cd + 28)
            let extraLen = u16(cd + 30)
            let commentLen = u16(cd + 32)
            let localOffset = u32(cd + 42)
            let name = String(bytes: bytes[(cd+46)..<(cd+46+nameLen)], encoding: .utf8) ?? ""
            cd += 46 + nameLen + extraLen + commentLen
            if name != path { continue }
            // Local file header at localOffset
            let lhNameLen = u16(localOffset + 26)
            let lhExtraLen = u16(localOffset + 28)
            let dataStart = localOffset + 30 + lhNameLen + lhExtraLen
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= bytes.count else { return nil }
            let payload = Data(bytes[dataStart..<dataEnd])
            if method == 0 { return payload }
            if method == 8 {
                // Raw DEFLATE: prepend zlib header so Foundation's Compression can decode,
                // or use Compression API directly via COMPRESSION_ZLIB on raw deflate.
                return rawInflate(payload, expectedSize: uncompressedSize)
            }
            return nil
        }
        return nil
    }

    private func rawInflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: expectedSize)
        let n = data.withUnsafeBytes { src -> Int in
            return out.withUnsafeMutableBufferPointer { dst -> Int in
                return compression_decode_buffer(dst.baseAddress!, expectedSize,
                                                 src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                 data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        return Data(out.prefix(n))
    }

    // MARK: - DOCX

    func test_docx_has_docProps_and_valid_styles() throws {
        let note = sampleNote(html: "<h1>Title</h1><p>Hello.</p>")
        let data = note.toDOCX()

        // Must contain the parts Word's strict parser checks for
        let coreXML = try XCTUnwrap(readZIPEntry(data, named: "docProps/core.xml"))
        let coreStr = String(data: coreXML, encoding: .utf8) ?? ""
        XCTAssertTrue(coreStr.contains("<dc:title>DOCX Sample</dc:title>"))
        XCTAssertTrue(coreStr.contains("dcterms:created"))

        let appXML = try XCTUnwrap(readZIPEntry(data, named: "docProps/app.xml"))
        let appStr = String(data: appXML, encoding: .utf8) ?? ""
        XCTAssertTrue(appStr.contains("<Application>"))

        let styles = try XCTUnwrap(readZIPEntry(data, named: "word/styles.xml"))
        let stylesStr = String(data: styles, encoding: .utf8) ?? ""
        // Word requires a Normal style + docDefaults; without these, the file
        // opens with the "file is corrupt" recovery prompt.
        XCTAssertTrue(stylesStr.contains("<w:docDefaults>"), "styles.xml missing docDefaults")
        XCTAssertTrue(stylesStr.contains("w:styleId=\"Normal\""), "styles.xml missing Normal style")

        let contentTypes = try XCTUnwrap(readZIPEntry(data, named: "[Content_Types].xml"))
        let ctStr = String(data: contentTypes, encoding: .utf8) ?? ""
        XCTAssertTrue(ctStr.contains("docProps/core.xml"))
        XCTAssertTrue(ctStr.contains("docProps/app.xml"))
    }

    func test_docx_zip_timestamps_not_epoch_zero() throws {
        let note = sampleNote(html: "<p>Hi.</p>")
        let data = note.toDOCX()
        // ZIP local file header for the first entry starts at offset 0.
        // mod time @ +10, mod date @ +12 (both UInt16 LE).
        let bytes = [UInt8](data)
        guard bytes.count > 14 else { return XCTFail("DOCX too short") }
        let modTime = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)
        let modDate = UInt16(bytes[12]) | (UInt16(bytes[13]) << 8)
        XCTAssertNotEqual(modDate, 0, "ZIP entry must have a non-zero MS-DOS date (Word rejects epoch zero)")
        // modTime can legitimately be 0 (midnight) so don't assert on it
        _ = modTime
    }

    // MARK: - ODT

    func test_odt_no_bare_text_outside_paragraphs() throws {
        // Plain text not wrapped in any HTML tags must end up inside a <text:p>.
        let note = sampleNote(html: "Just some bare text without a wrapping paragraph.")
        let data = note.toODT()
        let content = try XCTUnwrap(readZIPEntry(data, named: "content.xml"))
        let s = String(data: content, encoding: .utf8) ?? ""

        // Pull out the office:text body.
        guard let bodyStart = s.range(of: "<office:text>"),
              let bodyEnd = s.range(of: "</office:text>") else {
            return XCTFail("missing office:text section")
        }
        let body = String(s[bodyStart.upperBound..<bodyEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Body should be entirely <text:p>...</text:p> (and possibly tables).
        // No bare characters outside paragraphs.
        XCTAssertTrue(body.hasPrefix("<text:p"), "office:text body should start with <text:p>, got: \(body.prefix(80))")
        XCTAssertTrue(body.contains("Just some bare text without a wrapping paragraph."))
        XCTAssertTrue(body.contains("</text:p>"))
    }

    func test_odt_lists_inside_paragraphs() throws {
        let note = sampleNote(html: "<ul><li>one</li><li>two</li></ul>")
        let data = note.toODT()
        let content = try XCTUnwrap(readZIPEntry(data, named: "content.xml"))
        let s = String(data: content, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("<text:p text:style-name=\"ListIndent\">"))
        XCTAssertTrue(s.contains("one"))
        XCTAssertTrue(s.contains("two"))
    }

    // MARK: - Image embedding (data: URI → ZIP entry)

    /// Minimal valid 2x2 PNG used to assert end-to-end image embedding.
    private static let tinyPNGBytes: [UInt8] = [
        0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
        0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
        0x00,0x00,0x00,0x02,0x00,0x00,0x00,0x02,0x08,0x02,0x00,0x00,0x00,
        0xFD,0xD4,0x9A,0x73,
        0x00,0x00,0x00,0x16,0x49,0x44,0x41,0x54,
        0x78,0x9C,0x62,0xF8,0xCF,0xC0,0xF0,0x9F,0x81,0x81,0xE1,0x3F,
        0x03,0x03,0x03,0x03,0x00,0x18,0x37,0x05,0x9B,0x40,0xE1,0x82,0xE2,
        0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,0x42,0x60,0x82
    ]

    func test_docx_embeds_base64_image_into_word_media() throws {
        let pngBase64 = Data(Self.tinyPNGBytes).base64EncodedString()
        let html = "<p>Before <img src=\"data:image/png;base64,\(pngBase64)\" alt=\"image\"/> after</p>"
        let note = sampleNote(html: html)
        let data = note.toDOCX()

        // The image bytes must land at word/media/image1.png
        let imageData = try XCTUnwrap(readZIPEntry(data, named: "word/media/image1.png"))
        XCTAssertEqual(imageData, Data(Self.tinyPNGBytes))

        // The document must reference the image via a w:drawing run
        let doc = try XCTUnwrap(readZIPEntry(data, named: "word/document.xml"))
        let docStr = String(data: doc, encoding: .utf8) ?? ""
        XCTAssertTrue(docStr.contains("<w:drawing>"), "document.xml is missing the <w:drawing> element")
        XCTAssertTrue(docStr.contains("r:embed=\""), "document.xml is missing the r:embed reference")

        // The rels and Content Types must declare the image
        let rels = try XCTUnwrap(readZIPEntry(data, named: "word/_rels/document.xml.rels"))
        let relsStr = String(data: rels, encoding: .utf8) ?? ""
        XCTAssertTrue(relsStr.contains("media/image1.png"))
        XCTAssertTrue(relsStr.contains("relationships/image"))

        let ct = try XCTUnwrap(readZIPEntry(data, named: "[Content_Types].xml"))
        let ctStr = String(data: ct, encoding: .utf8) ?? ""
        XCTAssertTrue(ctStr.contains("Extension=\"png\""))
    }

    func test_odt_embeds_base64_image_into_pictures_folder() throws {
        let pngBase64 = Data(Self.tinyPNGBytes).base64EncodedString()
        let html = "<p>Before <img src=\"data:image/png;base64,\(pngBase64)\" alt=\"image\"/> after</p>"
        let note = sampleNote(html: html)
        let data = note.toODT()

        // Bytes at Pictures/image1.png
        let imageData = try XCTUnwrap(readZIPEntry(data, named: "Pictures/image1.png"))
        XCTAssertEqual(imageData, Data(Self.tinyPNGBytes))

        // Manifest declares the entry (LibreOffice drops undeclared files)
        let manifest = try XCTUnwrap(readZIPEntry(data, named: "META-INF/manifest.xml"))
        let mStr = String(data: manifest, encoding: .utf8) ?? ""
        XCTAssertTrue(mStr.contains("Pictures/image1.png"))
        XCTAssertTrue(mStr.contains("image/png"))

        // content.xml emits the draw:frame referencing it
        let content = try XCTUnwrap(readZIPEntry(data, named: "content.xml"))
        let cStr = String(data: content, encoding: .utf8) ?? ""
        XCTAssertTrue(cStr.contains("<draw:frame"))
        XCTAssertTrue(cStr.contains("xlink:href=\"Pictures/image1.png\""))
    }

    // MARK: - Hyperlinks (<a href>)

    func test_docx_emits_hyperlink_relationships_for_anchor_tags() throws {
        let html = "<p>Visit <a href=\"https://example.com/foo\">example</a> please.</p>"
        let note = sampleNote(html: html)
        let data = note.toDOCX()

        let doc = try XCTUnwrap(readZIPEntry(data, named: "word/document.xml"))
        let docStr = String(data: doc, encoding: .utf8) ?? ""
        XCTAssertTrue(docStr.contains("<w:hyperlink r:id="), "expected <w:hyperlink r:id=...> in document.xml")
        XCTAssertTrue(docStr.contains("example"))

        let rels = try XCTUnwrap(readZIPEntry(data, named: "word/_rels/document.xml.rels"))
        let relsStr = String(data: rels, encoding: .utf8) ?? ""
        XCTAssertTrue(relsStr.contains("https://example.com/foo"))
        XCTAssertTrue(relsStr.contains("TargetMode=\"External\""))
        XCTAssertTrue(relsStr.contains("relationships/hyperlink"))
    }

    func test_odt_emits_text_a_for_anchor_tags() throws {
        let html = "<p>Visit <a href=\"https://example.com/foo\">example</a> please.</p>"
        let note = sampleNote(html: html)
        let data = note.toODT()

        let content = try XCTUnwrap(readZIPEntry(data, named: "content.xml"))
        let cStr = String(data: content, encoding: .utf8) ?? ""
        XCTAssertTrue(cStr.contains("<text:a"))
        XCTAssertTrue(cStr.contains("xlink:href=\"https://example.com/foo\""))
        XCTAssertTrue(cStr.contains("example"))
    }

    // MARK: - Heading escape for attachment cards

    func test_docx_div_inside_heading_drops_heading_style() throws {
        // Apple Notes wraps attachment cards in <h1>. The card content
        // should NOT inherit Heading1 style.
        let html = "<h1>Title<br></h1><h1><div>card body text</div></h1>"
        let note = sampleNote(html: html)
        let data = note.toDOCX()
        let doc = try XCTUnwrap(readZIPEntry(data, named: "word/document.xml"))
        let docStr = String(data: doc, encoding: .utf8) ?? ""

        // Find the <w:p>…</w:p> chunk that contains the card text and
        // assert it doesn't declare a Heading1 paragraph style.
        var paragraphContainingCard: String? = nil
        var cursor = docStr.startIndex
        while let pOpen = docStr.range(of: "<w:p", range: cursor..<docStr.endIndex) {
            // Find the matching </w:p>
            guard let pClose = docStr.range(of: "</w:p>", range: pOpen.upperBound..<docStr.endIndex) else { break }
            let chunk = String(docStr[pOpen.lowerBound..<pClose.upperBound])
            if chunk.contains("card body text") {
                paragraphContainingCard = chunk
                break
            }
            cursor = pClose.upperBound
        }

        let chunk = try XCTUnwrap(paragraphContainingCard, "card text not found in any paragraph")
        XCTAssertFalse(chunk.contains("w:pStyle w:val=\"Heading1\""),
                       "card paragraph should not carry Heading1 style: \(chunk)")
    }

    func test_image_alt_image_does_not_render_as_redundant_alt() {
        // Cosmetic fix: alt="image" should render as [Image], not [Image: image].
        let note = sampleNote(html: "<p>Before <img alt=\"image\" src=\"x.jpg\"/> after</p>")
        let docx = note.toDOCX()
        let odt = note.toODT()

        if let docDataDOCX = readZIPEntry(docx, named: "word/document.xml") {
            let s = String(data: docDataDOCX, encoding: .utf8) ?? ""
            XCTAssertFalse(s.contains("[Image: image]"), "DOCX should not contain redundant '[Image: image]' placeholder")
            XCTAssertTrue(s.contains("[Image]"))
        } else { XCTFail("Couldn't read DOCX document.xml") }

        if let contentODT = readZIPEntry(odt, named: "content.xml") {
            let s = String(data: contentODT, encoding: .utf8) ?? ""
            XCTAssertFalse(s.contains("[Image: image]"))
            XCTAssertTrue(s.contains("[Image]"))
        } else { XCTFail("Couldn't read ODT content.xml") }
    }
}
