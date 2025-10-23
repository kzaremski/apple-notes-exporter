//
//  NotesViewModel.swift
//  Apple Notes Exporter
//
//  ViewModel for managing notes data and selection state
//  Uses repository pattern and async/await for clean data access
//

import Foundation
import SwiftUI
import OSLog

// MARK: - Sort Options

enum NoteSortOption: String, CaseIterable {
    case name = "Name"
    case dateModified = "Date Modified"
    case dateCreated = "Date Created"
}

// MARK: - Notes ViewModel

@MainActor
class NotesViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var hierarchy: NotesHierarchy = NotesHierarchy(accounts: [])
    @Published var selectionState = NotesSelectionState()
    @Published var loadingState: LoadingState = .idle

    // Sorting and display preferences
    @Published var sortOption: NoteSortOption = .dateModified
    @Published var foldersOnTop: Bool = true

    // Computed properties for UI
    var selectedCount: Int {
        selectionState.selectedCount
    }

    var accountsCount: Int {
        hierarchy.accounts.count
    }

    var allNotes: [NotesNote] {
        hierarchy.accounts.flatMap { account in
            account.folders.flatMap { folder in
                collectNotes(from: folder)
            }
        }
    }

    var selectedNotes: [NotesNote] {
        selectionState.selectedNotes(from: allNotes)
    }

    // MARK: - Dependencies

    private let repository: NotesRepository

    // Store raw data for rebuilding hierarchy
    private var rawAccounts: [NotesAccount] = []
    private var rawFolders: [NotesFolder] = []
    private var rawNotes: [NotesNote] = []

    // MARK: - Initialization

    init(repository: NotesRepository = DatabaseNotesRepository()) {
        self.repository = repository
    }

    // MARK: - Data Loading

    /// Load all notes from the database
    func loadNotes() async {
        loadingState = .loading(message: "Loading notes from database...")

        do {
            // Fetch raw data from repository
            async let accountsTask = repository.fetchAccounts()
            async let foldersTask = repository.fetchFolders()
            async let notesTask = repository.fetchNotes()

            let (accounts, folders, notes) = try await (accountsTask, foldersTask, notesTask)

            // Store raw data for rebuilding
            rawAccounts = accounts
            rawFolders = folders
            rawNotes = notes

            // Build hierarchy with current sort options
            hierarchy = NotesHierarchy.build(
                accounts: accounts,
                folders: folders,
                notes: notes,
                sortBy: sortOption,
                foldersOnTop: foldersOnTop
            )

            loadingState = .loaded

            // Automatically select all notes after loading
            selectAll()

            Logger.noteQuery.info("Loaded \(self.allNotes.count) notes from \(self.accountsCount) accounts")
            Logger.noteQuery.info("Automatically selected all \(self.selectedCount) notes")

        } catch let error as RepositoryError {
            loadingState = .error(error.localizedDescription)
            Logger.noteQuery.error("Repository error: \(error.localizedDescription)")

        } catch {
            loadingState = .error("Failed to load notes: \(error.localizedDescription)")
            Logger.noteQuery.error("Unexpected error: \(error.localizedDescription)")
        }
    }

    /// Rebuild hierarchy with current sort settings (uses cached data, does not reload from database)
    func rebuildHierarchy() async {
        // Build hierarchy using stored raw data with current sort options
        hierarchy = NotesHierarchy.build(
            accounts: rawAccounts,
            folders: rawFolders,
            notes: rawNotes,
            sortBy: sortOption,
            foldersOnTop: foldersOnTop
        )

        Logger.noteQuery.debug("Rebuilt hierarchy with sort: \(self.sortOption.rawValue), foldersOnTop: \(self.foldersOnTop)")
    }

    /// Reload notes from database (useful after permissions granted)
    func reload() async {
        selectionState.clearAll()
        await loadNotes()
    }

    // MARK: - Selection Management

    /// Toggle a single note's selection
    func toggleNote(_ noteId: String) {
        selectionState.toggleNote(noteId)
    }

    /// Select all notes in a folder
    func selectFolder(_ folderNode: NotesHierarchy.FolderNode) {
        selectionState.selectFolder(folderNode)
    }

    /// Deselect all notes in a folder
    func deselectFolder(_ folderNode: NotesHierarchy.FolderNode) {
        selectionState.deselectFolder(folderNode)
    }

    /// Toggle folder selection
    func toggleFolder(_ folderNode: NotesHierarchy.FolderNode) {
        if selectionState.isFolderSelected(folderNode.folder.id, in: hierarchy) {
            deselectFolder(folderNode)
        } else {
            selectFolder(folderNode)
        }
    }

    /// Clear all selections
    func clearSelections() {
        selectionState.clearAll()
    }

    /// Select all notes
    func selectAll() {
        for account in hierarchy.accounts {
            for folder in account.folders {
                selectFolder(folder)
            }
        }
    }

    // MARK: - Helper Methods

    /// Recursively collect all notes from a folder and its subfolders
    private func collectNotes(from folder: NotesHierarchy.FolderNode) -> [NotesNote] {
        var notes = folder.notes
        for subfolder in folder.subfolders {
            notes.append(contentsOf: collectNotes(from: subfolder))
        }
        return notes
    }

    /// Check if a note is selected
    func isNoteSelected(_ noteId: String) -> Bool {
        selectionState.isNoteSelected(noteId)
    }

    /// Check if a folder is selected
    func isFolderSelected(_ folderId: String) -> Bool {
        selectionState.isFolderSelected(folderId, in: hierarchy)
    }

    /// Get accounts with unique identifiers
    func getAccountsWithUniqueIds() -> [(id: String, name: String)] {
        hierarchy.accounts.map { account in
            (id: account.account.id, name: account.account.name)
        }
    }
}

// MARK: - Mock for Previews

extension NotesViewModel {
    /// Create a mock view model for SwiftUI previews
    static func preview() -> NotesViewModel {
        let mockRepo = MockNotesRepository.preview()
        let viewModel = NotesViewModel(repository: mockRepo)

        // Simulate loaded state
        Task {
            await viewModel.loadNotes()
        }

        return viewModel
    }
}
