//
//  export.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/13/24.
//

import Foundation
import OSLog

func exportNotes(sharedState: AppleNotesExporterState, outputURL: URL, outputFormat: String) {
    // Reset the export message and progress
    DispatchQueue.main.sync {
        sharedState.exporting = true
        sharedState.shouldCancelExport = false
        sharedState.exportDone = false
        sharedState.exportPercentage = 0.0
        sharedState.exportMessage = "Starting export..."
    }
    
    /**
     See if we should cancel the export, and set the export message accordingly.
     */
    func shouldCancelExport() -> Bool {
        if sharedState.shouldCancelExport {
            DispatchQueue.main.async {
                sharedState.exportMessage = sharedState.exporting ? "Cancelling export..." : "Export has been cancelled!"
            }
        }
        return sharedState.shouldCancelExport
    }
    
    func updateExportProgress(_ p: Float, _ message: String) {
        DispatchQueue.main.async {
            sharedState.exportPercentage = p
            sharedState.exportMessage = message
        }
    }
    
    func getExportProgress() -> (total: Int, done: Int) {
        let total = sharedState.selectedNotes.count
        let done  = sharedState.selectedNotes.filter { $0.saved }.count
        return (total, done)
    }
    
    // Set the start time (to be used for time remaining calculations)
    let startTime = Date()
    
    func exportItem(item: ICItem, baseURL: URL) {
        if !shouldCancelExport() {
            if item.type == .ICAccount || item.type == .ICFolder {
                // Create a directory at the current base URL for the account or the folder
                let folderURL = baseURL.appendingPathComponent(item.name)
                createDirectoryIfNotExists(location: folderURL)
                // If no children return
                guard let children = item.children else {
                    return
                }
                for child in children {
                    exportItem(item: child, baseURL: folderURL)
                }
            } else {
                // ** Update the progress
                let progress = getExportProgress()
                if progress.done >= 9 {
                    // Calculate time remaining
                    //let percentComplete = (Double(progress.done) / Double(progress.total)) * 100
                    let elapsedTime = -startTime.timeIntervalSinceNow
                    let estimatedRemainingTime = ((elapsedTime * 1.00) / Double(progress.done + 1)) * Double(progress.total + 1 - (progress.done + 1))
                    let remainingTimeString = timeRemainingFormatter(estimatedRemainingTime)
                    updateExportProgress(Float(progress.done) / Float(progress.total), "Exporting note \(progress.done + 1) of \(progress.total) (\(remainingTimeString) remaining)")
                } else {
                    updateExportProgress(Float(progress.done) / Float(progress.total), "Exporting note \(progress.done + 1) of \(progress.total)")
                }
                
                // Load the entire note
                item.exporting = true
                item.load()
                
                // Save the note to file
                item.save(toFolder: baseURL, format: outputFormat, withAttachments: true)
                
                // Update status of this note
                item.exporting = false
                
                DispatchQueue.main.async {
                    sharedState.refresh()
                }
            }
        }
    }
    
    for account in sharedState.selectedRoot {
        exportItem(item: account, baseURL: outputURL)
    }
    
    // Reset the export message and progress
    DispatchQueue.main.async {
        if shouldCancelExport() {
            sharedState.exporting = false
            sharedState.exportDone = false
            sharedState.exportMessage = "Export has been cancelled!"
            Logger.noteExport.info("Finished exporting, reason: cancelled.")
        } else {
            sharedState.exporting = false
            sharedState.exportDone = true
            sharedState.exportPercentage = 1.0
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .medium
            sharedState.exportMessage = "Export finished " + dateFormatter.string(from: Date())
            Logger.noteExport.info("Finished exporting, reason: finished.")
        }
    }
}

func initialLoad(sharedState: AppleNotesExporterState) {
    Logger.noteQuery.info("Started initial note and account query.")
    
    // Data root
    var localRoot: [ICItem] = []
    
    func findInLocalRoot(xid: String) -> ICItem? {
        // For each account in the root
        for item in localRoot {
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
    
    // All note references in single array
    var localAllNotes: [ICItem] = []
    
    // All ICItems stored against their XID
    var itemByXID: [String:ICItem] = [:]
    
    // Update the loading message
    DispatchQueue.main.async {
        sharedState.initialLoadMessage = "Querying accounts..."
    }
    
    // Load all accounts
    let accounts = AppleNotesScriptLayer.getAllAccounts()
    for accountXID in accounts {
        let ICAccount = ICItem(xid: accountXID)
        ICAccount.loadName()
        // Add the account to the local directory structure
        localRoot.append(ICAccount)
        // Store the account against its XID
        itemByXID[ICAccount.xid] = ICAccount
    }
    
    // For each account, load all of its notes and place them where they belong in the data structure
    for account in localRoot {
        // Set the start time (to be used for time remaining calculations)
        let startTime = Date()
        
        // Load (rich output) notes from account (inc. XID, name, and container XID)
        let accountNotes: [[String:String]] = AppleNotesScriptLayer.getAccountNotesRich(xid: account.xid)
        // For each note, instantiate an ICItem and place it where it belongs in the directory structure (loading containers along the way)
        for index in 0..<accountNotes.count {
            // Update the time remaining message
            let percentComplete = (Double(index + 1) / Double(accountNotes.count)) * 100
            let elapsedTime = -startTime.timeIntervalSinceNow
            let estimatedRemainingTime = (elapsedTime / Double(index + 1)) * Double(accountNotes.count - (index + 1))
            let remainingTimeString = timeRemainingFormatter(estimatedRemainingTime)
            DispatchQueue.main.async {
                sharedState.initialLoadMessage = "Querying account \"\(account.name)\" \(toFixed(percentComplete, 1))% (note \(index + 1) of \(accountNotes.count)), \(remainingTimeString) remaining"
            }
            
            // Get the current rich note dictionary
            let current = accountNotes[index]
            // Instantiate the ICItem for the note
            let note = ICItem(xid: current["xid"]!)
            note.name = current["name"]!
            note.container = current["container"]!
            note.account = account.xid
            
            // Store the note against its XID
            itemByXID[note.xid] = note
            
            // Place it where it belongs within the directory structure
            var item = note
            var container = findInLocalRoot(xid: item.container)
            while container == nil {
                // Create a new item that will represent the parent folder
                let newItem = ICItem(xid: item.container)
                newItem.loadName()
                newItem.loadContainer()
                newItem.account = account.xid
                // Add the current item as a child of the parent folder (new item)
                newItem.appendChild(child: item)
                
                // Store the new item against its XID
                itemByXID[newItem.xid] = newItem
                
                // Next level (try to place the item, which is now the parent folder, somewhere)
                item = newItem
                container = findInLocalRoot(xid: item.container)
            }
            // Once we have created containers moving upwards to a point that there is a container that exists, place the nested structure (or single note) as a child of that final container.
            container!.appendChild(child: item)
            
            // Add it to the all notes array
            localAllNotes.append(note)
        }
    }
    
    // Finish by updaing the global state
    DispatchQueue.main.async {
        sharedState.root = localRoot
        sharedState.itemByXID = itemByXID
        sharedState.allNotes = localAllNotes
        
        // Log
        Logger.noteQuery.info("Finished initial note and account query.")
    }
}
