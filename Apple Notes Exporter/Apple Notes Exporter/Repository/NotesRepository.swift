//
//  NotesRepository.swift
//  Apple Notes Exporter
//
//  Repository pattern for Notes data access
//  Abstracts the database layer for testability and flexibility
//

import Foundation

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

// MARK: - Database Implementation

/// Concrete implementation using AppleNotesDatabaseParser
class DatabaseNotesRepository: NotesRepository, @unchecked Sendable {
    private let databasePath: String

    /// Initialize with custom database path (useful for testing)
    init(databasePath: String = "\(NSHomeDirectory())/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite") {
        self.databasePath = databasePath
    }

    // MARK: - Fetch Methods

    func fetchAccounts() async throws -> [NotesAccount] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let parser = AppleNotesDatabaseParser(databasePath: self.databasePath)

                guard parser.open() else {
                    continuation.resume(throwing: RepositoryError.databaseUnavailable)
                    return
                }

                defer { parser.close() }

                let parsedAccounts = parser.fetchAccounts()

                // Convert from ParsedAccount to NotesAccount
                let accounts = parsedAccounts.map { account in
                    NotesAccount(
                        id: "\(account.id)",
                        name: account.name,
                        identifier: account.identifier,
                        accountType: .iCloud  // Default, parser doesn't return type yet
                    )
                }

                continuation.resume(returning: accounts)
            }
        }
    }

    func fetchFolders() async throws -> [NotesFolder] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let parser = AppleNotesDatabaseParser(databasePath: self.databasePath)

                guard parser.open() else {
                    continuation.resume(throwing: RepositoryError.databaseUnavailable)
                    return
                }

                defer { parser.close() }

                let parsedFolders = parser.fetchFolders()

                // Convert from parsed folder to NotesFolder
                let folders = parsedFolders.map { folder in
                    NotesFolder(
                        id: "\(folder.id)",
                        name: folder.name,
                        parentId: folder.parentId.map { "\($0)" },
                        accountId: "\(folder.accountId)"
                    )
                }

                continuation.resume(returning: folders)
            }
        }
    }

    func fetchNotes() async throws -> [NotesNote] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let parser = AppleNotesDatabaseParser(databasePath: self.databasePath)

                guard parser.open() else {
                    continuation.resume(throwing: RepositoryError.databaseUnavailable)
                    return
                }

                defer { parser.close() }

                let parsedNotes = parser.fetchNotes()

                // Convert from ParsedNote to NotesNote
                let notes = parsedNotes.map { note in
                    let attachments = note.attachments.map { attachment in
                        NotesAttachment(
                            id: attachment.id,
                            typeUTI: attachment.typeUTI,
                            filename: attachment.filepath
                        )
                    }

                    return NotesNote(
                        id: "\(note.id)",
                        title: note.title,
                        plaintext: note.plaintext,
                        htmlBody: nil,  // HTML is generated on-demand during export for better load performance
                        creationDate: note.creationDate,
                        modificationDate: note.modificationDate,
                        folderId: "\(note.folderId)",
                        accountId: "\(note.accountId)",
                        attachments: attachments
                    )
                }

                continuation.resume(returning: notes)
            }
        }
    }

    func fetchAttachment(id: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let parser = AppleNotesDatabaseParser(databasePath: self.databasePath)

                guard parser.open() else {
                    continuation.resume(throwing: RepositoryError.databaseUnavailable)
                    return
                }

                defer { parser.close() }

                if let attachmentData = parser.fetchAttachmentData(attachmentId: id) {
                    continuation.resume(returning: attachmentData)
                } else {
                    continuation.resume(throwing: RepositoryError.attachmentNotFound(id))
                }
            }
        }
    }

    func fetchAttachmentFilename(id: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let parser = AppleNotesDatabaseParser(databasePath: self.databasePath)

                guard parser.open() else {
                    continuation.resume(returning: nil)
                    return
                }

                defer { parser.close() }

                let filename = parser.fetchAttachmentFilename(attachmentId: id)
                continuation.resume(returning: filename)
            }
        }
    }

    func generateHTML(forNoteId noteId: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let parser = AppleNotesDatabaseParser(databasePath: self.databasePath)

                guard parser.open() else {
                    continuation.resume(throwing: RepositoryError.databaseUnavailable)
                    return
                }

                defer { parser.close() }

                guard let noteIdInt = Int(noteId) else {
                    continuation.resume(throwing: RepositoryError.itemNotFound(noteId))
                    return
                }

                if let html = parser.generateHTMLForNote(noteId: noteIdInt) {
                    continuation.resume(returning: html)
                } else {
                    continuation.resume(throwing: RepositoryError.itemNotFound(noteId))
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
        try await Task.sleep(nanoseconds: 100_000_000) // Simulate delay
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

        // Create sample account
        let account = NotesAccount(
            id: "1",
            name: "iCloud",
            identifier: "x-apple-account://sample",
            accountType: .iCloud
        )

        // Create sample folders
        let folder1 = NotesFolder(id: "10", name: "Work", parentId: nil, accountId: "1")
        let folder2 = NotesFolder(id: "11", name: "Personal", parentId: nil, accountId: "1")

        // Create sample notes
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
