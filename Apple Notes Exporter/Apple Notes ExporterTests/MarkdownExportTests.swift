//
//  MarkdownExportTests.swift
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
