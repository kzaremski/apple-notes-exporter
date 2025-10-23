//
//  DatabaseParserTest.swift
//  Apple Notes Exporter
//
//  Simple test to verify database parser works
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
