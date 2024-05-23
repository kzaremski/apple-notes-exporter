//
//  Apple_Notes_ExporterApp.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI

let APP_VERSION = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
let OUTPUT_FORMATS: [String] = [
    //"PDF",
    "HTML",
    //"TEX",
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
    
    @Published var selectedRoot: [ICItem] = []
    @Published var selectedNotes: [ICItem] = []
    
    @Published var initialLoadMessage: String = "Loading..."
    
    @Published var exportPercentage: Float = 0.0
    @Published var exportMessage: String = "Exporting..."
    @Published var exporting: Bool = false
    @Published var shouldCancelExport: Bool = false
    @Published var exportDone: Bool = false
    
    @Published var selectedNotesCount: Int = 0
    @Published var fromAccountsCount: Int = 0
    
    @Published var stateHash: UUID = UUID()
    
    /**
     Build a root for the selected notes
     */
    func buildSelectedRoot() {
        // New directory structure but for the selected notes only
        var newSelectedRoot: [ICItem] = []
        
        // Find item by XID in selected root
        func findInNewSelectedRoot(xid: String) -> ICItem? {
            // For each account in the root
            for item in newSelectedRoot {
                // Check if the current item's xid matches the desired xid
                if item.xid == xid {
                    return item
                }
                // Check if the current item's children contain the desired xid
                if let found = item.find(xid: xid) {
                    return found
                }
            }
            
            // If not found, return nil
            return nil
        }
        
        // Add all accounts (even if they are not selected)
        //     This is needed for the container placing method as the [ICItem] does not have an appendChild method
        for account in self.root {
            newSelectedRoot.append(ICItem(from: account))
        }
        // For each selected note XID
        for selectedNote in self.selectedNotes {
            // Reuse the object from the selected note that way the reference is the same
            var item = selectedNote
            
            // Place it where it belongs within the directory structure
            var container = findInNewSelectedRoot(xid: item.container)
            while container == nil {
                // Create a new item that will represent the parent folder
                let newItem = ICItem(from: self.itemByXID[item.container]!)
                
                // Add the current item as a child of the parent folder (new item)
                newItem.appendChild(child: item)
                
                // Next level (try to place the item, which is now the parent folder, somewhere)
                item = newItem
                container = findInNewSelectedRoot(xid: item.container)
            }
            // Once we have created containers moving upwards to a point that there is a container that exists, place the nested structure (or single note) as a child of that final container.
            container!.appendChild(child: item)
        }
        // Build the final selected root
        var finalNewSelectedRoot: [ICItem] = []
        for account in newSelectedRoot {
            // If the account has children (notes are selected within it), it is kept
            if account.children != nil {
                finalNewSelectedRoot.append(account)
            }
        }
        // Update the selected root
        self.selectedRoot = finalNewSelectedRoot
    }
    
    func update() {
        // Update the proportion selected for all items
        for (_, value) in itemByXID {
            // Update the proportion selected
            value.updateProportionSelected()
        }
        // ** Update the totals & array of selected notes
        var newSelectedNotes: [ICItem] = []
        var totalSelectedNotes = 0
        var selectedAccounts: Set<String> = []
        for note in self.allNotes {
            if note.selected {
                // Increment total
                totalSelectedNotes += 1
                // Add it to the set of selected accounts
                selectedAccounts.insert(note.account)
                // Add the note to the new array of selected notes
                newSelectedNotes.append(ICItem(from: note))
            }
        }
        self.selectedNotesCount = totalSelectedNotes
        self.fromAccountsCount = selectedAccounts.count
        self.selectedNotes = newSelectedNotes
        // Go through each selected note and build the new selected notes directory structure
        buildSelectedRoot()
        // Update the stateHash, which forces re-renders
        refresh()
    }
    
    func refresh() {
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
