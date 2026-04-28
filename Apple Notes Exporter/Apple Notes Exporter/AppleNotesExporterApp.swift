//
//  AppleNotesExporterApp.swift
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

import SwiftUI

extension Scene {
    func windowResizabilityContentSize() -> some Scene {
        if #available(macOS 13.0, *) {
            return windowResizability(.contentSize)
        } else {
            return self
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Shared App State
// Bridge for @main and menu commands that can't directly observe MainViewModel.
@MainActor
class AppleNotesExporterState: ObservableObject {
    @Published var showProgressWindow: Bool = false
    @Published var exportPercentage: Float = 0.0
    @Published var exportMessage: String = "Exporting..."
    @Published var exporting: Bool = false
    @Published var shouldCancelExport: Bool = false
    @Published var exportDone: Bool = false
    @Published var selectedNotesCount: Int = 0
    @Published var fromAccountsCount: Int = 0
    @Published var licenseAccepted: Bool = UserDefaults.standard.bool(forKey: "licenseAcceptedGPLv3")

    // Action triggers (set from menu commands, observed by view)
    @Published var triggerSelectNotes: Bool = false
    @Published var triggerChooseFolder: Bool = false
    @Published var triggerExport: Bool = false

    // Export Log Window reference
    var exportLogWindow: NSWindow?

    // References to the new ViewModels
    let notesViewModel: NotesViewModel
    let exportViewModel: ExportViewModel

    init(notesViewModel: NotesViewModel, exportViewModel: ExportViewModel) {
        self.notesViewModel = notesViewModel
        self.exportViewModel = exportViewModel

        // Update counts from ViewModel
        updateCounts()
    }

    func showExportLog() {
        // Check if window already exists and bring to front
        if let window = exportLogWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Create new window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Export Log"
        window.minSize = NSSize(width: 500, height: 400)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .fullScreenDisallowsTiling]

        // Create content view with close handler
        let contentView = ExportLogView(onClose: {
            window.close()
        })
        .environmentObject(exportViewModel)

        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)

        exportLogWindow = window
    }

    func update() {
        updateCounts()
    }

    func refresh() {
        objectWillChange.send()
    }

    func reload() {
        // Cannot reload while exporting
        if self.exporting {
            return
        }

        Task {
            await notesViewModel.reload()
            await MainActor.run {
                updateCounts()
            }
        }
    }

    private func updateCounts() {
        selectedNotesCount = notesViewModel.selectedCount

        // Count unique accounts from selected notes
        let uniqueAccounts = Set(notesViewModel.selectedNotes.map { $0.accountId })
        fromAccountsCount = uniqueAccounts.count
    }
}

