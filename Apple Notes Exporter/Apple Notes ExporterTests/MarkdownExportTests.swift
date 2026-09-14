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

    func testPlainTextDropsImagesRatherThanEmittingBase64() {
        // Regression: plain text stripped only a fixed list of tags, so an
        // <img> survived whole and a TXT export of a note with an inline image
        // contained the entire base64 data URI.
        let note = sampleNote(
            html: "<html><body><p>Before</p><img src=\"data:image/jpeg;base64,/9j/4AAQSkZJRg==\" alt=\"x\"><p>After</p></body></html>"
        )
        let text = note.toPlainText()

        XCTAssertFalse(text.contains("base64"))
        XCTAssertFalse(text.contains("<img"))
        XCTAssertTrue(text.contains("Before"))
        XCTAssertTrue(text.contains("After"))
    }

    func testPlainTextStripsStructuralTagsAndDecodesEntities() {
        // The note's own markup nests inside the export wrapper, so a second
        // <html><body> pair reaches the converter and must not be left behind.
        let note = sampleNote(
            html: "<html><body><html><body><p>Rack Hardware &amp; Patch Cables</p></body></html></body></html>"
        )

        XCTAssertEqual(note.toPlainText(), "Rack Hardware & Patch Cables")
    }

    func testPlainTextKeepsLinkURLs() {
        let note = sampleNote(
            html: "<html><body><p>See <a href=\"https://example.com\">this</a></p></body></html>"
        )

        XCTAssertTrue(note.toPlainText().contains("this (https://example.com)"))
    }

    func testBodyExtractionToleratesAttributesAndCase() {
        XCTAssertEqual(extractHTMLBody("<html><body class=\"x\" dir=\"rtl\"><p>Keep</p></body></html>"),
                       "<p>Keep</p>")
        XCTAssertEqual(extractHTMLBody("<BODY><p>Keep</p></BODY>"), "<p>Keep</p>")
        // No closing tag: take everything after the opening one rather than
        // giving up and handing back the whole document.
        XCTAssertEqual(extractHTMLBody("<body><p>Unclosed"), "<p>Unclosed")
        // No body at all: the input is already a fragment.
        XCTAssertEqual(extractHTMLBody("<p>Fragment</p>"), "<p>Fragment</p>")
    }

    func testConvertersDoNotLeakTheDocumentWrapperWhenBodyHasAttributes() {
        // Regression: seven converters each matched the literal "<body>" and
        // returned the input unchanged on failure, so one attribute added to
        // the export template would push <!DOCTYPE>, <head> and <style>
        // through the escaper as if they were note text.
        let note = sampleNote(
            html: "<!DOCTYPE html><html><head><style>p{color:red}</style></head>"
                + "<body class=\"export\"><p>Keep</p></body></html>"
        )

        for (name, output) in [("markdown", note.toMarkdown()),
                               ("org", note.toOrg()),
                               ("rst", note.toRST()),
                               ("asciidoc", note.toAsciiDoc()),
                               ("plaintext", note.toPlainText())] {
            XCTAssertTrue(output.contains("Keep"), "\(name) lost the note text")
            XCTAssertFalse(output.contains("DOCTYPE"), "\(name) leaked the document wrapper")
            XCTAssertFalse(output.contains("color:red"), "\(name) leaked the stylesheet")
        }
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
