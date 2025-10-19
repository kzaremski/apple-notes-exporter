//
//  NoteSelectorView.swift
//  Apple Notes Exporter
//
//  Modernized to use NotesViewModel and hierarchical data structure
//

import SwiftUI

// MARK: - Loading Indicator

struct LoaderLine: View {
    let label: String

    var body: some View {
        HStack {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .padding(.trailing, -15)
                .scaleEffect(0.5)
            Text(label)
        }
    }
}

// MARK: - Account Row

struct AccountRow: View {
    @EnvironmentObject var viewModel: NotesViewModel
    let accountNode: NotesHierarchy.AccountNode

    private func getImage() -> String {
        // Check if all notes in this account are selected
        let allNotes = collectAllNotes(from: accountNode.folders)

        // Empty accounts should show as unchecked
        if allNotes.isEmpty {
            return "square"
        }

        let allSelected = allNotes.allSatisfy { viewModel.isNoteSelected($0.id) }
        let noneSelected = allNotes.allSatisfy { !viewModel.isNoteSelected($0.id) }

        if allSelected {
            return "checkmark.square"
        } else if noneSelected {
            return "square"
        } else {
            return "minus.square"
        }
    }

    private func collectAllNotes(from folders: [NotesHierarchy.FolderNode]) -> [NotesNote] {
        var notes: [NotesNote] = []
        for folder in folders {
            notes.append(contentsOf: folder.notes)
            notes.append(contentsOf: collectAllNotes(from: folder.subfolders))
        }
        return notes
    }

    private func toggleAccount() {
        let allNotes = collectAllNotes(from: accountNode.folders)
        let allSelected = allNotes.allSatisfy { viewModel.isNoteSelected($0.id) }

        for folder in accountNode.folders {
            if allSelected {
                viewModel.deselectFolder(folder)
            } else {
                viewModel.selectFolder(folder)
            }
        }
    }

