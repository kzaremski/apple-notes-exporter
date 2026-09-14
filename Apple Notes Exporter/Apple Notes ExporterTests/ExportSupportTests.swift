//
//  ExportSupportTests.swift
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

    // MARK: - single file destination

    func test_concatenatedExportURL_usesTheFileTheUserNamed() {
        let named = URL(fileURLWithPath: "/tmp/out/My Notes.md")
        XCTAssertEqual(concatenatedExportURL(destination: named, format: .markdown), named)
    }

    func test_concatenatedExportURL_fallsBackToDefaultNameInADirectory() {
        let dir = URL(fileURLWithPath: "/tmp/out")
        XCTAssertEqual(
            concatenatedExportURL(destination: dir, format: .markdown).lastPathComponent,
            "\(concatenatedFileBaseName).md"
        )
    }

    func test_concatenatedExportURL_containingFolderIsNeverTheFileItself() {
        // Regression: the app used the destination as the directory to write
        // attachments and folder paths into. When the user named a file, that
        // created a folder called "Exported Notes.md" holding the whole tree,
        // and the final write then failed against the folder sitting in its
        // place. Whichever form the destination takes, the directory to work in
        // is the resolved file's parent, never the file path.
        for destination in [URL(fileURLWithPath: "/tmp/out/My Notes.md"),
                            URL(fileURLWithPath: "/tmp/out")] {
            let resolved = concatenatedExportURL(destination: destination, format: .markdown)
            let workingDirectory = resolved.deletingLastPathComponent()
            XCTAssertEqual(workingDirectory.path, "/tmp/out")
            XCTAssertNotEqual(workingDirectory, resolved)
        }
    }

    func test_concatenatedExportURL_ignoresAnExtensionForADifferentFormat() {
        // A name left over from a previous format is not the file to write.
        let stale = URL(fileURLWithPath: "/tmp/out/My Notes.md")
        XCTAssertEqual(
            concatenatedExportURL(destination: stale, format: .txt).lastPathComponent,
            "\(concatenatedFileBaseName).txt"
        )
    }

    func test_supportsConcatenation_excludesOnlyPackagedFormats() {
        let blocked = ExportFormat.allCases.filter { !$0.supportsConcatenation }
        XCTAssertEqual(Set(blocked), Set([.pdf, .docx, .odt, .epub]))
        XCTAssertEqual(ExportFormat.allCases.filter(\.supportsConcatenation).count, 14)
    }

    // MARK: - ENEX / ENML

    private func enexNote(html: String, title: String = "Note") -> NotesNote {
        NotesNote(
            id: "1", title: title, plaintext: "", htmlBody: html,
            creationDate: Date(timeIntervalSince1970: 1_400_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_400_000_000),
            folderId: "10", accountId: "1", attachments: []
        )
    }

    /// A 1x1 PNG, so the converter has real bytes to hash and encode.
    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    func test_enex_movesEmbeddedImagesIntoResources() {
        let html = "<html><body><p>Before</p><img src=\"data:image/png;base64,\(Self.onePixelPNG)\" alt=\"x\"><p>After</p></body></html>"
        let enex = enexNote(html: html).toENEX()

        XCTAssertTrue(enex.contains("<resource>"), "image should become a resource")
        XCTAssertTrue(enex.contains("<en-media"), "content should reference the resource")
        XCTAssertFalse(enex.contains("data:image"), "no base64 should remain inline in the content")
        XCTAssertTrue(enex.contains("<mime>image/png</mime>"))
    }

    func test_enex_enMediaHashMatchesResourceBytes() throws {
        let html = "<body><img src=\"data:image/png;base64,\(Self.onePixelPNG)\"></body>"
        let enex = enexNote(html: html).toENEX()

        let hashes = matches(in: enex, pattern: #"<en-media[^>]*hash="([0-9a-f]{32})""#)
        XCTAssertEqual(hashes.count, 1)

        // The hash must be the MD5 of the decoded bytes, not of the base64.
        let payloads = matches(in: enex, pattern: #"<data encoding="base64">\s*([A-Za-z0-9+/=\s]+?)\s*</data>"#)
        XCTAssertEqual(payloads.count, 1)
        let raw = try XCTUnwrap(Data(base64Encoded: payloads[0].replacingOccurrences(of: "\n", with: "")))
        XCTAssertEqual(raw, Data(base64Encoded: Self.onePixelPNG))
    }

    func test_enex_stripsAttributesENMLDoesNotAllow() {
        // %coreattrs; in enml2.dtd is style and title only; class and id are not there.
        let html = "<body><div class=\"x\" id=\"y\" style=\"color:red\">Text</div></body>"
        let enex = enexNote(html: html).toENEX()
        XCTAssertFalse(enex.contains("class="))
        XCTAssertFalse(enex.contains("id="))
        XCTAssertTrue(enex.contains("style="), "style is permitted and should survive")
    }

    func test_enex_balancesUnclosedTags() {
        // The note HTML nests its own <html><body> inside the wrapper's, which
        // leaves elements open once the body span is taken.
        let html = "<body><div><p>Unclosed"
        let enex = enexNote(html: html).toENEX()
        let content = try? XCTUnwrap(enex.range(of: "<![CDATA["))
        XCTAssertNotNil(content)
        XCTAssertEqual(count(of: "<div", in: enex), count(of: "</div>", in: enex))
        XCTAssertEqual(count(of: "<p", in: enex), count(of: "</p>", in: enex))
    }

    func test_enex_escapesCDATATerminator() {
        let html = "<body><p>a ]]> b</p></body>"
        let enex = enexNote(html: html).toENEX()
        // Exactly one CDATA section may close the content element.
        XCTAssertTrue(enex.contains("]]]]><![CDATA[>"), "the terminator must be split")
    }

    func test_enex_declaresExport3AndDropsDisallowedElements() {
        let html = "<html><head><title>T</title><style>p{color:red}</style></head><body><script>evil()</script><p>Keep</p></body></html>"
        let enex = enexNote(html: html).toENEX()
        XCTAssertTrue(enex.contains("evernote-export3.dtd"))
        XCTAssertFalse(enex.contains("<script"))
        XCTAssertFalse(enex.contains("<style"))
        XCTAssertFalse(enex.contains("evil()"), "script contents must go, not just the tag")
        XCTAssertFalse(enex.contains("<title>T</title>"), "head contents must not leak into the body")
        XCTAssertTrue(enex.contains("Keep"))
    }

    // MARK: - Attachment export

    /// A repository that answers exactly what a test asks it to, including by
    /// failing. The shipped `MockNotesRepository` returns fixed data and an
    /// empty gallery, which cannot express these cases.
    private final class FakeNotesRepository: NotesRepository {
        var attachments: [String: Data] = [:]
        var filenames: [String: String] = [:]
        var galleries: [String: [GalleryChild]] = [:]
        var failingIds: Set<String> = []

        struct Missing: Error {}

        func fetchAttachment(id: String) async throws -> Data {
            if failingIds.contains(id) { throw Missing() }
            guard let data = attachments[id] else { throw Missing() }
            return data
        }
        func fetchAttachmentFilename(id: String) async -> String? { filenames[id] }
        func fetchGalleryChildren(galleryId: String, accountId: String?) async throws -> [GalleryChild] {
            if failingIds.contains(galleryId) { throw Missing() }
            return galleries[galleryId] ?? []
        }

        func fetchAccounts() async throws -> [NotesAccount] { [] }
        func fetchFolders() async throws -> [NotesFolder] { [] }
        func fetchNotes(includeDeleted: Bool) async throws -> [NotesNote] { [] }
        func generateHTML(forNoteId noteId: String) async throws -> String { "" }
        func fetchHierarchy(sortBy: NoteSortOption, foldersOnTop: Bool) async throws -> NotesHierarchy {
            NotesHierarchy.build(accounts: [], folders: [], notes: [], sortBy: sortBy, foldersOnTop: foldersOnTop)
        }
        func invalidateCache() {}
    }

    private func exportAttachments(
        _ attachments: [NotesAttachment],
        repository: FakeNotesRepository,
        into root: URL,
        sharedFolder: Bool = false
    ) async throws -> AttachmentExportResult {
        try await exportNoteAttachments(
            attachments,
            toDirectory: root,
            outputRoot: root,
            noteBaseName: "My Note",
            noteTitle: "My Note",
            creationDate: Date(timeIntervalSince1970: 1_400_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_400_000_000),
            sharedAttachmentsFolder: sharedFolder,
            repository: repository
        )
    }

    func test_attachments_galleryIsExpandedIntoItsChildren() async throws {
        // Regression: the CLI copy had no gallery branch, so it asked the parser
        // for the container's bytes -- which by design has none -- and every
        // gallery in a CLI, MCP or Shortcuts export silently lost its images.
        let root = try makeTempDirectory()
        let repo = FakeNotesRepository()
        let png = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))
        repo.galleries["gal-1"] = [
            GalleryChild(id: "child-1", data: png, filename: "one.png", uti: "public.png"),
            GalleryChild(id: "child-2", data: png, filename: "two.png", uti: "public.png")
        ]

        let result = try await exportAttachments(
            [NotesAttachment(id: "gal-1", typeUTI: "com.apple.notes.gallery", filename: nil)],
            repository: repo, into: root
        )

        XCTAssertEqual(result.failures, 0)
        // Both children, plus the container aliased to the first so the note's
        // own markup resolves.
        XCTAssertEqual(result.paths.count, 3)
        XCTAssertEqual(result.paths["gal-1"], result.paths["child-1"])
        for id in ["child-1", "child-2"] {
            let path = try XCTUnwrap(result.paths[id])
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                "\(id) was not written"
            )
        }
    }

    func test_attachments_collidingNamesWithoutExtensionDoNotEndInADot() async throws {
        let root = try makeTempDirectory()
        let repo = FakeNotesRepository()
        repo.attachments = ["a": Data("a".utf8), "b": Data("b".utf8)]
        repo.filenames = ["a": "noext", "b": "noext"]

        let result = try await exportAttachments(
            [NotesAttachment(id: "a", typeUTI: "public.data", filename: nil),
             NotesAttachment(id: "b", typeUTI: "public.data", filename: nil)],
            repository: repo, into: root
        )

        let second = try XCTUnwrap(result.paths["b"])
        XCTAssertFalse(second.hasSuffix("."), "collision suffix left a trailing dot: \(second)")
        XCTAssertTrue(second.hasSuffix("noext (2).bin"), second)
    }

    func test_attachments_extensionIsSniffedWhenUTIAndFilenameAreBothAbsent() async throws {
        // The CLI copy lacked this and wrote .bin for a perfectly good PNG.
        let root = try makeTempDirectory()
        let repo = FakeNotesRepository()
        repo.attachments = ["a": try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))]

        let result = try await exportAttachments(
            [NotesAttachment(id: "a", typeUTI: "public.item", filename: nil)],
            repository: repo, into: root
        )

        XCTAssertTrue(try XCTUnwrap(result.paths["a"]).hasSuffix(".png"))
    }

    func test_attachments_oneFailureDoesNotCostTheOthers() async throws {
        let root = try makeTempDirectory()
        let repo = FakeNotesRepository()
        repo.attachments = ["good": Data("ok".utf8)]
        repo.filenames = ["good": "good.txt"]
        repo.failingIds = ["bad"]

        let result = try await exportAttachments(
            [NotesAttachment(id: "bad", typeUTI: "public.data", filename: "bad.bin"),
             NotesAttachment(id: "good", typeUTI: "public.data", filename: nil)],
            repository: repo, into: root
        )

        XCTAssertEqual(result.failures, 1)
        XCTAssertNil(result.paths["bad"])
        XCTAssertNotNil(result.paths["good"], "a later attachment must still be exported")
        // The CLI reported nothing at all for a failed attachment, even with -v.
        XCTAssertEqual(result.events.filter { $0.severity == .warning }.count, 1)
    }

    func test_attachments_sharedFolderPathsAreRelativeToTheNote() async throws {
        let root = try makeTempDirectory()
        let repo = FakeNotesRepository()
        repo.attachments = ["a": Data("x".utf8)]
        repo.filenames = ["a": "doc.pdf"]

        let shared = try await exportAttachments(
            [NotesAttachment(id: "a", typeUTI: "com.adobe.pdf", filename: nil)],
            repository: repo, into: root, sharedFolder: true
        )
        let beside = try await exportAttachments(
            [NotesAttachment(id: "a", typeUTI: "com.adobe.pdf", filename: nil)],
            repository: repo, into: root, sharedFolder: false
        )

        XCTAssertTrue(try XCTUnwrap(shared.paths["a"]).contains("Attachments/"), shared.paths["a"] ?? "")
        XCTAssertTrue(try XCTUnwrap(beside.paths["a"]).contains("(Attachments)"), beside.paths["a"] ?? "")
    }

    // MARK: - Prune safety

    func test_prune_isSkippedEntirelyWhenTheLibraryCouldNotBeRead() {
        // Regression: a failed library read was collapsed into an empty set,
        // so pruning judged "deleted from Apple Notes" against this run's
        // selection and removed the exported files of every unselected note.
        XCTAssertNil(prunePresentNoteIds(libraryNoteIds: nil, selectedNoteIds: ["a", "b"]))
    }

    func test_prune_judgesAgainstTheWholeLibraryNotTheSelection() {
        let present = prunePresentNoteIds(
            libraryNoteIds: ["a", "b", "c"],
            selectedNoteIds: ["a"]
        )
        // "b" and "c" were not exported this run but still exist, so they must
        // be counted present or their files would be deleted.
        XCTAssertEqual(present, ["a", "b", "c"])
    }

    func test_prune_includesSelectedNotesMissingFromTheLibrarySnapshot() {
        let present = prunePresentNoteIds(libraryNoteIds: ["a"], selectedNoteIds: ["b"])
        XCTAssertEqual(present, ["a", "b"])
    }

    // MARK: - Export destination

    func test_destination_cannotBeBothZipAndTar() {
        // The three booleans could express this; the two-axis model cannot.
        var configs = ExportConfigurations.default
        configs.zipOutput = true
        configs.tarOutput = true

        XCTAssertFalse(configs.zipOutput, "setting tar must clear zip")
        XCTAssertTrue(configs.tarOutput)
        XCTAssertEqual(configs.archiveFormat, .tar)
    }

    func test_destination_clearingOneArchiveDoesNotClearTheOther() {
        // The GUI sets the one it wants then clears the others in sequence.
        var configs = ExportConfigurations.default
        configs.tarOutput = true
        configs.zipOutput = false          // was never zip; must be a no-op

        XCTAssertEqual(configs.archiveFormat, .tar)

        configs.tarOutput = false
        XCTAssertNil(configs.archiveFormat)
    }

    func test_destination_singleFileInsideAnArchiveIsRepresentable() {
        // --zip --concatenate is a supported CLI combination. A single
        // four-case destination enum would have silently deleted it.
        var configs = ExportConfigurations.default
        configs.zipOutput = true
        configs.concatenateOutput = true

        XCTAssertEqual(configs.destination.container, .zip)
        XCTAssertEqual(configs.destination.layout, .singleFile)
        XCTAssertEqual(configs.archiveFormat, .zip)
        XCTAssertTrue(configs.concatenateOutput)
    }

    func test_destination_migratesFromTheLegacyBooleans() throws {
        // Settings saved before the destination became one value must survive.
        let legacy = """
        {"html":\(try encoded(ExportConfigurations.default.html)),
         "pdf":\(try encoded(ExportConfigurations.default.pdf)),
         "latex":\(try encoded(ExportConfigurations.default.latex)),
         "rtf":\(try encoded(ExportConfigurations.default.rtf)),
         "tarOutput":true,"concatenateOutput":true}
        """
        let decoded = try JSONDecoder().decode(
            ExportConfigurations.self, from: Data(legacy.utf8))

        XCTAssertEqual(decoded.destination.container, .tar)
        XCTAssertEqual(decoded.destination.layout, .singleFile)
        XCTAssertTrue(decoded.tarOutput)
        XCTAssertTrue(decoded.concatenateOutput)
    }

    func test_destination_survivesARoundTrip() throws {
        var configs = ExportConfigurations.default
        configs.zipOutput = true
        configs.concatenateOutput = true

        let data = try JSONEncoder().encode(configs)
        let decoded = try JSONDecoder().decode(ExportConfigurations.self, from: data)

        XCTAssertEqual(decoded.destination, configs.destination)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "{}"
    }

    // MARK: - Format bridges that cannot be derived

    func test_everyFormat_roundTripsThroughItsAdvertisedToken() {
        // The CLI parser switches over arbitrary user text, so it cannot be
        // exhaustive. A format added to the enum but not to that switch would
        // be unreachable from the CLI and MCP with nothing failing to compile.
        for format in ExportFormat.allCases {
            XCTAssertEqual(
                ExportFormat(cliString: format.cliToken), format,
                "\(format.rawValue) is not reachable by its advertised token '\(format.cliToken)'"
            )
            XCTAssertEqual(
                ExportFormat(cliString: format.rawValue), format,
                "\(format.rawValue) is not reachable by its raw value"
            )
        }
    }

    func test_advertisedTokensListsEveryFormat() {
        // Regression: the CLI's "Valid formats:" line was hand-written and
        // omitted pdf.
        let advertised = ExportFormat.advertisedTokens
        for format in ExportFormat.allCases {
            XCTAssertTrue(
                advertised.contains(format.cliToken),
                "\(format.rawValue) is missing from the advertised list"
            )
        }
    }

    @available(macOS 13.0, *)
    func test_everyFormat_hasAShortcutsOption() throws {
        // AppIntents bridges two hand-maintained enums with a force unwrap
        // (`ExportFormat(rawValue: self.rawValue)!`), so a mismatch traps inside
        // a Shortcut instead of failing to build. Nothing could check this until
        // AppIntents.swift was added to the app target: it was absent from
        // project.pbxproj, so the whole Shortcuts integration compiled into
        // nothing and the type did not exist.
        for format in ExportFormat.allCases {
            let option = ExportFormatOption(rawValue: format.rawValue)
            XCTAssertNotNil(option, "\(format.rawValue) has no Shortcuts option; the force unwrap would trap")
            XCTAssertEqual(option?.toExportFormat, format)
        }
        for option in ExportFormatOption.allCases {
            XCTAssertNotNil(
                ExportFormat(rawValue: option.rawValue),
                "\(option.rawValue) has no matching ExportFormat"
            )
        }
    }

    func test_archiveFormats_haveDistinctExtensions() {
        let extensions = ExportArchiveFormat.allCases.map(\.fileExtension)
        XCTAssertEqual(Set(extensions).count, extensions.count, "archive extensions collide")
        for archive in ExportArchiveFormat.allCases {
            XCTAssertFalse(archive.displayName.isEmpty)
            XCTAssertFalse(archive.systemImage.isEmpty)
        }
    }

    // MARK: - Per-format HTML configuration

    func test_htmlConfiguration_markdownLinksImagesRatherThanEmbeddingThem() {
        // Regression: the app applied this and the CLI did not, so
        // `--format markdown` wrote multi-megabyte base64 data URIs into the
        // .md where the app wrote a relative link to the exported file.
        var base = ExportConfigurations.default.html
        base.embedImagesInline = true
        base.linkEmbeddedImages = false

        let markdown = htmlConfiguration(for: .markdown, base: base)
        XCTAssertFalse(markdown.embedImagesInline)
        XCTAssertTrue(markdown.linkEmbeddedImages)
    }

    func test_htmlConfiguration_plainTextCarriesNoImagesAtAll() {
        var base = ExportConfigurations.default.html
        base.embedImagesInline = true
        base.linkEmbeddedImages = true

        let txt = htmlConfiguration(for: .txt, base: base)
        XCTAssertFalse(txt.embedImagesInline)
        XCTAssertFalse(txt.linkEmbeddedImages)
    }

    func test_htmlConfiguration_leavesEveryOtherFormatAsConfigured() {
        var base = ExportConfigurations.default.html
        base.embedImagesInline = true
        base.linkEmbeddedImages = true

        for format in ExportFormat.allCases where format != .txt && format != .markdown {
            let config = htmlConfiguration(for: format, base: base)
            XCTAssertEqual(config.embedImagesInline, base.embedImagesInline, format.rawValue)
            XCTAssertEqual(config.linkEmbeddedImages, base.linkEmbeddedImages, format.rawValue)
        }
    }

    // MARK: - Format dispatch honours configuration

    func test_textContent_usesTheConfiguredRTFFontAndLaTeXTemplate() {
        // The shared dispatch hardcoded Helvetica 12 and the default template,
        // so CLI, MCP and Shortcuts ignored the user's RTF and LaTeX settings.
        let note = enexNote(html: "<html><body><p>Body</p></body></html>", title: "T")

        let rtf = generateExportTextContent(
            for: note, format: .rtf, folderName: nil, accountName: nil,
            rtfFontFamily: "Courier", rtfFontSize: 18
        )
        XCTAssertTrue(rtf.contains("Courier"), "configured RTF font was ignored")
        XCTAssertTrue(rtf.contains("36"), "configured RTF size was ignored (half-points)")

        let tex = generateExportTextContent(
            for: note, format: .tex, folderName: nil, accountName: nil,
            latexTemplate: "CUSTOM-TEMPLATE APPLE_NOTES_EXPORTER_NOTE_CONTENT"
        )
        XCTAssertTrue(tex.hasPrefix("CUSTOM-TEMPLATE"), "configured LaTeX template was ignored")
    }

    func test_textContent_writesFolderAndAccountNamesWhenGiven() {
        // The CLI passed nil for both, so its JSON/XML/CSV carried raw Core
        // Data folder ids where the app wrote human-readable names.
        let note = enexNote(html: "<html><body><p>Body</p></body></html>", title: "T")

        let json = generateExportTextContent(
            for: note, format: .json, folderName: "Work", accountName: "iCloud"
        )
        XCTAssertTrue(json.contains("Work"), json)
        XCTAssertTrue(json.contains("iCloud"), json)
        XCTAssertFalse(json.contains("\"folder\" : \"10\""), "fell back to the folder id")
    }

    // MARK: - Output extension recognition

    func test_exportProducedExtensions_coversEveryFormatAndArchive() {
        // Regression: the MCP copy of this set was hand-written as ["zip"] and
        // silently missed "tar" when the TAR destination was added.
        for format in ExportFormat.allCases {
            XCTAssertTrue(
                exportProducedExtensions.contains(format.fileExtension),
                "\(format.rawValue) is not recognised as an output extension"
            )
        }
        for archive in ExportArchiveFormat.allCases {
            XCTAssertTrue(
                exportProducedExtensions.contains(archive.fileExtension),
                "\(archive.rawValue) is not recognised as an output extension"
            )
        }
        XCTAssertFalse(exportProducedExtensions.contains("notes"))
    }

    // MARK: - Single file assembly

    func test_concatenatedENEX_isOneDocumentWithOneRoot() {
        // Regression: each note produced a whole <en-export> document and the
        // parts were simply joined, so the file had N XML declarations and N
        // root elements. No importer accepts that.
        // Note that each note's CDATA content is itself an ENML document with
        // its own <?xml?> declaration, which is correct; it is the *export*
        // document that must occur exactly once.
        let parts = (1...3).map { enexNote(html: "<body><p>Note \($0)</p></body>", title: "N\($0)").toENEXNoteElement() }
        let document = ConcatenatedExport.assemble(parts, format: .enex)

        XCTAssertTrue(document.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertEqual(count(of: "<!DOCTYPE en-export", in: document), 1)
        XCTAssertEqual(count(of: "<en-export ", in: document), 1)
        XCTAssertEqual(count(of: "</en-export>", in: document), 1)
        XCTAssertEqual(count(of: "<note>", in: document), 3)
        XCTAssertEqual(count(of: "</note>", in: document), 3)
        XCTAssertTrue(document.contains("evernote-export3.dtd"))
    }

    func test_concatenatedENEX_parsesAsXML() throws {
        // The structural assertions above would still pass on a file that no
        // parser accepts, so actually parse it.
        let parts = (1...3).map {
            enexNote(html: "<body><p>Note \($0) &amp; more</p></body>", title: "N & \($0)").toENEXNoteElement()
        }
        let document = ConcatenatedExport.assemble(parts, format: .enex)

        let parser = XMLParser(data: try XCTUnwrap(document.data(using: .utf8)))
        parser.shouldResolveExternalEntities = false
        XCTAssertTrue(
            parser.parse(),
            "concatenated ENEX must be well formed: \(parser.parserError?.localizedDescription ?? "unknown")"
        )
    }

    func test_concatenatedXMLAndOPML_areOneDocumentEach() throws {
        // Found by the export matrix: ENEX was fixed but XML and OPML had the
        // same defect, N complete documents joined into one file.
        let notes = (1...3).map {
            enexNote(html: "<html><body><p>Note \($0)</p></body></html>", title: "N\($0)")
        }

        let xml = ConcatenatedExport.assemble(notes.map { $0.toXMLNoteElement() }, format: .xml)
        let xmlParser = XMLParser(data: try XCTUnwrap(xml.data(using: .utf8)))
        XCTAssertTrue(xmlParser.parse(),
                      "concatenated XML must parse: \(xmlParser.parserError?.localizedDescription ?? "")")
        XCTAssertEqual(count(of: "<?xml", in: xml), 1)
        XCTAssertEqual(count(of: "<note>", in: xml), 3)

        let opml = ConcatenatedExport.assemble(notes.map { $0.toOPMLOutline() }, format: .opml)
        let opmlParser = XMLParser(data: try XCTUnwrap(opml.data(using: .utf8)))
        XCTAssertTrue(opmlParser.parse(),
                      "concatenated OPML must parse: \(opmlParser.parserError?.localizedDescription ?? "")")
        XCTAssertEqual(count(of: "<?xml", in: opml), 1)
        XCTAssertEqual(count(of: "<opml", in: opml), 1)
    }

    func test_opmlEscapesEntitiesOnceNotTwice() {
        // OPML stripped tags but not entities, then escaped, so a note
        // containing "&" came out as "&amp;amp;".
        let note = enexNote(html: "<html><body><p>Tom &amp; Jerry &lt;x&gt;</p></body></html>")
        let opml = note.toOPML()

        XCTAssertTrue(opml.contains("&amp; Jerry"), opml)
        XCTAssertFalse(opml.contains("&amp;amp;"), "entity was escaped twice")
        XCTAssertFalse(opml.contains("&amp;lt;"), "entity was escaped twice")
    }

    func test_singleNoteXML_stillHasNoteAsItsRoot() throws {
        let xml = enexNote(html: "<html><body><p>Solo</p></body></html>").toXML()
        let parser = XMLParser(data: try XCTUnwrap(xml.data(using: .utf8)))
        XCTAssertTrue(parser.parse())
        XCTAssertEqual(count(of: "<?xml", in: xml), 1)
        XCTAssertFalse(xml.contains("<notes>"), "a single-note document keeps <note> as its root")
    }

    func test_singleNoteENEX_stillEmitsCompleteDocument() {
        let enex = enexNote(html: "<body><p>Solo</p></body>").toENEX()
        XCTAssertTrue(enex.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertEqual(count(of: "<!DOCTYPE en-export", in: enex), 1)
        XCTAssertEqual(count(of: "<en-export ", in: enex), 1)
        XCTAssertEqual(count(of: "</en-export>", in: enex), 1)
        XCTAssertEqual(count(of: "<note>", in: enex), 1)
    }

    func test_concatenatedJSONIsAnArrayAndCSVGetsItsHeader() {
        // The CLI applied neither, so its single-file JSON was bare objects
        // joined by a Markdown rule and its CSV had no header row.
        let json = ConcatenatedExport.assemble(["{\"a\":1}", "{\"a\":2}"], format: .json)
        XCTAssertTrue(json.hasPrefix("["))
        XCTAssertTrue(json.hasSuffix("]"))
        XCTAssertTrue(json.contains("},\n{"))

        let csv = ConcatenatedExport.assemble(["r1", "r2"], format: .csv)
        XCTAssertTrue(csv.hasPrefix(NotesNote.csvHeader()))
        XCTAssertTrue(csv.contains("r1\nr2"))
    }

    func test_everyConcatenatableFormatHasANonEmptySeparator() {
        // A format added later must not fall through to a default meant for
        // prose and end up splicing a Markdown rule into a structured document.
        for format in ExportFormat.allCases where format.supportsConcatenation {
            XCTAssertFalse(
                ConcatenatedExport.separator(for: format).isEmpty,
                "\(format.rawValue) joins notes with an empty separator"
            )
        }
    }

    // MARK: - ENEX attachment resources

    func test_enex_carriesLinkedAttachmentsAsResources() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdfBytes = Data("%PDF-1.4 fake".utf8)
        let relativePath = "Note (Attachments)/report.pdf"
        let fileURL = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdfBytes.write(to: fileURL)

        let html = "<body><p>See <a href=\"\(relativePath)\">report.pdf</a></p></body>"
        let resources = linkedAttachmentResources(
            linkedIn: html, paths: ["att-1": relativePath], outputRoot: directory)

        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(resources.first?.mime, "application/pdf")
        XCTAssertEqual(resources.first?.filename, "report.pdf")

        let enex = enexNote(html: html).toENEX(attachmentResources: resources)
        XCTAssertTrue(enex.contains("<mime>application/pdf</mime>"))
        XCTAssertTrue(enex.contains("<file-name>report.pdf</file-name>"))
        XCTAssertTrue(enex.contains("<en-media"), "the link must become an en-media reference")
        XCTAssertFalse(enex.contains("href="), "a link to a sibling file cannot survive the import")

        // The en-media hash must be the MD5 of the resource bytes.
        let hashes = matches(in: enex, pattern: #"<en-media[^>]*hash="([0-9a-f]{32})""#)
        XCTAssertEqual(hashes.count, 1)
        let payloads = matches(in: enex, pattern: #"<data encoding="base64">\s*([A-Za-z0-9+/=\s]+?)\s*</data>"#)
        let raw = try XCTUnwrap(Data(base64Encoded: payloads[0].replacingOccurrences(of: "\n", with: "")))
        XCTAssertEqual(raw, pdfBytes)
    }

    func test_enex_doesNotEmbedAttachmentsTheMarkupNeverLinks() throws {
        // An inline image is already a resource; attaching the file copy too
        // would put the same bytes on the note twice.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let relativePath = "Note (Attachments)/photo.png"
        let fileURL = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG)).write(to: fileURL)

        let html = "<body><img src=\"data:image/png;base64,\(Self.onePixelPNG)\"></body>"
        let resources = linkedAttachmentResources(
            linkedIn: html, paths: ["att-1": relativePath], outputRoot: directory)

        XCTAssertTrue(resources.isEmpty, "nothing links to the file, so it must not be embedded again")

        let enex = enexNote(html: html).toENEX(attachmentResources: resources)
        XCTAssertEqual(count(of: "<resource>", in: enex), 1, "the image should appear exactly once")
    }

    private func matches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    private func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
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

    func test_tarDirectory_roundTripsAndPreservesModificationDates() throws {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("Apple Notes Export")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("iCloud/Notes"), withIntermediateDirectories: true
        )
        let note = source.appendingPathComponent("iCloud/Notes/Old Note.md")
        try Data("aged".utf8).write(to: note)

        let created = Date(timeIntervalSince1970: 1_100_000_000)
        let modified = Date(timeIntervalSince1970: 1_400_000_000)
        try setExportFileTimestamps(note, creationDate: created, modificationDate: modified)

        let archive = root.appendingPathComponent("Apple Notes Export.tar")
        try createArchive(.tar, at: source, to: archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let unpacked = root.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let untar = Process()
        untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untar.arguments = ["-xf", archive.path, "-C", unpacked.path]
        try untar.run()
        untar.waitUntilExit()
        XCTAssertEqual(untar.terminationStatus, 0)

        let restored = unpacked.appendingPathComponent("Apple Notes Export/iCloud/Notes/Old Note.md")
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), "aged")

        let attrs = try FileManager.default.attributesOfItem(atPath: restored.path)
        let restoredModified = try XCTUnwrap(attrs[.modificationDate] as? Date)
        XCTAssertEqual(
            restoredModified.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 2,
            "modification date did not survive the tar"
        )
    }

    func test_tarDirectory_archiveRootIsTheFolderNotAnAbsolutePath() throws {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("Trip Notes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appendingPathComponent("a.md"))

        let archive = root.appendingPathComponent("Trip Notes.tar")
        try createArchive(.tar, at: source, to: archive)

        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        list.arguments = ["-tf", archive.path]
        let pipe = Pipe()
        list.standardOutput = pipe
        try list.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        list.waitUntilExit()

        XCTAssertTrue(out.contains("Trip Notes/"), "archive should be rooted at the folder, got: \(out)")
        XCTAssertFalse(out.contains(root.path), "archive must not embed an absolute path")
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
