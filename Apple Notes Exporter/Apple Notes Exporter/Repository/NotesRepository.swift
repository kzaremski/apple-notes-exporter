//
//  NotesRepository.swift
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
import OSLog
import SQLite3

// MARK: - Repository Protocol

/// Protocol defining all Notes data access operations
protocol NotesRepository {
    /// Fetch all accounts from the Notes database
    func fetchAccounts() async throws -> [NotesAccount]

    /// Fetch all folders from the Notes database
    func fetchFolders() async throws -> [NotesFolder]

    /// Fetch all notes from the Notes database
    func fetchNotes() async throws -> [NotesNote]

    /// Fetch binary data for a specific attachment
    func fetchAttachment(id: String) async throws -> Data

    /// Fetch filename for a specific attachment
    func fetchAttachmentFilename(id: String) async -> String?

    /// Generate HTML for a specific note (called during export)
    func generateHTML(forNoteId noteId: String) async throws -> String

    /// Build complete hierarchy of accounts, folders, and notes
    func fetchHierarchy(sortBy: NoteSortOption, foldersOnTop: Bool) async throws -> NotesHierarchy
}

// MARK: - Repository Errors

enum RepositoryError: Error, LocalizedError {
    case databaseUnavailable
    case itemNotFound(String)
    case attachmentNotFound(String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "Unable to access the Notes database. Please ensure Full Disk Access is granted."
        case .itemNotFound(let id):
            return "Item with ID '\(id)' was not found in the database."
        case .attachmentNotFound(let id):
            return "Attachment '\(id)' was not found or could not be retrieved."
        case .decodingError(let details):
            return "Failed to decode data from database: \(details)"
        }
    }
}

// MARK: - Database Implementation (C Parser Backend)

/// Concrete implementation using the C AppleNotesKit parser
class DatabaseNotesRepository: NotesRepository, @unchecked Sendable {
    let databasePath: String

    /// Initialize with custom database path (useful for testing)
    init(databasePath: String = "\(NSHomeDirectory())/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite") {
        self.databasePath = databasePath
    }

    // MARK: - Internal C Handle Helpers

    /// Open a C parser handle. Caller must call ane_close() when done.
    private func openDB() -> OpaquePointer? {
        return ane_open(databasePath)
    }

    // MARK: - Fetch Methods

    func fetchAccounts() async throws -> [NotesAccount] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let db = self.openDB() else {
                    continuation.resume(throwing: RepositoryError.databaseUnavailable)
                    return
                }
                defer { ane_close(db) }

                var count: Int = 0
                guard let raw = ane_fetch_accounts(db, &count), count > 0 else {
                    continuation.resume(returning: [])
                    return
                }
                defer { ane_free_accounts(raw, count) }

                var accounts: [NotesAccount] = []
                accounts.reserveCapacity(count)

                for i in 0..<count {
                    let a = raw[i]
                    let identifier = a.identifier != nil ? String(cString: a.identifier) : ""
                    let name = a.name != nil ? String(cString: a.name) : "Unknown"

                    // Map account_type from C (ZACCOUNTTYPE): -1=unknown, 0=local, 1=exchange, 2=imap, 3=iCloud, 4=google
                    let accountType: NotesAccount.AccountType
                    switch a.account_type {
                    case 0: accountType = .local
                    case 1: accountType = .exchange
                    case 2: accountType = .imap
                    case 3: accountType = .iCloud
                    case 4: accountType = .google
                    default: accountType = .iCloud  // Default for unknown
                    }

                    accounts.append(NotesAccount(
                        id: "\(a.pk)",
                        name: name,
                        identifier: identifier,
                        accountType: accountType
                    ))
                }