    var body: some View {
        HStack {
            Image(systemName: accountNode.account.icon)
                .padding([.leading], 5)
                .frame(width: 20)
            Text(accountNode.account.name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            // Only show checkbox if account has notes
            let allNotes = collectAllNotes(from: accountNode.folders)
            if !allNotes.isEmpty {
                Button {
                    toggleAccount()
                } label: {
                    Image(systemName: getImage())
                        .padding([.leading], 5)
                        .frame(width: 23)
                }
                .buttonStyle(BorderlessButtonStyle())
            } else {
                // Keep spacing consistent with other rows
                Spacer()
                    .frame(width: 23)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Folder Row

struct FolderRow: View {
    @EnvironmentObject var viewModel: NotesViewModel
    let folderNode: NotesHierarchy.FolderNode

    private func getImage() -> String {
        // Check selection state of all notes in this folder (including subfolders)
        let allNotes = collectAllNotes(from: folderNode)

        // Empty folders should show as unchecked
        if allNotes.isEmpty {
            return "square"
        }

        let allSelected = allNotes.allSatisfy { viewModel.isNoteSelected($0.id) }
        let noneSelected = allNotes.allSatisfy { !viewModel.isNoteSelected($0.id) }

        if allSelected {
            return "checkmark.square"
        } else if noneSelected {
            return "square"
        } else {
            return "minus.square"
        }
    }

    private func collectAllNotes(from folder: NotesHierarchy.FolderNode) -> [NotesNote] {
        var notes = folder.notes
        for subfolder in folder.subfolders {
            notes.append(contentsOf: collectAllNotes(from: subfolder))
        }
        return notes
    }

    private func toggleFolder() {
        let allNotes = collectAllNotes(from: folderNode)
        let allSelected = allNotes.allSatisfy { viewModel.isNoteSelected($0.id) }

        if allSelected {
            viewModel.deselectFolder(folderNode)
        } else {
            viewModel.selectFolder(folderNode)
        }
    }

    var body: some View {
        HStack {
            Image(systemName: folderNode.folder.icon)
                .padding([.leading], 5)
                .frame(width: 20)
            Text(folderNode.folder.name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            // Only show checkbox if folder has notes
            let allNotes = collectAllNotes(from: folderNode)
            if !allNotes.isEmpty {
                Button {
                    toggleFolder()
                } label: {
                    Image(systemName: getImage())
                        .padding([.leading], 5)
                        .frame(width: 23)
                }
                .buttonStyle(BorderlessButtonStyle())
            } else {
                // Show "empty" message where checkbox would be
                Text("This folder is empty.")
                    .italic()
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Note Row

struct NoteRow: View {
    @EnvironmentObject var viewModel: NotesViewModel
    let note: NotesNote

    private func getImage() -> String {
        viewModel.isNoteSelected(note.id) ? "checkmark.square" : "square"
    }

    var body: some View {
        HStack {
            Image(systemName: note.icon)
                .padding([.leading], 5)
                .frame(width: 20)
            Text(note.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            Button {
                viewModel.toggleNote(note.id)
            } label: {
                Image(systemName: getImage())
                    .padding([.leading], 5)
                    .frame(width: 23)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Note Selector View

struct NoteSelectorView: View {
    @ObservedObject var sharedState: AppleNotesExporterState
    @EnvironmentObject var viewModel: NotesViewModel
    @Binding var showNoteSelectorView: Bool

    var body: some View {
        VStack {
            Text("Select the accounts, folders, and notes that you would like to include in the export.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack {
                if viewModel.loadingState.isLoading {
                    if case .loading(let message) = viewModel.loadingState {
                        LoaderLine(label: message)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else if viewModel.accountsCount == 0 {
                    Text("No notes or note accounts were found!")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    SwiftUI.List {
                        ForEach(viewModel.hierarchy.accounts) { accountNode in
                            DisclosureGroup {
                                ForEach(accountNode.folders) { folderNode in
                                    FolderDisclosureGroup(folderNode: folderNode)
                                }
                            } label: {
                                AccountRow(accountNode: accountNode)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .border(SwiftUI.Color.gray, width: 1)
            .padding([.top, .bottom], 5)

            HStack {
                HStack {
                    Image(systemName: "info.circle")
                    Text("Notes that are locked with a password cannot be exported.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    sharedState.update() // Update counts before closing
                    showNoteSelectorView = false
                } label: {
                    Text("Done")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Update counts when the selector opens
            sharedState.update()
        }
    }
}

// MARK: - Folder Disclosure Group

struct FolderDisclosureGroup: View {
    @EnvironmentObject var viewModel: NotesViewModel
    let folderNode: NotesHierarchy.FolderNode

    // Helper to check if folder is completely empty (no notes in this folder or any subfolders)
    private var isFolderCompletelyEmpty: Bool {
        let allNotes = collectAllNotes(from: folderNode)
        return allNotes.isEmpty
    }

    private func collectAllNotes(from folder: NotesHierarchy.FolderNode) -> [NotesNote] {
        var notes = folder.notes
        for subfolder in folder.subfolders {
            notes.append(contentsOf: collectAllNotes(from: subfolder))
        }
        return notes
    }

    var body: some View {
        if isFolderCompletelyEmpty {
            // Empty folder - don't make it expandable, just show the row
            FolderRow(folderNode: folderNode)
        } else if folderNode.subfolders.isEmpty {
            // Folder with no subfolders - just show the folder and its notes
            DisclosureGroup {
                ForEach(folderNode.notes) { note in
                    NoteRow(note: note)
                }
            } label: {
                FolderRow(folderNode: folderNode)
            }
        } else {
            // Folder with subfolders - show recursive structure
            DisclosureGroup {
                if viewModel.foldersOnTop {
                    // Show subfolders first (folders before notes)
                    ForEach(folderNode.subfolders) { subfolderNode in
                        FolderDisclosureGroup(folderNode: subfolderNode)
                    }

                    // Show notes in this folder after subfolders
                    ForEach(folderNode.notes) { note in
                        NoteRow(note: note)
                    }
                } else {
                    // Mix folders and notes together (already sorted)
                    ForEach(folderNode.subfolders) { subfolderNode in
                        FolderDisclosureGroup(folderNode: subfolderNode)
                    }

                    ForEach(folderNode.notes) { note in
                        NoteRow(note: note)
                    }
                }
            } label: {
                FolderRow(folderNode: folderNode)
            }
        }
    }
}
