//
//  NotesModels.swift
//  Apple Notes Exporter
//
//  Modern, protocol-based data models following Swift best practices
//

import Foundation

// MARK: - Base Protocol

/// Base protocol for all Notes items (accounts, folders, notes, attachments)
protocol NotesItem: Identifiable, Hashable, CustomStringConvertible {
    var id: String { get }
    var name: String { get }
}

// MARK: - Account

/// Represents a Notes account (iCloud, Gmail, On My Mac, etc.)
struct NotesAccount: NotesItem {
    let id: String
    let name: String
    let identifier: String
    let accountType: AccountType

    enum AccountType: Int {
        case local = 0
        case exchange = 1
        case imap = 2
        case iCloud = 3
        case google = 4

        var displayName: String {
            switch self {
            case .local: return "On My Mac"
            case .exchange: return "Exchange"
            case .imap: return "IMAP"
            case .iCloud: return "iCloud"
            case .google: return "Google"
            }
        }
    }

    var description: String { name }

    var icon: String { "globe" }
}

// MARK: - Folder

/// Represents a folder within a Notes account
struct NotesFolder: NotesItem {
    let id: String
    let name: String
    let parentId: String?
    let accountId: String

    var description: String { name }

    var icon: String { "folder" }

    /// Check if this is a root-level folder (no parent)
    var isRootFolder: Bool { parentId == nil }
}

// MARK: - Note

/// Represents an individual note with all its content and metadata
struct NotesNote: NotesItem {
    let id: String
    let title: String
    let plaintext: String
    let htmlBody: String
    let creationDate: Date
    let modificationDate: Date
    let folderId: String
    let accountId: String
    let attachments: [NotesAttachment]

    var name: String { title }
    var description: String { title }
    var icon: String { "doc" }

    /// Check if note has any attachments
    var hasAttachments: Bool { !attachments.isEmpty }

    /// Generate sanitized filename for export
    var sanitizedFileName: String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.newlines)
            .union(.illegalCharacters)
            .union(.controlCharacters)

        return title.components(separatedBy: invalidCharacters).joined(separator: "")
    }
}

// MARK: - Attachment

/// Represents a file attachment within a note
struct NotesAttachment: NotesItem {
    let id: String
    let typeUTI: String
    let filename: String?

    var name: String { filename ?? id.components(separatedBy: "/").last ?? "Unnamed" }
    var description: String { name }
    var icon: String { "paperclip" }

    /// Extract file extension from type UTI
    var fileExtension: String? {
        // Common UTI mappings
        let utiExtensions: [String: String] = [
            "public.jpeg": "jpg",
            "public.png": "png",
            "public.pdf": "pdf",
            "public.heic": "heic",
            "com.apple.quicktime-movie": "mov",
            "public.mpeg-4": "mp4"
        ]

        return utiExtensions[typeUTI] ?? typeUTI.components(separatedBy: ".").last
    }
}

// MARK: - Hierarchical Structure

/// Represents a hierarchical tree structure for displaying accounts/folders/notes
struct NotesHierarchy {
    let accounts: [AccountNode]

    struct AccountNode: Identifiable {
        let account: NotesAccount
        let folders: [FolderNode]

        var id: String { account.id }
    }

    struct FolderNode: Identifiable {
        let folder: NotesFolder
        let subfolders: [FolderNode]
        let notes: [NotesNote]

        var id: String { folder.id }

        /// Count all notes recursively
        var totalNoteCount: Int {
            notes.count + subfolders.reduce(0) { $0 + $1.totalNoteCount }
        }

        /// Get the most recent modification date from all notes in this folder and subfolders
        var mostRecentModificationDate: Date? {
            var allDates: [Date] = notes.map { $0.modificationDate }
            for subfolder in subfolders {
                if let subfolderDate = subfolder.mostRecentModificationDate {
                    allDates.append(subfolderDate)
                }
            }
            return allDates.max()
        }

        /// Get the earliest creation date from all notes in this folder and subfolders
        var earliestCreationDate: Date? {
            var allDates: [Date] = notes.map { $0.creationDate }
            for subfolder in subfolders {
                if let subfolderDate = subfolder.earliestCreationDate {
                    allDates.append(subfolderDate)
                }
            }
            return allDates.min()
        }
    }

    /// Build hierarchy from flat arrays
    static func build(
        accounts: [NotesAccount],
        folders: [NotesFolder],
        notes: [NotesNote],
        sortBy: NoteSortOption = .dateModified,
        foldersOnTop: Bool = true
    ) -> NotesHierarchy {
        let accountNodes = accounts.map { account in
            let accountFolders = folders.filter { $0.accountId == account.id }
            let rootFolders = accountFolders.filter { $0.parentId == nil || $0.parentId == account.id }

            // Group root folders by name to merge duplicates
            var groupedFolders: [String: [NotesFolder]] = [:]
            for folder in rootFolders {
                groupedFolders[folder.name, default: []].append(folder)
            }
            let folderNodes = groupedFolders.map { (name, foldersWithSameName) in
                buildMergedFolderNode(folders: foldersWithSameName, allFolders: accountFolders, notes: notes, sortBy: sortBy, foldersOnTop: foldersOnTop)
            }
            // Sort root folders based on sort option
            .sorted { folder1, folder2 in
                sortFolders(folder1, folder2, by: sortBy)
            }

            return AccountNode(account: account, folders: folderNodes)
        }

        return NotesHierarchy(accounts: accountNodes)
    }

