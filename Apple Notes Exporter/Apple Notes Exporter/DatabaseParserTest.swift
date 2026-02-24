//
//  DatabaseParserTest.swift
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

import Foundation

func testDatabaseParser() {
    print("=== Testing Database Parser ===")

    let parser = AppleNotesDatabaseParser()

    guard parser.open() else {
        print("❌ Failed to open database")
        return
    }

    defer { parser.close() }

    // Test accounts
    print("\n📁 Fetching accounts...")
    let accounts = parser.fetchAccounts()
    print("Found \(accounts.count) accounts:")
    for account in accounts {
        print("  - [\(account.id)] \(account.name) (\(account.identifier))")
    }

    // Debug: Show all account-like entries
    print("\n🔍 Debug: Checking for all potential accounts in database...")
    // This will help us see if there are other accounts we're missing

    // Test folders
    print("\n📂 Fetching folders...")
    let folders = parser.fetchFolders()
    print("Found \(folders.count) folders:")
    for folder in folders.prefix(5) {
        print("  - [\(folder.id)] \(folder.name) (account: \(folder.accountId), parent: \(folder.parentId ?? -1))")
    }

    // Test notes
    print("\n📝 Fetching notes (first 3)...")
    let notes = parser.fetchNotes()
    print("Found \(notes.count) total notes")

    for note in notes.prefix(3) {
        print("\n--- Note \(note.id) ---")
        print("Title: \(note.title)")
        print("Created: \(note.creationDate)")
        print("Modified: \(note.modificationDate)")
        print("Folder ID: \(note.folderId)")
        print("Plaintext length: \(note.plaintext.count) chars")
        print("HTML length: \(note.htmlBody.count) chars")
        print("Attachments: \(note.attachments.count)")
        if note.plaintext.count > 0 {
            let preview = String(note.plaintext.prefix(100))
            print("Preview: \(preview)...")
        }
    }

    print("\n✅ Test complete!")
}
