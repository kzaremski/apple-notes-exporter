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

    func test_rewriteInternalLinks_uuidCaseDiffersBetweenLinkAndDatabase() {
        // Real data: ZIDENTIFIER is stored uppercase, but Apple writes the
        // UUID lowercase into the applenotes: link. A case-sensitive lookup
        // silently leaves the link unrewritten.
        let stored = "634112D0-8C76-435A-9EC5-1436D955EF53"
        let map = [stored: "iCloud/Notes/Viviana.md"]
        let html = "Viviana [applenotes:note/\(stored.lowercased())?ownerIdentifier=_9e42932ef6]"

        let result = rewriteInternalLinks(
            html: html,
            currentNoteRelativePath: "iCloud/Work/Source.md",
            noteIdToRelativePath: map
        )
        XCTAssertFalse(result.contains("applenotes:note"), "link should be rewritten, got: \(result)")
        XCTAssertTrue(result.contains("Viviana.md"))
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

    func test_matchingFolderIds_exactNameIncludesDescendants() {
        let folders = [
            folder("10", name: "Recipes"),
            folder("11", name: "Soups", parent: "10"),
            folder("12", name: "Work"),
            folder("13", name: "Recipe Book"),
        ]
        XCTAssertEqual(matchingFolderIds(filter: "Recipes", folders: folders), ["10", "11"])
        XCTAssertEqual(matchingFolderIds(filter: "Work", folders: folders), ["12"])
        XCTAssertTrue(matchingFolderIds(filter: "Rec", folders: folders).isEmpty)
    }

    func test_matchingFolderIds_containsModeAndNoDescendants() {
        let folders = [
            folder("10", name: "Recipes"),
            folder("11", name: "Soups", parent: "10"),
            folder("13", name: "Recipe Book"),
        ]
        XCTAssertEqual(
            matchingFolderIds(filters: ["Rec"], folders: folders, matchContains: true, includeDescendants: false),
            ["10", "13"]
        )
        XCTAssertEqual(
            matchingFolderIds(filters: ["Recipes"], folders: folders, matchContains: false, includeDescendants: false),
            ["10"]
        )
    }

    func test_matchingFolderIds_multiSelectUnion() {
        let folders = [
            folder("10", name: "Recipes"),
            folder("12", name: "Work"),
        ]
        XCTAssertEqual(
            matchingFolderIds(filters: ["Recipes", "Work"], folders: folders),
            ["10", "12"]
        )
        XCTAssertEqual(
            matchingFolderIds(filters: ["10,12"], folders: folders, includeDescendants: false),
            ["10", "12"]
        )
    }

    func test_selectedNotes_unionAndRecentlyDeleted() {
        let live = NotesNote(
            id: "1", title: "A", plaintext: "", htmlBody: nil,
            creationDate: Date(), modificationDate: Date(),
            folderId: "10", accountId: "1", attachments: [], isDeleted: false
        )
        let trash = NotesNote(
            id: "2", title: "B", plaintext: "", htmlBody: nil,
            creationDate: Date(), modificationDate: Date(),
            folderId: "10", accountId: "1", attachments: [], isDeleted: true
        )
        let other = NotesNote(
            id: "3", title: "C", plaintext: "", htmlBody: nil,
            creationDate: Date(), modificationDate: Date(),
            folderId: "12", accountId: "1", attachments: [], isDeleted: false
        )
        let all = [live, trash, other]

        let onlyLive = selectedNotes(from: all, folderIds: [], noteIds: [], includeDeleted: false, selectAllTrash: false)
        XCTAssertEqual(Set(onlyLive.map(\.id)), ["1", "3"])

        let trashOnly = applyNoteSelection(
            notes: all, folders: [folder("10", name: "Work")],
            folderFilters: ["Recently Deleted"], matchContains: false,
            includeSubfolders: true, includeDeleted: false, noteIds: []
        )
        XCTAssertEqual(trashOnly.map(\.id), ["2"])

        let union = applyNoteSelection(
            notes: all, folders: [folder("12", name: "Work")],
            folderFilters: ["Work"], matchContains: false,
            includeSubfolders: true, includeDeleted: false, noteIds: ["1"]
        )
        XCTAssertEqual(Set(union.map(\.id)), ["1", "3"])
    }

    func test_attachmentExportLocation_sharedDumpIsRelativeToNote() {
        let root = URL(fileURLWithPath: "/tmp/export")
        let noteDir = root.appendingPathComponent("iCloud/Notes")
        let loc = attachmentExportLocation(
            sharedDump: true,
            outputRoot: root,
            noteDirectory: noteDir,
            noteBaseName: "Foo",
            filename: "img.png"
        )
        XCTAssertTrue(loc.directory.path.hasSuffix("Attachments/iCloud/Notes/Foo"))
        XCTAssertTrue(loc.relativePath.contains("Attachments/"))
        XCTAssertTrue(loc.relativePath.hasSuffix("img.png"))
        XCTAssertFalse(loc.relativePath.hasPrefix("/"))
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

    // MARK: - Sync manifest history

    func test_syncManifest_oldJSONWithoutHistoryStillLoads() throws {
        let json = """
        {
          "version": 1,
          "lastSync": 1700000000,
          "notes": {
            "1": {
              "modificationDate": 1700000000,
              "exportedPath": "iCloud/Notes/A.md",
              "attachmentPaths": []
            }
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let manifest = try decoder.decode(SyncManifest.self, from: Data(json.utf8))
        XCTAssertTrue(manifest.history.isEmpty)
        XCTAssertEqual(manifest.notes["1"]?.exportedPath, "iCloud/Notes/A.md")
    }

    func test_syncManifest_recordsAddedUpdatedDeletedAsFileDiff() {
        var manifest = SyncManifest.empty()
        manifest.recordExport(noteId: "1", modificationDate: Date(), exportedPath: "iCloud/Notes/A.md")
        manifest.recordExport(noteId: "2", modificationDate: Date(), exportedPath: "iCloud/Work/B.md")

        let pruned = manifest.pruneDeleted(presentNoteIds: ["1"])
        XCTAssertEqual(pruned.map(\.noteId), ["2"])

        manifest.appendRun(SyncManifest.SyncRun(
            timestamp: Date(),
            added: [SyncManifest.HistoryItem(noteId: "1", path: "iCloud/Notes/A.md")],
            updated: [],
            deleted: [SyncManifest.HistoryItem(noteId: "2", path: "iCloud/Work/B.md")]
        ))

        XCTAssertEqual(manifest.history.count, 1)
        XCTAssertEqual(manifest.history[0].added.map(\.path), ["iCloud/Notes/A.md"])
        XCTAssertEqual(manifest.history[0].deleted.map(\.path), ["iCloud/Work/B.md"])
        XCTAssertNil(manifest.notes["2"])
    }

    func test_syncManifestTracker_classifiesAddedVsUpdated() async {
        var seed = SyncManifest.empty()
        seed.recordExport(noteId: "1", modificationDate: Date(), exportedPath: "Notes/A.md")
        let tracker = SyncManifestTracker(manifest: seed)

        await tracker.recordExport(noteId: "1", modificationDate: Date(), exportedPath: "Notes/A.md")
        await tracker.recordExport(noteId: "2", modificationDate: Date(), exportedPath: "Notes/B.md")
        await tracker.finishRun(pruned: [])

        let manifest = await tracker.getManifest()
        XCTAssertEqual(manifest.history.last?.updated.map(\.noteId), ["1"])
        XCTAssertEqual(manifest.history.last?.added.map(\.noteId), ["2"])
        XCTAssertEqual(manifest.history.last?.deleted, [])
    }

    func test_syncManifest_saveLoadRoundtripsHistory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var manifest = SyncManifest.empty()
        manifest.recordExport(noteId: "1", modificationDate: Date(timeIntervalSince1970: 1_700_000_000), exportedPath: "iCloud/Notes/A.md")
        manifest.appendRun(SyncManifest.SyncRun(
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            added: [SyncManifest.HistoryItem(noteId: "1", path: "iCloud/Notes/A.md")],
            updated: [],
            deleted: [SyncManifest.HistoryItem(noteId: "9", path: "iCloud/Notes/Old.md")]
        ))
        try manifest.save(to: dir)

        let loaded = try XCTUnwrap(SyncManifest.load(from: dir))
        XCTAssertEqual(loaded.notes["1"]?.exportedPath, "iCloud/Notes/A.md")
        XCTAssertEqual(loaded.history.count, 1)
        XCTAssertEqual(loaded.history[0].added.first?.path, "iCloud/Notes/A.md")
        XCTAssertEqual(loaded.history[0].deleted.first?.path, "iCloud/Notes/Old.md")
    }

    func test_syncManifest_historyDropsOldestOverCap() {
        var manifest = SyncManifest.empty()
        for i in 0..<(SyncManifest.maxHistoryRuns + 3) {
            manifest.appendRun(SyncManifest.SyncRun(
                timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                added: [SyncManifest.HistoryItem(noteId: "\(i)", path: "Notes/\(i).md")],
                updated: [],
                deleted: []
            ))
        }
        XCTAssertEqual(manifest.history.count, SyncManifest.maxHistoryRuns)
        XCTAssertEqual(manifest.history.first?.added.first?.noteId, "3")
        XCTAssertEqual(manifest.history.last?.added.first?.noteId, "\(SyncManifest.maxHistoryRuns + 2)")
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

    // MARK: - defaultNotesFolder / localized default folder

    private func note(_ id: String, folder: String, account: String = "1") -> NotesNote {
        NotesNote(
            id: id, title: "Note \(id)", plaintext: "", htmlBody: nil,
            creationDate: Date(), modificationDate: Date(),
            folderId: folder, accountId: account, attachments: []
        )
    }

    func test_buildExportFolderPath_defaultFolderMarkerBeatsLocalizedName() {
        // A German library: the default folder is "Notizen", so a name match on
        // "Notes" would miss it and invent an English folder that isn't there.
        let localized = NotesFolder(
            id: "10", name: "Notizen", parentId: nil, accountId: "1",
            identifier: "DefaultFolder-CloudKit"
        )
        let other = NotesFolder(id: "11", name: "Arbeit", parentId: nil, accountId: "1")
        let lookup = ["10": localized, "11": other]

        let path = buildExportFolderPath(folderId: "", folderLookup: lookup, accountId: "1")
        XCTAssertEqual(path, "Notizen")
    }

    func test_buildExportFolderPath_defaultFolderOfOtherAccountIsNotBorrowed() {
        let theirs = NotesFolder(
            id: "10", name: "Notes", parentId: nil, accountId: "2",
            identifier: "DefaultFolder-CloudKit"
        )
        let path = buildExportFolderPath(folderId: "", folderLookup: ["10": theirs], accountId: "1")
        XCTAssertEqual(path, "Notes", "should fall back, not reuse another account's folder")
    }

    func test_buildExportFolderPath_resolutionIsStableAcrossCalls() {
        // Dictionary iteration order is not stable, so a library with more than
        // one marked folder must still resolve the same way every run or the
        // sync manifest thrashes.
        var lookup: [String: NotesFolder] = [:]
        for id in ["30", "10", "20"] {
            lookup[id] = NotesFolder(
                id: id, name: "Notes \(id)", parentId: nil, accountId: "1",
                identifier: "DefaultFolder-CloudKit"
            )
        }
        let results = (0..<20).map { _ in
            buildExportFolderPath(folderId: "", folderLookup: lookup, accountId: "1")
        }
        XCTAssertEqual(Set(results).count, 1, "expected one stable answer, got \(Set(results))")
    }

    func test_buildExportFolderPath_nestedFolderKeepsFullPath() {
        let parent = NotesFolder(id: "10", name: "Recipes", parentId: nil, accountId: "1")
        let child = NotesFolder(id: "11", name: "Soups", parentId: "10", accountId: "1")
        let path = buildExportFolderPath(
            folderId: "11", folderLookup: ["10": parent, "11": child], accountId: "1"
        )
        XCTAssertEqual(path, "Recipes/Soups")
    }

    func test_buildExportFolderPath_cyclicParentChainTerminates() {
        // A self-parenting ZPARENT would otherwise spin forever.
        let a = NotesFolder(id: "10", name: "A", parentId: "11", accountId: "1")
        let b = NotesFolder(id: "11", name: "B", parentId: "10", accountId: "1")
        let path = buildExportFolderPath(
            folderId: "10", folderLookup: ["10": a, "11": b], accountId: "1"
        )
        XCTAssertFalse(path.isEmpty)
    }

    // MARK: - zipDirectory

    func test_zipDirectory_producesAnArchiveThatRoundTrips() throws {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("Apple Notes Export")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("iCloud/Notes"), withIntermediateDirectories: true
        )
        try Data("hello".utf8).write(to: source.appendingPathComponent("iCloud/Notes/A.md"))
        try Data("world".utf8).write(to: source.appendingPathComponent("iCloud/Notes/B.md"))

        let archive = root.appendingPathComponent("Apple Notes Export.zip")
        try zipDirectory(at: source, to: archive)

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path), "archive was not written")
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "archive is empty")

        // Unpack it again and confirm the tree survived.
        let unpacked = root.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, unpacked.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0, "archive could not be expanded")

        let restored = unpacked.appendingPathComponent("Apple Notes Export/iCloud/Notes/A.md")
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), "hello")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: unpacked.appendingPathComponent("Apple Notes Export/iCloud/Notes/B.md").path
            )
        )
    }

    func test_zipDirectory_preservesFileModificationDates() throws {
        // Exported notes carry their note's creation and modification dates.
        // Those have to survive the trip into the archive, or a zip export
        // loses metadata that a folder export keeps.
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("Apple Notes Export")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("iCloud/Notes"), withIntermediateDirectories: true
        )
        let note = source.appendingPathComponent("iCloud/Notes/Old Note.md")
        try Data("aged".utf8).write(to: note)

        let created = Date(timeIntervalSince1970: 1_100_000_000)   // 2004-11-09
        let modified = Date(timeIntervalSince1970: 1_400_000_000)  // 2014-05-13
        try setExportFileTimestamps(note, creationDate: created, modificationDate: modified)

        let archive = root.appendingPathComponent("Apple Notes Export.zip")
        try zipDirectory(at: source, to: archive)

        let unpacked = root.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, unpacked.path]
        try unzip.run()
        unzip.waitUntilExit()

        let restored = unpacked.appendingPathComponent("Apple Notes Export/iCloud/Notes/Old Note.md")
        let attrs = try FileManager.default.attributesOfItem(atPath: restored.path)
        let restoredModified = attrs[.modificationDate] as? Date

        XCTAssertNotNil(restoredModified)
        XCTAssertEqual(
            restoredModified!.timeIntervalSince1970,
            modified.timeIntervalSince1970,
            accuracy: 2,
            "modification date did not survive the archive"
        )
    }

    func test_zipDirectory_overwritesAnExistingArchive() throws {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("Apple Notes Export")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appendingPathComponent("note.md"))

        let archive = root.appendingPathComponent("Apple Notes Export.zip")
        try Data("stale".utf8).write(to: archive)
        try zipDirectory(at: source, to: archive)

        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 5, "stale file should have been replaced by a real archive")
    }

    // MARK: - healManifestPaths

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-heal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func writeFile(_ relativePath: String, under root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
    }

    func test_healManifestPaths_dropsEntryStrandedInUnknownFolder() throws {
        let root = try makeTempDirectory()
        let stale = "iCloud/Unknown Folder/2001-01-01.html"
        try writeFile(stale, under: root)

        var manifest = SyncManifest(lastSync: Date(), notes: [
            "1": SyncManifest.SyncedNoteEntry(
                modificationDate: Date(), exportedPath: stale, attachmentPaths: []
            )
        ])
        let notesFolder = NotesFolder(id: "10", name: "Notes", parentId: nil, accountId: "1")

        let healed = healManifestPaths(
            manifest: &manifest,
            notes: [note("1", folder: "")],
            accountLookup: ["1": "iCloud"],
            folderLookup: ["10": notesFolder],
            outputRoot: root
        )

        XCTAssertEqual(healed.map(\.noteId), ["1"])
        XCTAssertNil(manifest.notes["1"], "entry should be dropped so the note re-exports")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(stale).path),
            "stale file should be deleted"
        )
    }

    func test_healManifestPaths_keepsEntryWhenOnlyFilenameDiffers() throws {
        let root = try makeTempDirectory()
        // Collision suffixes are legitimate; only the directory should matter.
        let path = "iCloud/Notes/Note 1 (2).html"
        try writeFile(path, under: root)

        var manifest = SyncManifest(lastSync: Date(), notes: [
            "1": SyncManifest.SyncedNoteEntry(
                modificationDate: Date(), exportedPath: path, attachmentPaths: []
            )
        ])
        let notesFolder = NotesFolder(id: "10", name: "Notes", parentId: nil, accountId: "1")

        let healed = healManifestPaths(
            manifest: &manifest,
            notes: [note("1", folder: "10")],
            accountLookup: ["1": "iCloud"],
            folderLookup: ["10": notesFolder],
            outputRoot: root
        )

        XCTAssertTrue(healed.isEmpty)
        XCTAssertNotNil(manifest.notes["1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
    }

    func test_healManifestPaths_relocatesNoteMovedBetweenFolders() throws {
        let root = try makeTempDirectory()
        let stale = "iCloud/Work/Note 1.html"
        let attachment = "iCloud/Work/Note 1/image.png"
        try writeFile(stale, under: root)
        try writeFile(attachment, under: root)

        var manifest = SyncManifest(lastSync: Date(), notes: [
            "1": SyncManifest.SyncedNoteEntry(
                modificationDate: Date(), exportedPath: stale, attachmentPaths: [attachment]
            )
        ])
        let work = NotesFolder(id: "10", name: "Work", parentId: nil, accountId: "1")
        let personal = NotesFolder(id: "11", name: "Personal", parentId: nil, accountId: "1")

        // The note now lives in Personal.
        let healed = healManifestPaths(
            manifest: &manifest,
            notes: [note("1", folder: "11")],
            accountLookup: ["1": "iCloud"],
            folderLookup: ["10": work, "11": personal],
            outputRoot: root
        )

        XCTAssertEqual(healed.count, 1)
        XCTAssertNil(manifest.notes["1"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(attachment).path),
            "attachments should be cleaned up alongside the note"
        )
    }

    func test_healManifestPaths_ignoresNotesAbsentFromManifest() throws {
        let root = try makeTempDirectory()
        var manifest = SyncManifest(lastSync: Date(), notes: [:])
        let healed = healManifestPaths(
            manifest: &manifest,
            notes: [note("1", folder: "10")],
            accountLookup: ["1": "iCloud"],
            folderLookup: [:],
            outputRoot: root
        )
        XCTAssertTrue(healed.isEmpty)
    }
}
