//
//  export.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/13/24.
//

import Foundation

func exportNotes(outputURL: URL, outputFormat: String, outputType: String) {
    // Generate a UUID to use when creating the temporary directories for this particular export
    //let temporaryWorkingDirectoryName: String = UUID().uuidString
    
    //// Get notes from the selected account using AppleScript (this takes a while)
    ////let notes = getNotesUsingAppleScript(noteAccountName: "notesAccount")
    //let notes: [Note] = []
    //print("Finished getting Apple Notes and their contents via. AppleScript automation")
    //
    //// Create the temporary directory
    //let temporaryWorkingDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: //true).appendingPathComponent(temporaryWorkingDirectoryName, isDirectory: true)
    //createDirectoryIfNotExists(location: temporaryWorkingDirectory)
    //print("Created temporary working directory: \(temporaryWorkingDirectory.absoluteString)")
    //
    //// Create a direcory within the temp that represents the root of the exported notes account
    //var zipRootDirectoryName = outputURL.lastPathComponent
    //zipRootDirectoryName = zipRootDirectoryName.replacingOccurrences(of: ".zip", with: "")
    //let zipRootDirectory: URL = temporaryWorkingDirectory.appendingPathComponent(zipRootDirectoryName, isDirectory: true)
    //createDirectoryIfNotExists(location: zipRootDirectory)
    //
    //// Loop through the notes and write them to output files, dynamically creating their containing folders as needed
    //for note in notes {
    //    // ** Create the containing directories of the note file
    //    // Start at the root
    //    var currentPath = URL(string: zipRootDirectory.absoluteString)
    //    // Loop through each string in the path array and create the directories if they are not already created
    //    for directory in note.path {
    //        // Set the current path to the current directory name, sanitized
    //        currentPath = URL(string: currentPath!.absoluteString)!
    //            .appendingPathComponent(sanitizeFileNameString(inputFilename: directory, outputFormat: outputFormat), //isDirectory:true)
    //        // Create it if it does not exist
    //        createDirectoryIfNotExists(location: currentPath!)
    //    }
    //    // Set the path to the filename of the note based on the current format
    //    let outputFileName = sanitizeFileNameString(inputFilename: note.title, outputFormat: outputFormat)
    //    let outputDirectoryURL: URL = URL(string: currentPath!.absoluteString)!
    //    // Write the note to the file
    //    note.toOutputFile(location: outputDirectoryURL, fileName: outputFileName, format: outputFormat, //shouldExportAttachments: true)
    //}
    //
    //// ZIP the working directory to the output file directory
    //zipDirectory(inputDirectory: zipRootDirectory, outputZipFile: outputURL)
    //print("Zipped output directory to the user-selected output file")
    //
    //print("Done!")
}

func initialLoad(sharedState: AppleNotesExporterState) {
    // Time formatter (for the time remaining)
    func formatTime(_ timeInterval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: timeInterval)!
    }
    
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
            let remainingTimeString = formatTime(estimatedRemainingTime)
            DispatchQueue.main.async {
                sharedState.initialLoadMessage = "Querying account \"\(account.name)\" \(toFixed(percentComplete, 1))% (note \(index + 1) of \(accountNotes.count)), \(remainingTimeString) remaining"
            }
            
            // Get the current rich note dictionary
            let current = accountNotes[index]
            // Instantiate the ICItem for the note
            let note = ICItem(xid: current["xid"]!)
            note.name = current["name"]!
            note.container = current["container"]!
            
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
    }
}
