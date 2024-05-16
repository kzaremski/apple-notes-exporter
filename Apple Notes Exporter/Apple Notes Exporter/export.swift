//
//  export.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/13/24.
//

import Foundation

func exportNotes(outputURL: URL, outputFormat: String, outputType: String) {
    // Generate a UUID to use when creating the temporary directories for this particular export
    let temporaryWorkingDirectoryName: String = UUID().uuidString
    
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

func initialLoad() {
    let accounts = AppleNotesScriptLayer.getAllAccounts()
    for accountXID in accounts {
        var ICAccount = ICItem(xid: accountXID)
        ICAccount.name = accountXID
        let notes = AppleNotesScriptLayer.getAccountNotes(xid: accountXID)
        for noteXID in notes {
            var ICNote = ICItem(xid: noteXID)
            ICNote.name = noteXID
            ICAccount.appendChild(child: ICNote)
        }
        AppleNotesExporterData.root.append(ICAccount)
    }
}
