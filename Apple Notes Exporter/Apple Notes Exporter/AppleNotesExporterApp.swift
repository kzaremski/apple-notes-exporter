//
//  Apple_Notes_ExporterApp.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI
import OSLog

// ** Declare Constants
// App version and capability
let APP_VERSION = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
let OUTPUT_FORMATS: [String] = [
    "HTML",
    "PDF",
    "TEX",
    "MD",
    "RTF",
    "TXT",
]
let OUTPUT_TYPES: [String] = [
    "Folder",
    "TAR Archive",
    "ZIP Archive",
]
// Page types
let PAGE_US_LETTER: (width: Int, height: Int) = (612, 792)
let PAGE_US_LEGAL: (width: Int, height: Int) = (612, 1008)
let PAGE_US_TABLOID: (width: Int, height: Int) = (792, 1224)
let PAGE_A4: (width: Int, height: Int) = (595, 842)
// Logger
extension Logger {
    /// Using your bundle identifier is a great way to ensure a unique identifier.
    private static var subsystem = Bundle.main.bundleIdentifier!

    static let noteQuery = Logger(subsystem: subsystem, category: "notequery")
    static let noteExport = Logger(subsystem: subsystem, category: "noteexport")
}

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

// MARK: - App State (Legacy Compatibility Layer)
// This class provides compatibility with the old UI while we migrate to ViewModels
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
    @Published var licenseAccepted: Bool = false

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

    // Legacy compatibility state
    @ObservedObject var sharedState: AppleNotesExporterState

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
            AppleNotesExporterView(sharedState: sharedState)
                .environmentObject(notesViewModel)
                .environmentObject(exportViewModel)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
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
