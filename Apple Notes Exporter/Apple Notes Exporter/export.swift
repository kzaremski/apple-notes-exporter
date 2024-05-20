//
//  export.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/13/24.
//

import Foundation

func parseAppleEventDescriptor(_ desc: NSAppleEventDescriptor) {
    let descType = desc.descriptorType
    let typeString = String(format: "%c%c%c%c",
                            (descType >> 24) & 0xFF,
                            (descType >> 16) & 0xFF,
                            (descType >> 8) & 0xFF,
                            descType & 0xFF)
    print("Descriptor Type: \(typeString)")

    switch descType {
    case typeUTF8Text, typeUnicodeText, typeChar:
        parseTextDesc(desc)
    case typeSInt32:
        parseLongDesc(desc)
    case typeAEList:
        parseListDesc(desc)
    case typeAERecord:
        parseRecordDesc(desc)
    case typeObjectSpecifier:
        parseObjectSpecifierDesc(desc)
    default:
        parseRawDataDesc(desc)
    }
}

func parseTextDesc(_ desc: NSAppleEventDescriptor) {
    if let text = desc.stringValue {
        print("Text Data: \(text)")
    } else {
        print("Failed to parse text data")
    }
}

func parseLongDesc(_ desc: NSAppleEventDescriptor) {
    let value = desc.int32Value
    print("Long Integer Data: \(value)")
}

func parseListDesc(_ desc: NSAppleEventDescriptor) {
    let count = desc.numberOfItems
    print("List contains \(count) items")

    for i in 1...count {
        if let item = desc.atIndex(i) {
            parseAppleEventDescriptor(item)
        }
    }
}

func parseRecordDesc(_ desc: NSAppleEventDescriptor) {
    let count = desc.numberOfItems
    print("Record contains \(count) fields")

    for i in 1...count {
        let keyword = desc.keywordForDescriptor(at: i)
        let keywordString = String(format: "%c%c%c%c",
                                   (keyword >> 24) & 0xFF,
                                   (keyword >> 16) & 0xFF,
                                   (keyword >> 8) & 0xFF,
                                   keyword & 0xFF)
        if let item = desc.atIndex(i) {
            print("Field Keyword: \(keywordString)")
            parseAppleEventDescriptor(item)
        }
    }
}

func parseObjectSpecifierDesc(_ desc: NSAppleEventDescriptor) {
    if let container = desc.forKeyword(keyDirectObject) {
        print("Container:")
        parseAppleEventDescriptor(container)
    }
    
    if let keyForm = desc.forKeyword(AEKeyword(keyAEKeyForm)) {
        print("Key Form:")
        parseAppleEventDescriptor(keyForm)
    }
    
    if let keyData = desc.forKeyword(AEKeyword(keyAEKeyData)) {
        print("Key Data:")
        parseAppleEventDescriptor(keyData)
    }
}

func parseRawDataDesc(_ desc: NSAppleEventDescriptor) {
    let data = desc.data
    let rawData = data.map { String(format: "%02X", $0) }.joined(separator: " ")
    print("Raw Data: \(rawData)")
}


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

func executeAppleScript(script: String) -> NSAppleEventDescriptor? {
    var error: NSDictionary?
    if let scriptObject = NSAppleScript(source: script) {
        let descriptor = scriptObject.executeAndReturnError(&error)
        if let error = error {
            print("AppleScript Error: \(error)")
            return nil
        }
        return descriptor
    }
    return nil
}

func getFirstNoteFromFirstAccount() -> String? {
    let scriptSource = """
    tell application id "com.apple.Notes"
        set theAccount to first account
        return first note of theAccount
    end tell
    """
    
    if let descriptor = executeAppleScript(script: scriptSource) {
        print(descriptor)
        // Parse the descriptor to get note information
        if let noteBody = descriptor.forKeyword(keyAEText)?.stringValue {
            return noteBody
        } else if let noteDescriptor = descriptor.forKeyword(keyDirectObject),
                  let noteBody = noteDescriptor.stringValue {
            return noteBody
        }
    }
    return nil
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
                
                // Next level (try to place the item, which is now the parent folder, somewhere)
                item = newItem
                container = findInLocalRoot(xid: item.container)
            }
            container!.appendChild(child: item)
            
            // Add it to the all notes array
            localAllNotes.append(note)
        }
    }
    
    // Finish by updaing the global state
    DispatchQueue.main.async {
        sharedState.root = localRoot
        sharedState.allNotes = localAllNotes
    }
}