                continuation.resume(returning: accounts)
            }
        }
    }

    func fetchFolders() async throws -> [NotesFolder] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let db = self.openDB() else {
                    continuation.resume(throwing: RepositoryError.databaseUnavailable)
                    return
                }
                defer { ane_close(db) }

                var count: Int = 0
                guard let raw = ane_fetch_folders(db, &count), count > 0 else {
                    continuation.resume(returning: [])
                    return
                }
                defer { ane_free_folders(raw, count) }

                var folders: [NotesFolder] = []
                folders.reserveCapacity(count)

                for i in 0..<count {
                    let f = raw[i]
                    let title = f.title != nil ? String(cString: f.title) : "Untitled"

                    folders.append(NotesFolder(
                        id: "\(f.pk)",
                        name: title,
                        parentId: f.parent_pk >= 0 ? "\(f.parent_pk)" : nil,
                        accountId: "\(f.account_pk)"
                    ))
                }

                continuation.resume(returning: folders)
            }
        }
    }

    func fetchNotes() async throws -> [NotesNote] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let db = self.openDB() else {
                    continuation.resume(throwing: RepositoryError.databaseUnavailable)
                    return
                }
                defer { ane_close(db) }

                var count: Int = 0
                guard let raw = ane_fetch_notes(db, &count), count > 0 else {
                    continuation.resume(returning: [])
                    return
                }
                defer { ane_free_notes(raw, count) }

                // Create HTML generator with the C parser's sqlite handle for inline queries
                let htmlGen = NoteHTMLGenerator(database: db)

                var notes: [NotesNote] = []
                notes.reserveCapacity(count)

                for i in 0..<count {
                    let n = raw[i]
                    let title = n.title != nil ? String(cString: n.title) : "Untitled"

                    // Convert CoreTime dates to Swift Date
                    // CoreTime is seconds since 2001-01-01, Date(timeIntervalSinceReferenceDate:) uses the same epoch
                    let creationDate = Date(timeIntervalSinceReferenceDate: n.creation_date)
                    let modificationDate = Date(timeIntervalSinceReferenceDate: n.modification_date)

                    // Extract protobuf data
                    var plaintext = ""
                    var attachments: [NotesAttachment] = []

                    if n.protobuf_data != nil && n.protobuf_len > 0 {
                        let data = Data(bytes: n.protobuf_data, count: n.protobuf_len)

                        // Legacy notes have raw text, not gzipped protobuf
                        if n.is_legacy != 0 {
                            plaintext = String(data: data, encoding: .utf8) ?? ""
                        } else {
                            // Extract plaintext and attachments from protobuf
                            plaintext = htmlGen.extractPlaintext(fromProtobufData: data) ?? ""
                            let rawAttachments = htmlGen.extractAttachments(fromProtobufData: data)

                            // Validate attachment ownership: filter out stale/orphaned
                            // attachment references that may linger in protobuf data
                            // after notes are deleted or content is synced (#26)
                            attachments = rawAttachments.compactMap { att in
                                let owns = ane_validate_attachment_owner(db, att.id, n.pk)
                                guard owns != 0 else { return nil }
                                return NotesAttachment(
                                    id: att.id,
                                    typeUTI: att.typeUTI,
                                    filename: att.filepath
                                )
                            }
                        }
                    }

                    notes.append(NotesNote(
                        id: "\(n.pk)",
                        title: title,
                        plaintext: plaintext,
                        htmlBody: nil,  // Generated on-demand during export
                        creationDate: creationDate,
                        modificationDate: modificationDate,
                        folderId: "\(n.folder_pk)",
                        accountId: "\(n.account_pk)",
                        attachments: attachments
                    ))
                }

                continuation.resume(returning: notes)
            }
        }
    }

    func fetchAttachment(id: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let db = self.openDB() else {
                    continuation.resume(throwing: RepositoryError.databaseUnavailable)
                    return
                }
                defer { ane_close(db) }

                // Use the C parser's full attachment resolution chain
                guard let result = ane_fetch_attachment(db, id, nil) else {
                    continuation.resume(throwing: RepositoryError.attachmentNotFound(id))
                    return
                }
                defer { ane_free_attachment_data(result) }

                if result.pointee.data != nil && result.pointee.len > 0 {
                    let data = Data(bytes: result.pointee.data, count: result.pointee.len)
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: RepositoryError.attachmentNotFound(id))
                }
            }
        }
    }

    func fetchAttachmentFilename(id: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let db = self.openDB() else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { ane_close(db) }

                // Try the prefetch cache first for O(1) lookup
                let cached = ane_lookup_attachment(db, id)
                if let meta = cached {
                    // Prefer media_filename, fall back to attachment filename
                    if let mediaFn = meta.pointee.media_filename {
                        continuation.resume(returning: String(cString: mediaFn))
                        return
                    }
                    if let attFn = meta.pointee.filename {
                        continuation.resume(returning: String(cString: attFn))
                        return
                    }
                }

                // Prefetch cache wasn't populated, try direct lookup
                // Two-step: ZIDENTIFIER -> ZMEDIA -> ZFILENAME
                let mediaPk = ane_get_media_pk_for_identifier(db, id)
                if mediaPk >= 0 {
                    let identifierPtr = ane_get_identifier_for_pk(db, mediaPk)
                    if identifierPtr != nil {
                        // Get the media filename
                        let mediaResult = ane_fetch_media(db, mediaPk)
                        if let media = mediaResult {
                            if let fn = media.pointee.filename {
                                let filename = String(cString: fn)
                                ane_free_attachment_data(media)
                                free(identifierPtr)
                                continuation.resume(returning: filename)
                                return
                            }
                            ane_free_attachment_data(media)
                        }
                        free(identifierPtr)
                    }
                }

                continuation.resume(returning: nil)
            }
        }
    }

    func generateHTML(forNoteId noteId: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let db = self.openDB() else {
                    continuation.resume(throwing: RepositoryError.databaseUnavailable)
                    return
                }
                defer { ane_close(db) }

                guard let noteIdInt = Int64(noteId) else {
                    continuation.resume(throwing: RepositoryError.itemNotFound(noteId))
                    return
                }

                // Query the ZDATA blob for this specific note
                guard let sqliteHandle = ane_get_sqlite_handle(db) else {
                    continuation.resume(throwing: RepositoryError.databaseUnavailable)
                    return
                }
                let sqlite = OpaquePointer(sqliteHandle)

                let query = "SELECT data.ZDATA FROM ZICNOTEDATA data WHERE data.ZNOTE = ?"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(sqlite, query, -1, &stmt, nil) == SQLITE_OK else {
                    continuation.resume(throwing: RepositoryError.itemNotFound(noteId))
                    return
                }
                defer { sqlite3_finalize(stmt) }

                sqlite3_bind_int64(stmt, 1, noteIdInt)

                guard sqlite3_step(stmt) == SQLITE_ROW else {
                    continuation.resume(throwing: RepositoryError.itemNotFound(noteId))
                    return
                }

                guard sqlite3_column_type(stmt, 0) == SQLITE_BLOB else {
                    continuation.resume(throwing: RepositoryError.itemNotFound(noteId))
                    return
                }

                let dataSize = sqlite3_column_bytes(stmt, 0)
                guard let dataPointer = sqlite3_column_blob(stmt, 0), dataSize > 0 else {
                    continuation.resume(throwing: RepositoryError.itemNotFound(noteId))
                    return
                }

                let data = Data(bytes: dataPointer, count: Int(dataSize))

                // Generate HTML using the protobuf -> HTML generator
                let htmlGen = NoteHTMLGenerator(database: db)
                if let html = htmlGen.generateHTML(fromProtobufData: data) {
                    continuation.resume(returning: html)
                } else {
                    continuation.resume(throwing: RepositoryError.decodingError("Failed to generate HTML for note \(noteId)"))
                }
            }
        }
    }

    func fetchHierarchy(sortBy: NoteSortOption = .dateModified, foldersOnTop: Bool = true) async throws -> NotesHierarchy {
        // Fetch all data in parallel
        async let accounts = fetchAccounts()
        async let folders = fetchFolders()
        async let notes = fetchNotes()

        // Wait for all to complete
        let (accountsList, foldersList, notesList) = try await (accounts, folders, notes)

        // Build hierarchy with sort options
        return NotesHierarchy.build(
            accounts: accountsList,
            folders: foldersList,
            notes: notesList,
            sortBy: sortBy,
            foldersOnTop: foldersOnTop
        )
    }
}

