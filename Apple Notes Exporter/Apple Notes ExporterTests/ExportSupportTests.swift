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

    // MARK: - HTML entity decoding

    func test_htmlDecoded_decodesNamedDecimalAndHexadecimalEntities() {
        XCTAssertEqual(
            "Tom &amp; Jerry: &lt;example&gt; &quot;quoted&quot; &#169; &#x1F600;".htmlDecoded,
            "Tom & Jerry: <example> \"quoted\" © 😀"
        )
    }

    func test_htmlDecoded_decodesOneEscapingLayer() {
        XCTAssertEqual("&amp;amp;".htmlDecoded, "&amp;")
    }

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

    func test_rewriteInternalLinks_looksUpUUIDNotCoreDataPK() {
        let pk = "42"
        let uuid = "1d1d6543-df39-9275-9a7a-827db983efc0"
        let map = [
            pk: "iCloud/Notes/Target.md",
            uuid: "iCloud/Notes/Target.md"
        ]
        let html = "<a href='applenotes:note/\(uuid)?ownerIdentifier=foo'>Target</a>"
        let result = rewriteInternalLinks(
            html: html,
            currentNoteRelativePath: "iCloud/Notes/Source.md",
            noteIdToRelativePath: map
        )
        XCTAssertTrue(result.contains("Target.md"), "Expected UUID lookup, got: \(result)")
        XCTAssertFalse(result.contains("applenotes:note"))
    }

    func test_buildExportFolderPath_missingFolderUsesAccountNotesFolder() {
        let notesFolder = NotesFolder(id: "10", name: "Notes", parentId: "1", accountId: "1")
        let lookup = ["10": notesFolder]
        let path = buildExportFolderPath(folderId: "", folderLookup: lookup, accountId: "1")
        XCTAssertEqual(path, "Notes")
    }

    func test_buildExportFolderPath_missingFolderWithoutAccountStillNotes() {
        let path = buildExportFolderPath(folderId: "missing", folderLookup: [:], accountId: nil)
        XCTAssertEqual(path, "Notes")
        XCTAssertNotEqual(path, "Unknown Folder")
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

    // MARK: - matchingFolderIds

    private func folder(_ id: String, name: String, parent: String? = nil) -> NotesFolder {
        NotesFolder(id: id, name: name, parentId: parent, accountId: "1")
    }

    func test_matchingFolderIds_nameSubstringIncludesDescendants() {
        let folders = [
            folder("10", name: "Recipes"),
            folder("11", name: "Soups", parent: "10"),
            folder("12", name: "Work"),
        ]
        XCTAssertEqual(matchingFolderIds(filter: "Recipes", folders: folders), ["10", "11"])
        XCTAssertEqual(matchingFolderIds(filter: "Work", folders: folders), ["12"])
    }

    func test_matchingFolderIds_exactIdIncludesDescendants() {
        let folders = [
            folder("10", name: "Recipes"),
            folder("11", name: "Soups", parent: "10"),
            folder("13", name: "Broth", parent: "11"),
        ]
        XCTAssertEqual(matchingFolderIds(filter: "10", folders: folders), ["10", "11", "13"])
        XCTAssertEqual(matchingFolderIds(filter: "11", folders: folders), ["11", "13"])
    }

    func test_matchingFolderIds_unknownReturnsEmpty() {
        let folders = [folder("10", name: "Recipes")]
        XCTAssertTrue(matchingFolderIds(filter: "nope", folders: folders).isEmpty)
        XCTAssertTrue(matchingFolderIds(filter: "  ", folders: folders).isEmpty)
    }

    // MARK: - HTML folder indexes

    func test_writeHTMLFolderIndex_listsNotesAndSubfolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-index-\(UUID().uuidString)")
        let recipes = root.appendingPathComponent("Recipes")
        let soups = recipes.appendingPathComponent("Soups")
        try FileManager.default.createDirectory(at: soups, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "<p>Chili</p>".write(to: recipes.appendingPathComponent("Chili.html"), atomically: true, encoding: .utf8)
        try "<p>Broth</p>".write(to: soups.appendingPathComponent("Broth.html"), atomically: true, encoding: .utf8)

        try writeHTMLFolderIndexes(underRoot: root)

        let recipesIndex = try String(contentsOf: recipes.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(recipesIndex.contains(htmlFolderIndexMarker))
        XCTAssertTrue(recipesIndex.contains("Chili.html"))
        XCTAssertTrue(recipesIndex.contains("Soups/index.html"))

        let soupsIndex = try String(contentsOf: soups.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(soupsIndex.contains("Broth.html"))
    }

    func test_generateUniqueExportFilename_reservesIndexHtml() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-index-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let name = generateUniqueExportFilename(baseName: "index", extension: "html", inDirectory: dir)
        XCTAssertNotEqual(name.lowercased(), "index.html")
        XCTAssertTrue(name.hasSuffix(".html"))
    }

    // MARK: - Notes database path resolution

    func test_resolvedFilePath_expandsTildeToAbsolute() {
        let resolved = resolvedFilePath("~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
        XCTAssertFalse(resolved.contains("~"))
        XCTAssertTrue(resolved.hasPrefix("/"))
        XCTAssertTrue(resolved.hasSuffix("/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"))
        XCTAssertEqual(resolved, defaultNotesDatabasePath())
    }

    func test_userHomeDirectoryPath_isAbsolute() {
        let home = userHomeDirectoryPath()
        XCTAssertTrue(home.hasPrefix("/"))
        XCTAssertFalse(home.contains("~"))
    }

    func test_buildInternalLinkPathMap_reservesIndexHtml() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-linkmap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = NotesNote(
            id: "1",
            title: "index",
            plaintext: "body",
            htmlBody: nil,
            creationDate: Date(),
            modificationDate: Date(),
            folderId: "f",
            accountId: "a",
            attachments: []
        )
        let map = buildInternalLinkPathMap(
            allNotes: [note],
            notesWithPaths: [(note: note, folderURL: dir)],
            outputRoot: dir,
            format: .html,
            addDatePrefix: false,
            dateFormat: "yyyy-MM-dd",
            existingManifest: nil
        )
        guard let rel = map["1"] else {
            return XCTFail("expected a path mapping for the note")
        }
        XCTAssertNotEqual((rel as NSString).lastPathComponent.lowercased(), "index.html")
    }
}
