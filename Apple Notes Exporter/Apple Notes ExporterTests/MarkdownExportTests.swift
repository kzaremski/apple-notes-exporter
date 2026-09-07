//
//  MarkdownExportTests.swift
//  Apple Notes ExporterTests
//
//  Copyright (C) 2026 Konstantin Zaremski
//  Licensed under GPL v3.
//

import XCTest
import Foundation
@testable import Apple_Notes_Exporter

final class MarkdownExportTests: XCTestCase {

    private func sampleNote(html: String) -> NotesNote {
        NotesNote(
            id: "test-note",
            title: "Test",
            plaintext: "",
            htmlBody: html,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            folderId: "folder",
            accountId: "account",
            attachments: []
        )
    }

    func testMarkdownDecodesHTMLEntitiesAfterStrippingTags() {
        let note = sampleNote(
            html: "<html><body><p>Tom &amp; Jerry: &lt;example&gt; &quot;quoted&quot; &#169; &#x1F600;</p></body></html>"
        )

        XCTAssertEqual(
            note.toMarkdown(),
            "Tom & Jerry: <example> \"quoted\" © 😀"
        )
    }

    func testRTFStillDecodesHTMLEntities() {
        let note = sampleNote(
            html: "<html><body><p>Tom &amp; Jerry &#169; &#x1F600;</p></body></html>"
        )
        let rtf = note.toRTF()

        XCTAssertTrue(rtf.contains("Tom & Jerry"))
        XCTAssertTrue(rtf.contains("\\u169?"))
        XCTAssertTrue(rtf.contains("\\u-10179?\\u-8704?"))
    }
}
