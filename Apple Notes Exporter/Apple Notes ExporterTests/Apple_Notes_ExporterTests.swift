//
//  Apple_Notes_ExporterTests.swift
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
//  Suite-level setup placeholder. Actual test cases live in topic-specific
//  files (ExportSupportTests.swift, etc.).
//

import XCTest
@testable import Apple_Notes_Exporter

final class Apple_Notes_ExporterTests: XCTestCase {
    // Intentionally empty. Add tests in topic-specific files within this target.
}

final class NotesHierarchyRobustnessTests: XCTestCase {

    private func account(_ id: String, name: String = "iCloud") -> NotesAccount {
        NotesAccount(id: id, name: name, identifier: "id-\(id)", accountType: .iCloud)
    }

    private func folder(_ id: String, name: String, parent: String?, account: String) -> NotesFolder {
        NotesFolder(id: id, name: name, parentId: parent, accountId: account)
    }

    private func note(_ id: String, folder: String, account: String) -> NotesNote {
        NotesNote(
            id: id,
            title: "Note \(id)",
            plaintext: "body",
            htmlBody: nil,
            creationDate: Date(),
            modificationDate: Date(),
            folderId: folder,
            accountId: account,
            attachments: []
        )
    }

    func test_orphanFolderWithDanglingParent_becomesRoot() {
        let acct = account("1")
        let folders = [
            folder("10", name: "Work", parent: "999", account: "1")
        ]
        let notes = [note("100", folder: "10", account: "1")]

        let tree = NotesHierarchy.build(accounts: [acct], folders: folders, notes: notes)
        XCTAssertEqual(tree.accounts.count, 1)
        XCTAssertEqual(tree.accounts[0].folders.count, 1)
        XCTAssertEqual(tree.accounts[0].folders[0].folder.name, "Work")
        XCTAssertEqual(tree.accounts[0].folders[0].totalNoteCount, 1)
    }

    func test_folderWithUnknownAccount_inferredFromNotes() {
        let acct = account("1")
        let folders = [
            folder("10", name: "Inbox", parent: nil, account: "")
        ]
        let notes = [note("100", folder: "10", account: "1")]

        let tree = NotesHierarchy.build(accounts: [acct], folders: folders, notes: notes)
        XCTAssertEqual(tree.accounts[0].folders.first?.totalNoteCount, 1)
    }

    // The tree has to agree with what the exporter writes to disk. Loose notes
    // go to the account's default folder in both, not to a separate "Unfiled"
    // node that exists only in the UI.

    func test_notesWithoutFolder_landInDefaultFolderWhenThereAreNoFolders() {
        let acct = account("1")
        let notes = [note("100", folder: "missing", account: "1")]

        let tree = NotesHierarchy.build(accounts: [acct], folders: [], notes: notes)
        XCTAssertEqual(tree.accounts[0].folders.count, 1)
        XCTAssertEqual(tree.accounts[0].folders[0].folder.name, fallbackNotesFolderName)
        XCTAssertEqual(tree.accounts[0].folders[0].notes.count, 1)
    }

    func test_notesWithoutFolder_mergeIntoExistingDefaultFolderNode() {
        let acct = account("1")
        let defaultFolder = NotesFolder(
            id: "10", name: "Notes", parentId: nil, accountId: "1",
            identifier: "DefaultFolder-CloudKit"
        )
        let notes = [
            note("100", folder: "10", account: "1"),
            note("101", folder: "missing", account: "1")
        ]

        let tree = NotesHierarchy.build(accounts: [acct], folders: [defaultFolder], notes: notes)
        XCTAssertEqual(tree.accounts[0].folders.count, 1, "should not add a sibling node")
        XCTAssertEqual(tree.accounts[0].folders[0].folder.name, "Notes")
        XCTAssertEqual(tree.accounts[0].folders[0].totalNoteCount, 2)
    }

    func test_notesWithoutFolder_useLocalizedDefaultFolderName() {
        let acct = account("1")
        let localized = NotesFolder(
            id: "10", name: "Notizen", parentId: nil, accountId: "1",
            identifier: "DefaultFolder-CloudKit"
        )
        let notes = [note("100", folder: "missing", account: "1")]

        let tree = NotesHierarchy.build(accounts: [acct], folders: [localized], notes: notes)
        XCTAssertEqual(tree.accounts[0].folders.count, 1)
        XCTAssertEqual(tree.accounts[0].folders[0].folder.name, "Notizen")
        XCTAssertEqual(tree.accounts[0].folders[0].totalNoteCount, 1)
    }
}
