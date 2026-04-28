//
//  ExportSupportTests.swift
//  Apple Notes ExporterTests
//
//  Copyright (C) 2026 Konstantin Zaremski
//  Licensed under GPL v3.
//

import XCTest
@testable import Apple_Notes_Exporter

final class ExportSupportTests: XCTestCase {

    // MARK: - sanitizeExportFilename
    //
    // Contract: produce a string safe to use as a single filesystem path
    // component. Don't assert specific replacement choices (e.g. that "/"
    // becomes "_") since that's implementation; assert the output is safe
    // and that clean inputs are preserved.

    private static let forbiddenInFilenames: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r"]

    private func assertNoForbiddenCharacters(_ s: String, file: StaticString = #file, line: UInt = #line) {
        for ch in s where Self.forbiddenInFilenames.contains(ch) {
            XCTFail("filename '\(s)' contains forbidden character \(ch)", file: file, line: line)
        }
    }

    func test_sanitizeExportFilename_removesPathSeparators() {
        assertNoForbiddenCharacters(sanitizeExportFilename("a/b\\c"))
    }

    func test_sanitizeExportFilename_removesIllegalCharacters() {
        assertNoForbiddenCharacters(sanitizeExportFilename("note: <\"why?\"> *test*|x"))
    }

    func test_sanitizeExportFilename_preservesCleanInput() {
        let input = "My Vacation Notes 2026"
        XCTAssertEqual(sanitizeExportFilename(input), input)
    }

    func test_sanitizeExportFilename_emptyInputReturnsEmpty() {
        XCTAssertTrue(sanitizeExportFilename("").isEmpty)
    }

    func test_sanitizeExportFilename_removesNewlinesAndControlChars() {
        assertNoForbiddenCharacters(sanitizeExportFilename("hello\nworld\rsuffix"))
    }

    func test_sanitizeExportFilename_preservesAlphanumericAndCommonPunctuation() {
        // After sanitization, normal note-title characters (letters, numbers,
        // spaces, hyphens, parens, accented chars) should still be present.
        let result = sanitizeExportFilename("Trip to Paris (2026) - rough notes, résumé")
        XCTAssertTrue(result.contains("Trip"))
        XCTAssertTrue(result.contains("Paris"))
        XCTAssertTrue(result.contains("(2026)"))
        XCTAssertTrue(result.contains("résumé"))
    }

    // MARK: - splitExportFilename

    func test_splitExportFilename_basicCase() {
        let (name, ext) = splitExportFilename("note.md")
        XCTAssertEqual(name, "note")
        XCTAssertEqual(ext, "md")
    }

    func test_splitExportFilename_multipleDotsUsesLast() {
        let (name, ext) = splitExportFilename("my.test.file.pdf")
        XCTAssertEqual(name, "my.test.file")
        XCTAssertEqual(ext, "pdf")
    }

    func test_splitExportFilename_noExtension() {
        let (name, ext) = splitExportFilename("README")
        XCTAssertEqual(name, "README")
        XCTAssertEqual(ext, "")
    }

    func test_splitExportFilename_leadingDotIsNotExtension() {
        // Hidden files: ".gitignore" should be treated as a filename, not as extension "gitignore".
        let (name, ext) = splitExportFilename(".gitignore")
        XCTAssertEqual(name, ".gitignore")
        XCTAssertEqual(ext, "")
    }

    // MARK: - relativePathFromSource

    func test_relativePath_sameDirectory() {
        let result = relativePathFromSource("iCloud/Notes/A.md", toTarget: "iCloud/Notes/B.md")
        XCTAssertEqual(result, "B.md")
    }

    func test_relativePath_siblingFolder() {
        let result = relativePathFromSource("iCloud/Work/A.md", toTarget: "iCloud/Personal/B.md")
        XCTAssertEqual(result, "../Personal/B.md")
    }

    func test_relativePath_acrossAccounts() {
        let result = relativePathFromSource("iCloud/Folder/A.md", toTarget: "OnMyMac/Other/B.md")
        XCTAssertEqual(result, "../../OnMyMac/Other/B.md")
    }

    func test_relativePath_targetInDeeperFolder() {
        let result = relativePathFromSource("iCloud/A.md", toTarget: "iCloud/Subfolder/B.md")
        XCTAssertEqual(result, "Subfolder/B.md")
    }

    func test_relativePath_targetInShallowerFolder() {
        let result = relativePathFromSource("iCloud/Subfolder/A.md", toTarget: "iCloud/B.md")
        XCTAssertEqual(result, "../B.md")
    }

    // MARK: - rewriteInternalLinks

    // Apple Notes IDs are UUID-like; the rewrite regex requires at least 8
    // hex/dash characters after `applenotes:note/`. Use realistic test IDs.

    func test_rewriteInternalLinks_basicSingleLink() {
        let id = "1d1d6543-df39-9275-9a7a-827db983efc0"
        let map = [id: "iCloud/Notes/Target.md"]
        let html = #"<a href="applenotes:note/\#(id)?ownerIdentifier=foo">Target</a>"#
        let result = rewriteInternalLinks(
            html: html,
            currentNoteRelativePath: "iCloud/Notes/Source.md",
            noteIdToRelativePath: map
        )
        XCTAssertTrue(result.contains("Target.md"), "Expected rewritten URL, got: \(result)")
        XCTAssertFalse(result.contains("applenotes:note"), "Expected applenotes: URL to be replaced")
    }