    /// Build a merged folder node from multiple folders with the same name
    private static func buildMergedFolderNode(
        folders: [NotesFolder],
        allFolders: [NotesFolder],
        notes: [NotesNote],
        sortBy: NoteSortOption,
        foldersOnTop: Bool
    ) -> FolderNode {
        // Use the first folder as the representative
        let representativeFolder = folders[0]

        // Collect all folder IDs that need to be merged
        let folderIds = Set(folders.map { $0.id })

        // Find all subfolders that belong to any of these merged folders
        let childFolders = allFolders.filter { folderIds.contains($0.parentId ?? "") }

        // Group child folders by name and recursively merge them
        var groupedChildFolders: [String: [NotesFolder]] = [:]
        for folder in childFolders {
            groupedChildFolders[folder.name, default: []].append(folder)
        }
        let subfolders = groupedChildFolders.map { (name, foldersWithSameName) in
            buildMergedFolderNode(folders: foldersWithSameName, allFolders: allFolders, notes: notes, sortBy: sortBy, foldersOnTop: foldersOnTop)
        }
        // Sort subfolders based on sort option
        .sorted { folder1, folder2 in
            sortFolders(folder1, folder2, by: sortBy)
        }

        // Collect all notes from all merged folders, sorted based on sort option
        let folderNotes = notes
            .filter { folderIds.contains($0.folderId) }
            .sorted { note1, note2 in
                sortNotes(note1, note2, by: sortBy)
            }

        return FolderNode(folder: representativeFolder, subfolders: subfolders, notes: folderNotes)
    }

    /// Sort two folders based on the given sort option
    private static func sortFolders(_ folder1: FolderNode, _ folder2: FolderNode, by sortOption: NoteSortOption) -> Bool {
        switch sortOption {
        case .name:
            return folder1.folder.name.localizedCaseInsensitiveCompare(folder2.folder.name) == .orderedAscending
        case .dateModified:
            let date1 = folder1.mostRecentModificationDate ?? Date.distantPast
            let date2 = folder2.mostRecentModificationDate ?? Date.distantPast
            return date1 > date2
        case .dateCreated:
            // For folders, we'll use the earliest creation date from notes within
            let date1 = folder1.earliestCreationDate ?? Date.distantFuture
            let date2 = folder2.earliestCreationDate ?? Date.distantFuture
            return date1 < date2
        }
    }

    /// Sort two notes based on the given sort option
    private static func sortNotes(_ note1: NotesNote, _ note2: NotesNote, by sortOption: NoteSortOption) -> Bool {
        switch sortOption {
        case .name:
            return note1.title.localizedCaseInsensitiveCompare(note2.title) == .orderedAscending
        case .dateModified:
            return note1.modificationDate > note2.modificationDate
        case .dateCreated:
            return note1.creationDate > note2.creationDate
        }
    }
}

// MARK: - Selection State

/// Manages note selection state separately from data model
struct NotesSelectionState {
    private var selectedNoteIds: Set<String> = []
    private var selectedFolderIds: Set<String> = []

    /// Check if a note is selected
    func isNoteSelected(_ noteId: String) -> Bool {
        selectedNoteIds.contains(noteId)
    }

    /// Check if a folder is selected (all notes within it selected)
    func isFolderSelected(_ folderId: String, in hierarchy: NotesHierarchy) -> Bool {
        selectedFolderIds.contains(folderId)
    }

    /// Toggle note selection
    mutating func toggleNote(_ noteId: String) {
        if selectedNoteIds.contains(noteId) {
            selectedNoteIds.remove(noteId)
        } else {
            selectedNoteIds.insert(noteId)
        }
    }

    /// Select all notes in a folder
    mutating func selectFolder(_ folderNode: NotesHierarchy.FolderNode) {
        // Select all notes in this folder
        folderNode.notes.forEach { selectedNoteIds.insert($0.id) }

        // Recursively select notes in subfolders
        folderNode.subfolders.forEach { selectFolder($0) }

        selectedFolderIds.insert(folderNode.folder.id)
    }

    /// Deselect all notes in a folder
    mutating func deselectFolder(_ folderNode: NotesHierarchy.FolderNode) {
        // Deselect all notes in this folder
        folderNode.notes.forEach { selectedNoteIds.remove($0.id) }

        // Recursively deselect notes in subfolders
        folderNode.subfolders.forEach { deselectFolder($0) }

        selectedFolderIds.remove(folderNode.folder.id)
    }

    /// Get all selected notes
    func selectedNotes(from allNotes: [NotesNote]) -> [NotesNote] {
        allNotes.filter { selectedNoteIds.contains($0.id) }
    }

    /// Get count of selected notes
    var selectedCount: Int {
        selectedNoteIds.count
    }

    /// Clear all selections
    mutating func clearAll() {
        selectedNoteIds.removeAll()
        selectedFolderIds.removeAll()
    }
}

// MARK: - Export Format

/// Supported export formats
enum ExportFormat: String, CaseIterable {
    case html = "HTML"
    case pdf = "PDF"
    case tex = "TEX"
    case markdown = "MD"
    case rtf = "RTF"
    case txt = "TXT"

    var fileExtension: String {
        rawValue.lowercased()
    }
}

// MARK: - Loading State

/// Represents the current loading state for async operations
enum LoadingState: Equatable {
    case idle
    case loading(message: String)
    case loaded
    case error(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}