// MARK: - Mock Implementation (for testing/previews)

/// Mock repository for SwiftUI previews and unit tests
class MockNotesRepository: NotesRepository {
    var mockAccounts: [NotesAccount] = []
    var mockFolders: [NotesFolder] = []
    var mockNotes: [NotesNote] = []
    var mockAttachmentData: Data = Data()

    func fetchAccounts() async throws -> [NotesAccount] {
        try await Task.sleep(nanoseconds: 100_000_000)
        return mockAccounts
    }

    func fetchFolders() async throws -> [NotesFolder] {
        try await Task.sleep(nanoseconds: 100_000_000)
        return mockFolders
    }

    func fetchNotes() async throws -> [NotesNote] {
        try await Task.sleep(nanoseconds: 100_000_000)
        return mockNotes
    }

    func fetchAttachment(id: String) async throws -> Data {
        try await Task.sleep(nanoseconds: 100_000_000)
        return mockAttachmentData
    }

    func fetchAttachmentFilename(id: String) async -> String? {
        return "mock-attachment.bin"
    }

    func generateHTML(forNoteId noteId: String) async throws -> String {
        try await Task.sleep(nanoseconds: 100_000_000)
        return "<html><body><p>Mock HTML for note \(noteId)</p></body></html>"
    }

    func fetchHierarchy(sortBy: NoteSortOption = .dateModified, foldersOnTop: Bool = true) async throws -> NotesHierarchy {
        NotesHierarchy.build(
            accounts: mockAccounts,
            folders: mockFolders,
            notes: mockNotes,
            sortBy: sortBy,
            foldersOnTop: foldersOnTop
        )
    }

    // MARK: - Mock Data Helpers

    static func preview() -> MockNotesRepository {
        let repo = MockNotesRepository()

        let account = NotesAccount(
            id: "1",
            name: "iCloud",
            identifier: "x-apple-account://sample",
            accountType: .iCloud
        )

        let folder1 = NotesFolder(id: "10", name: "Work", parentId: nil, accountId: "1")
        let folder2 = NotesFolder(id: "11", name: "Personal", parentId: nil, accountId: "1")

        let note1 = NotesNote(
            id: "100",
            title: "Meeting Notes",
            plaintext: "Discussed project timeline",
            htmlBody: "<html><body>Discussed project timeline</body></html>",
            creationDate: Date(),
            modificationDate: Date(),
            folderId: "10",
            accountId: "1",
            attachments: []
        )

        repo.mockAccounts = [account]
        repo.mockFolders = [folder1, folder2]
        repo.mockNotes = [note1]

        return repo
    }
}