    func test_rewriteInternalLinks_unknownUUIDLeftAlone() {
        let knownID = "1d1d6543-df39-9275-9a7a-827db983efc0"
        let unknownID = "deadbeef-0000-0000-0000-000000000000"
        let map = [knownID: "Notes/Target.md"]
        let html = #"<a href="applenotes:note/\#(unknownID)?x=y">Other</a>"#
        let result = rewriteInternalLinks(
            html: html,
            currentNoteRelativePath: "Notes/Source.md",
            noteIdToRelativePath: map
        )
        // Unknown ID stays as-is (browsers will fail to follow it but at least we don't lose info).
        XCTAssertTrue(result.contains("applenotes:note/\(unknownID)"))
    }

    func test_rewriteInternalLinks_emptyMapNoOp() {
        let id = "1d1d6543-df39-9275-9a7a-827db983efc0"
        let html = #"<a href="applenotes:note/\#(id)?x=y">x</a>"#
        let result = rewriteInternalLinks(html: html, currentNoteRelativePath: "x.md", noteIdToRelativePath: [:])
        XCTAssertEqual(result, html)
    }

    func test_rewriteInternalLinks_noApplenotesURIsNoOp() {
        let html = #"<a href="https://example.com">External</a>"#
        let map = ["1d1d6543-df39-9275-9a7a-827db983efc0": "Other.md"]
        let result = rewriteInternalLinks(html: html, currentNoteRelativePath: "x.md", noteIdToRelativePath: map)
        XCTAssertEqual(result, html)
    }

    func test_rewriteInternalLinks_multipleLinks() {
        let id1 = "1d1d6543-df39-9275-9a7a-827db983efc0"
        let id2 = "2e2e7654-ef40-a386-ab8b-938ec094f0d1"
        let map = [
            id1: "Folder/A.md",
            id2: "Folder/B.md"
        ]
        let html = #"<a href="applenotes:note/\#(id1)?x=1">A</a> and <a href="applenotes:note/\#(id2)?x=2">B</a>"#
        let result = rewriteInternalLinks(
            html: html,
            currentNoteRelativePath: "Folder/Source.md",
            noteIdToRelativePath: map
        )
        XCTAssertTrue(result.contains("A.md"))
        XCTAssertTrue(result.contains("B.md"))
        XCTAssertFalse(result.contains("applenotes:note"))
    }

    // MARK: - detectFileExtension (magic bytes)

    func test_detectFileExtension_jpeg() {
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        XCTAssertEqual(detectFileExtension(from: data), "jpg")
    }

    func test_detectFileExtension_png() {
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(detectFileExtension(from: data), "png")
    }

    func test_detectFileExtension_pdf() {
        let data = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37])  // %PDF-1.7
        XCTAssertEqual(detectFileExtension(from: data), "pdf")
    }

    func test_detectFileExtension_gif() {
        let data = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])  // GIF89a
        XCTAssertEqual(detectFileExtension(from: data), "gif")
    }

    func test_detectFileExtension_heic() {
        // ftyp header at offset 4
        let data = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
        XCTAssertEqual(detectFileExtension(from: data), "heic")
    }

    func test_detectFileExtension_unknownReturnsNil() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00])
        XCTAssertNil(detectFileExtension(from: data))
    }

    func test_detectFileExtension_tooShortReturnsNil() {
        XCTAssertNil(detectFileExtension(from: Data([0xFF, 0xD8])))
    }

    // MARK: - filterFileAttachments

    func test_filterFileAttachments_keepsImageAttachments() {
        let kept = NotesAttachment(id: "1", typeUTI: "public.jpeg", filename: "photo.jpg")
        XCTAssertEqual(filterFileAttachments([kept]).count, 1)
    }

    func test_filterFileAttachments_dropsTables() {
        let table = NotesAttachment(id: "1", typeUTI: "com.apple.notes.table", filename: nil)
        XCTAssertTrue(filterFileAttachments([table]).isEmpty)
    }

    func test_filterFileAttachments_dropsInlineHashtags() {
        let tag = NotesAttachment(id: "1", typeUTI: "com.apple.notes.inlinehashtagattachment", filename: nil)
        XCTAssertTrue(filterFileAttachments([tag]).isEmpty)
    }

    func test_filterFileAttachments_dropsInlineMentions() {
        let mention = NotesAttachment(id: "1", typeUTI: "com.apple.notes.inlinementionattachment", filename: nil)
        XCTAssertTrue(filterFileAttachments([mention]).isEmpty)
    }

    func test_filterFileAttachments_dropsInlineTextAttachmentSubtypes() {
        // Should match prefix com.apple.notes.inlinetextattachment.
        let calc = NotesAttachment(id: "1", typeUTI: "com.apple.notes.inlinetextattachment.calculate.result", filename: nil)
        XCTAssertTrue(filterFileAttachments([calc]).isEmpty)
    }

    func test_filterFileAttachments_dropsURLs() {
        let link = NotesAttachment(id: "1", typeUTI: "public.url", filename: nil)
        XCTAssertTrue(filterFileAttachments([link]).isEmpty)
    }

    func test_filterFileAttachments_keepsDrawings() {
        // Drawings should NOT be filtered — they have fallback images that should export.
        let drawing = NotesAttachment(id: "1", typeUTI: "com.apple.drawing.2", filename: nil)
        XCTAssertEqual(filterFileAttachments([drawing]).count, 1)
    }

    func test_filterFileAttachments_mixedSet() {
        let attachments = [
            NotesAttachment(id: "1", typeUTI: "public.jpeg", filename: "img.jpg"),
            NotesAttachment(id: "2", typeUTI: "com.apple.notes.table", filename: nil),
            NotesAttachment(id: "3", typeUTI: "public.pdf", filename: "doc.pdf"),
            NotesAttachment(id: "4", typeUTI: "public.url", filename: nil),
        ]
        let result = filterFileAttachments(attachments)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map { $0.id }), ["1", "3"])
    }
}
