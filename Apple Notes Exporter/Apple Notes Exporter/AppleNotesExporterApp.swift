//
//  Apple_Notes_ExporterApp.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI

let APP_VERSION = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
let OUTPUT_FORMATS: [String] = [
    "PDF",
    "HTML",
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

class AppleNotesExporterState: ObservableObject {
    @Published var root: [ICItem] = []
    @Published var itemByXID: [String:ICItem] = [:]
    @Published var allNotes: [ICItem] = []
    
    @Published var initialLoadMessage: String = "Loading..."
    
    @Published var selectedNotesCount: Int = 0
    @Published var fromAccountsCount: Int = 0
    
    @Published var stateHash: UUID = UUID()
    
    func update() {
        // Update the proportion selected for all items
        for (_, value) in itemByXID {
            // Update the proportion selected
            value.updateProportionSelected()
        }
        // ** Update the totals
        var totalSelectedNotes = 0
        var selectedAccounts: Set<String> = []
        for note in self.allNotes {
            if note.selected {
                // Increment total
                totalSelectedNotes += 1
                // Add it to the set of selected accounts
                selectedAccounts.insert(note.account)
            }
        }
        self.selectedNotesCount = totalSelectedNotes
        self.fromAccountsCount = selectedAccounts.count
        // Update the stateHash, which forces re-renders
        self.stateHash = UUID()
    }
    
    func findItem(xid: String) -> ICItem? {
        // For each account in the root
        for item in root {
            // Check if the current item's xid matches the desired xid
            if item.xid == xid {
                return item
            }
            // Check if the current item's children contain the desired xid
            if let found = item.find(xid: xid) {
                return found
            }
        }
        
        // Return nil if nothing found
        return nil
    }
}

@main
struct Apple_Notes_ExporterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup(id: "main") {
            AppleNotesExporterView().onAppear {
                NSWindow.allowsAutomaticWindowTabbing = false
            }
            
        }
        .commands {
            CommandGroup(replacing: .newItem, addition: { })
        }
        .windowResizabilityContentSize()
    }
}