@main
struct Apple_Notes_ExporterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // New ViewModels
    @StateObject private var notesViewModel = NotesViewModel()
    @StateObject private var exportViewModel = ExportViewModel()

    @ObservedObject var sharedState: AppleNotesExporterState

    /// True when the app process was launched as a host for an XCTest run.
    /// In that case we render an empty scene so the FDA / license dialog
    /// never opens; the unit-test bundle loads into the same process and
    /// runs against the imported types directly.
    private static var isRunningUnderXCTest: Bool {
        return NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
    }

    init() {
        // Initialize ViewModels first
        let notesVM = NotesViewModel()
        let exportVM = ExportViewModel()

        // Create compatibility layer
        let state = AppleNotesExporterState(
            notesViewModel: notesVM,
            exportViewModel: exportVM
        )

        self.sharedState = state
        self._notesViewModel = StateObject(wrappedValue: notesVM)
        self._exportViewModel = StateObject(wrappedValue: exportVM)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            if Self.isRunningUnderXCTest {
                // Tests run inside this host process; do not bring up the UI
                // or trigger Notes-DB / FDA work.
                EmptyView()
            } else {
                AppleNotesExporterView(sharedState: sharedState)
                    .environmentObject(notesViewModel)
                    .environmentObject(exportViewModel)
                    .onAppear {
                        NSWindow.allowsAutomaticWindowTabbing = false
                    }
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(action: {
                    sharedState.reload()
                }) {
                    Text("Reload Notes Accounts")
                }
                .keyboardShortcut("R", modifiers: [.command])
                .disabled(sharedState.exporting)
            }

            CommandGroup(after: .sidebar) {
                Toggle(isOn: Binding(
                    get: { notesViewModel.foldersOnTop },
                    set: { newValue in
                        notesViewModel.foldersOnTop = newValue
                        Task {
                            await notesViewModel.rebuildHierarchy()
                        }
                    }
                )) {
                    Text("Display Folders Separately")
                }

                Picker("Sort By", selection: Binding(
                    get: { notesViewModel.sortOption },
                    set: { newValue in
                        notesViewModel.sortOption = newValue
                        Task {
                            await notesViewModel.rebuildHierarchy()
                        }
                    }
                )) {
                    ForEach(NoteSortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
            }

            CommandGroup(after: .newItem) {
                let canInteract = sharedState.licenseAccepted && !sharedState.exporting

                // Format selection shortcuts follow the 3-row grid in the UI.
                // Row 1 (rich docs):   Cmd+1-6
                // Row 2 (data):        Cmd+Opt+1-6
                // Row 3 (outline/bin): Cmd+Ctrl+1-6

                // Row 1: HTML, PDF, TEX, MD, RTF, TXT
                Button("HTML") { UserDefaults.standard.set("HTML", forKey: "outputFormat") }
                    .keyboardShortcut("1", modifiers: [.command]).disabled(!canInteract)
                Button("PDF") { UserDefaults.standard.set("PDF", forKey: "outputFormat") }
                    .keyboardShortcut("2", modifiers: [.command]).disabled(!canInteract)
                Button("LaTeX (TEX)") { UserDefaults.standard.set("TEX", forKey: "outputFormat") }
                    .keyboardShortcut("3", modifiers: [.command]).disabled(!canInteract)
                Button("Markdown (MD)") { UserDefaults.standard.set("MD", forKey: "outputFormat") }
                    .keyboardShortcut("4", modifiers: [.command]).disabled(!canInteract)
                Button("Rich Text (RTF)") { UserDefaults.standard.set("RTF", forKey: "outputFormat") }
                    .keyboardShortcut("5", modifiers: [.command]).disabled(!canInteract)
                Button("Plain Text (TXT)") { UserDefaults.standard.set("TXT", forKey: "outputFormat") }
                    .keyboardShortcut("6", modifiers: [.command]).disabled(!canInteract)

                Divider()

                // Row 2: JSON, JSONL, XML, CSV, OPML, ORG
                Button("JSON") { UserDefaults.standard.set("JSON", forKey: "outputFormat") }
                    .keyboardShortcut("1", modifiers: [.command, .option]).disabled(!canInteract)
                Button("JSON Lines (JSONL)") { UserDefaults.standard.set("JSONL", forKey: "outputFormat") }
                    .keyboardShortcut("2", modifiers: [.command, .option]).disabled(!canInteract)
                Button("XML") { UserDefaults.standard.set("XML", forKey: "outputFormat") }
                    .keyboardShortcut("3", modifiers: [.command, .option]).disabled(!canInteract)
                Button("CSV") { UserDefaults.standard.set("CSV", forKey: "outputFormat") }
                    .keyboardShortcut("4", modifiers: [.command, .option]).disabled(!canInteract)
                Button("OPML") { UserDefaults.standard.set("OPML", forKey: "outputFormat") }
                    .keyboardShortcut("5", modifiers: [.command, .option]).disabled(!canInteract)
                Button("Org Mode") { UserDefaults.standard.set("ORG", forKey: "outputFormat") }
                    .keyboardShortcut("6", modifiers: [.command, .option]).disabled(!canInteract)

                Divider()

                // Row 3: RST, ADOC, DOCX, ODT, EPUB, ENEX
                Button("reStructuredText (RST)") { UserDefaults.standard.set("RST", forKey: "outputFormat") }
                    .keyboardShortcut("1", modifiers: [.command, .control]).disabled(!canInteract)
                Button("AsciiDoc (ADOC)") { UserDefaults.standard.set("ADOC", forKey: "outputFormat") }
                    .keyboardShortcut("2", modifiers: [.command, .control]).disabled(!canInteract)
                Button("Word (DOCX)") { UserDefaults.standard.set("DOCX", forKey: "outputFormat") }
                    .keyboardShortcut("3", modifiers: [.command, .control]).disabled(!canInteract)
                Button("OpenDocument (ODT)") { UserDefaults.standard.set("ODT", forKey: "outputFormat") }
                    .keyboardShortcut("4", modifiers: [.command, .control]).disabled(!canInteract)
                Button("EPUB") { UserDefaults.standard.set("EPUB", forKey: "outputFormat") }
                    .keyboardShortcut("5", modifiers: [.command, .control]).disabled(!canInteract)
                Button("Evernote (ENEX)") { UserDefaults.standard.set("ENEX", forKey: "outputFormat") }
                    .keyboardShortcut("6", modifiers: [.command, .control]).disabled(!canInteract)

                Divider()

                Button("Select Notes...") {
                    sharedState.triggerSelectNotes = true
                }
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(!canInteract)

                Button("Choose Output Folder...") {
                    sharedState.triggerChooseFolder = true
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(!canInteract)

                Button("Export") {
                    sharedState.triggerExport = true
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(!canInteract)

                Divider()
            }

            CommandGroup(after: .windowArrangement) {
                Button(action: {
                    sharedState.showExportLog()
                }) {
                    Text("Show Export Log")
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])
                .disabled(!sharedState.licenseAccepted)
            }
        }
        .windowResizabilityContentSize()
    }
}
