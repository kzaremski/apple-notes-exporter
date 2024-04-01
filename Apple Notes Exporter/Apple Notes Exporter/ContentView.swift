//
//  ContentView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI
import WebKit
import Foundation
import UniformTypeIdentifiers
import AppKit
import Cocoa

struct MenuItem: Identifiable {
    let id = UUID()
    let title: String
    let action: () -> Void
}



/**
 Struct that represents an exported Apple Note
 */
struct Note {
    var ID: String = ""
    var title: String = ""
    var content: String = ""
    var creationDate: Date = Date()
    var modificationDate: Date = Date()
    var path: [String] = []
    var attachments: [String] = []
    var tags: [String] = []
    
    func appleDateStringToDate(inputString: String) -> Date {
        // DateFormatter based on Apple's format
        //   eg. Monday, June 21, 2021 at 10:40:09 PM
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
        dateFormatter.timeZone = TimeZone.current // Current offset
        // Return the converted output
        return dateFormatter.date(from: inputString) ?? Date()
    }
    
    init(ID: String, title: String, content: String, creationDate: String, modificationDate: String, path: [String], attachments: [String], tags: [String]) {
        self.ID = ID
        self.title = title
        self.content = content.replacingOccurrences(of: "\u{2028}", with: "<br>").replacingOccurrences(of: "\u{2029}", with: "<br>")
        self.creationDate = appleDateStringToDate(inputString: creationDate)
        self.modificationDate = appleDateStringToDate(inputString: modificationDate)
        self.path = path
        self.attachments = attachments
        self.tags = tags
    }
    
    /**
     Create a little box that is a link to the supplied attachment.
     */
    func htmlAttachmentLinkString(linkTitle: String, linkPath: String) -> String {
        return
"""
<a href="\(linkPath)">
    <h5></h5>
</a>
"""
    }
    
    /**
        Convert the current note object in to an HTML document string.
     */
    func toHTMLString() -> String {
        let outputHTMLString: String =
"""
<!Doctype HTML>
<html>
    <head>
        <meta content="text/html; charset=utf-8" http-equiv="Content-Type">
        <title>\(self.title)</title>
    </head>
    <body>
        <style>
            body {
                padding: 2em;
                font-family: sans-serif;
            }
        </style>
        <div>
        \(self.content)
        </div>
    </body>
</html>
"""
        return outputHTMLString
    }
    
    func toAttributedString() -> NSAttributedString {
        // Get the HTML content of the note
        let htmlString = self.toHTMLString()
        
        do {
            // Empty NSAttributedString
            var attributedString: NSMutableAttributedString = NSMutableAttributedString()
            // Set the NSAttributed string to the contents of the HTML output, converted to NSAttributedString
            try attributedString = NSMutableAttributedString(
                data: htmlString.data(using: .utf8) ?? Data(),
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
            
            // Hand back the attributed string
            return attributedString
        } catch {
            print("Failed to convert note to NSAttributedString")
        }
        return NSMutableAttributedString()
    }
    
    /**
     Write the note to an output file.
     */
    func toOutputFile(location: URL, fileName: String, format: String, shouldExportAttachments: Bool) {
        // Roll through a series of filenames until we get to one that does not exist
        let fileManager = FileManager.default
        // Initial filename & output URL
        var outputFileName = fileName + "." + format.lowercased()
        var outputFileURL: URL = URL(string: location.absoluteString)!.appendingPathComponent(outputFileName)
        // Filenumber starts counting at zero
        var outputFileNumber: Int = 0;
        // Roll through and incremernt a (3) parenthesis number at the end of the filename until we get to a filename that does not exist
        while (fileManager.fileExists(atPath: outputFileURL.path)) {
            // Increment the file number
            outputFileNumber = outputFileNumber + 1
            // Create a new filename & path with that output number
            outputFileName = fileName + " (\(outputFileNumber))." + format.lowercased()
            outputFileURL = URL(string: location.absoluteString)!.appendingPathComponent(outputFileName)
        }
        
        // Export note attachments (if there are any) if we are directed to do so
        if shouldExportAttachments && self.attachments.count > 0 {
            // Create a directory for the attachments
            let attachmentDirectoryName = outputFileNumber > 0 ? fileName + " (\(outputFileNumber)) Attachments" : fileName + " Attachments"
            let attachmentDirectoryURL = URL(string: location.absoluteString)!.appendingPathComponent(attachmentDirectoryName)
            do {
                // Create the directory
                try fileManager.createDirectory(at: attachmentDirectoryURL, withIntermediateDirectories: false)
            } catch {
                print("Failed to create attachment directory: \(error)")
            }
            
            
            // For each ID in the Array of Attachment IDs
            for attachmentIDString in attachments {
                // Script to export the current attachment
                let attachmentIDStringSanitized = attachmentIDString.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let attachmentSaveScript = """
                    set savePath to (POSIX file "\(attachmentDirectoryURL.path)/\(attachmentIDStringSanitized)")
                    tell application "Notes"
                        repeat with theAttachment in attachments
                            if id of theAttachment as string is "\(attachmentIDString)" then
                                save theAttachment in file savePath
                                return {name of theAttachment, creation date of theAttachment as string, modification date of theAttachment as string}
                            end if
                        end repeat
                    end tell
                    return {"", "", ""}
                """
                
                // Error handling
                var errorDict: NSDictionary? = nil
                // Execute the script, adding to the errorDict if there are errors
                let script: NSAppleScript = NSAppleScript(source: attachmentSaveScript)!
                let resultDescriptor = script.executeAndReturnError(&errorDict)
                // If there are errors, do nothing
                if errorDict != nil {
                    print(errorDict!.description)
                    continue
                }
                
                // Get the properties of the attachment
                let originalFileName = resultDescriptor.atIndex(1)?.stringValue ?? ""
                let creationDate = appleDateStringToDate(inputString: resultDescriptor.atIndex(2)?.stringValue ?? "")
                let modificationDate = appleDateStringToDate(inputString: resultDescriptor.atIndex(3)?.stringValue ?? "")
                
                // Rename the AppleScript-outputted file to a good file name
                var attachmentNameComponents = originalFileName.split(separator: ".")
                let attachmentExtension = attachmentNameComponents.removeLast()
                // Reassemble the filename
                let attachmentName = attachmentNameComponents.joined(separator: ".")
                var attachmentFileName = attachmentName + "." + attachmentExtension
                
                // Filenumber starts counting at zero
                var attachmentFileNumber: Int = 0;
                // Roll through and incremernt a (3) parenthesis number at the end of the filename until we get to a filename that does not exist
                while (fileManager.fileExists(atPath: URL(string: attachmentDirectoryURL.absoluteString)!.appendingPathComponent(attachmentFileName).path)) {
                    // Increment the file number
                    attachmentFileNumber = attachmentFileNumber + 1
                    // Create a new filename with that output number
                    attachmentFileName = attachmentName + " (\(attachmentFileNumber))." + attachmentExtension
                }
                
                // Create URL objects
                let originalAttachmentURL = URL(string: attachmentDirectoryURL.absoluteString)!.appendingPathComponent(attachmentIDStringSanitized)
                let attachmentURL = URL(string: attachmentDirectoryURL.absoluteString)!.appendingPathComponent(attachmentFileName)
                
                // Rename the UUID file to a proper filename
                do {
                    try fileManager.moveItem(at: originalAttachmentURL, to: attachmentURL)
                } catch {
                    print("Failed to rename attachment \(originalAttachmentURL.path) to \(attachmentURL.path)")
                }
                
                // Set the properties of the attachment file
                let attributes = [
                    FileAttributeKey.creationDate: creationDate,
                    FileAttributeKey.modificationDate: modificationDate,
                ]
                do {
                    try fileManager.setAttributes(attributes, ofItemAtPath: attachmentURL.absoluteString)
                } catch {
                    print(error)
                }
            }
        }
        
        // Export the actual note
        switch format.uppercased() {
        case "HTML":
            try? self.toHTMLString().data(using: .utf8)!
                .write(to: outputFileURL)
        case "PDF":
            return
        case "RTFD":
            let attributedString = self.toAttributedString()
            try? attributedString.rtfd(
                from: NSRange(location: 0, length: attributedString.length),
                documentAttributes: [:])!
                .write(to: outputFileURL)
        case "MD":
            // Get the HTML string of the content (less common tags)
            let htmlStringLines = self.content
                .replacingOccurrences(of: "<div>", with: "")
                .replacingOccurrences(of: "</div>", with: "")
                .replacingOccurrences(of: "<br>", with: "")
                .replacingOccurrences(of: "<object>", with: "")
                .replacingOccurrences(of: "</object>", with: "")
                .split(separator: "\n")
            
            // Create an output string
            var outputString =
"""
---
title: \(fileName)
tags: \(self.tags.joined(separator: ", "))
---
"""
            
            // The above is gross
            outputString = ""
   
            // Mode
            let MD_CONVERSION_MODE_NORMAL = 0
            let MD_CONVERSION_MODE_ORDEREDLIST = 1
            let MD_CONVERSION_MODE_UNORDEREDLIST = 2
            let MD_CONVERSION_MODE_TABLE = 3
            var mode = MD_CONVERSION_MODE_NORMAL
            
            // For each HTML line
            for htmlLine in htmlStringLines {
                // Markdown line
                var markdownLine = String(htmlLine)
                
                // ** Conversion
                // Headings
                markdownLine = markdownLine.replacingOccurrences(of: "<h1>", with: "\n# ").replacingOccurrences(of: "</h1>", with: "")
                markdownLine = markdownLine.replacingOccurrences(of: "<h2>", with: "\n## ").replacingOccurrences(of: "</h2>", with: "")
                markdownLine = markdownLine.replacingOccurrences(of: "<h3>", with: "\n### ").replacingOccurrences(of: "</h3>", with: "")
                markdownLine = markdownLine.replacingOccurrences(of: "<h4>", with: "\n#### ").replacingOccurrences(of: "</h4>", with: "")
                markdownLine = markdownLine.replacingOccurrences(of: "<h5>", with: "\n##### ").replacingOccurrences(of: "</h5>", with: "")
                markdownLine = markdownLine.replacingOccurrences(of: "<h6>", with: "\n###### ").replacingOccurrences(of: "</h6>", with: "")
                // Styles
                markdownLine = markdownLine.replacingOccurrences(of: "<b>", with: "**").replacingOccurrences(of: "</b>", with: "**")
                markdownLine = markdownLine.replacingOccurrences(of: "<i>", with: "*").replacingOccurrences(of: "</i>", with: "*")
                // MD doesnt have underline because the creator is opinionated!  markdownLine = markdownLine.replacingOccurrences(of: "<i>", with: "*").replacingOccurrences(of: "</i>", with: "*")
                markdownLine = markdownLine.replacingOccurrences(of: "<tt>", with: "`").replacingOccurrences(of: "</tt>", with: "`")
            
                // Mode changes
                
                // Add the markdown line to the output string
                outputString = outputString + "\n" + markdownLine
            }
            
            // Create
            try? outputString.data(using: .utf8)!
                .write(to: outputFileURL)
        case "RTF":
            let attributedString = self.toAttributedString()
            try? attributedString.rtf(
                from: NSRange(location: 0, length: attributedString.length),
                documentAttributes: [:])!
                .write(to: outputFileURL)
        case "TXT":
            let attributedString = self.toAttributedString()
            try? attributedString.string.data(using: .utf8)!
                .write(to: outputFileURL)
        default:
            try? Data().write(to: outputFileURL)
        }
        
        // Set the properties of the outputted file (creation date and the modification date)
        let attributes = [
            FileAttributeKey.creationDate: self.creationDate,
            FileAttributeKey.modificationDate: self.modificationDate,
        ]
        do {
            try fileManager.setAttributes(attributes, ofItemAtPath: outputFileURL.absoluteString)
        } catch {
            print(error)
        }
    }
}

func getNotesUsingAppleScript(noteAccountName: String) -> [Note] {
    // Script to export the notes from the current account
    let exportScript = """
        set noteList to {}
        tell application "Notes"
            repeat with theAccount in accounts
                if name of theAccount as string = "\(noteAccountName)" then
                    set chosenAccount to theAccount
                end if
            end repeat
            repeat with currentNote in notes of chosenAccount
                set noteLocked to password protected of currentNote as boolean
                if not noteLocked then
                    -- Get properties of the not if it is not locked
                    set modificationDate to modification date of currentNote as string
                    set creationDate to creation date of currentNote as string
                    set noteID to id of currentNote as string
                    set noteTitle to name of currentNote as string
                    set noteContent to body of currentNote as string
                    -- Build an array of attachments
                    set noteAttachments to {}
                    repeat with theAttachment in attachments of currentNote
                        set end of noteAttachments to id of theAttachment as string
                    end repeat
                    -- Build an array of note tags
                    set noteTags to {}
                    -- Get the path of the note internally to Apple Notes
                    set currentContainer to container of currentNote
                    set internalPath to {name of currentContainer}
                        repeat until name of currentContainer as string = name of chosenAccount as string
                            set currentContainer to container of currentContainer
                            if name of currentContainer as string ≠ name of chosenAccount then
                                set beginning of internalPath to name of currentContainer as string
                            end if
                        end repeat
                    -- Build the object
                    set noteListObject to {noteID,noteTitle,noteContent,creationDate,modificationDate,internalPath,noteAttachments,noteTags}
                    -- Add to the list
                    set end of noteList to noteListObject
                end if
            end repeat
        end tell
        return noteList
    """
    
    // Error handling
    var errorDict: NSDictionary? = nil
    // Execute the script, adding to the errorDict if there are errors
    let script: NSAppleScript = NSAppleScript(source: exportScript)!
    let resultDescriptor = script.executeAndReturnError(&errorDict)
    // If there are errors, return and do nothing
    if errorDict != nil {
        print("AppleScript in getNotes failed")
        print(errorDict!.description)
        return []
    }
    
    // Take action with the resulting Apple Event desciptor in order to export and format the notes
    let listDescriptor = resultDescriptor.coerce(toDescriptorType: typeAEList)!
    
    // Empty array of output notes
    var notes: [Note] = []
    
    // Iterate through the typeAEList
    for listIndex in 0 ... listDescriptor.numberOfItems {
        // This record is just a list of strings in a particular order since I could not figure out typeAERecord
        guard let recordDescriptor = listDescriptor.atIndex(listIndex)?.coerce(toDescriptorType: typeAEList) else {
            // If it doesn't work, just skip it for now
            continue
        }
        // Create a new note from the AppleScript object based on the indexes of the values provided in the Apple Event descriptor
        //   {noteID,noteTitle,noteContent,creationDate,modificationDate,internalPath}
        //   {
        //      noteID,             1
        //      noteTitle,          2
        //      noteContent,        3
        //      creationDate,       4
        //      modificationDate,   5
        //      internalPath        6
        //      attachments         7
        //  }
        let newNote = Note(
            ID: recordDescriptor.atIndex(1)?.stringValue ?? "",
            title: recordDescriptor.atIndex(2)?.stringValue ?? "",
            content: recordDescriptor.atIndex(3)?.stringValue ?? "",
            creationDate: recordDescriptor.atIndex(4)?.stringValue ?? "",
            modificationDate: recordDescriptor.atIndex(5)?.stringValue ?? "",
            path: recordDescriptor.atIndex(6)!.toStringArray(),
            attachments: recordDescriptor.atIndex(7)!.toStringArray(),
            tags: recordDescriptor.atIndex(8)!.toStringArray()
        )
        // Add the note to the list of notes
        notes.append(newNote)
    }
    
    // Return the list of Apple Notes
    return notes
}

func zipDirectory(inputDirectory: URL, outputZipFile: URL) {
    // NSFileCoordinator
    let coordinator = NSFileCoordinator()
    let zipIntent = NSFileAccessIntent.readingIntent(with: inputDirectory, options: [.forUploading])
    // ZIP the input directory
    coordinator.coordinate(with: [zipIntent], queue: .main) { errorQ in
        if let error = errorQ {
            print("Error: \(error)")
            return
        }
        // Get the location of the ZIP file to be copied
        let coordinatorOutputFile = zipIntent.url
        // Copy the output to the output ZIP file location
        do {
            if FileManager.default.fileExists(atPath: outputZipFile.path) {
                try FileManager.default.removeItem(at: outputZipFile)
            }
            try FileManager.default.copyItem(at: coordinatorOutputFile, to: outputZipFile)
        } catch (let error) {
            print("Failed to copy \(coordinatorOutputFile) to \(outputZipFile): \(error)")
        }
    }
}

func createDirectoryIfNotExists(location: URL) {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: location.path) {
        do {
            try fileManager.createDirectory(at: location, withIntermediateDirectories: false)
        } catch {
            print("Error creating directory at \(location.absoluteString)")
        }
        
    }
}

struct ContentView: View {
    func sanitizeFileNameString(inputFilename: String) -> String {
        // Define CharacterSet of invalid characters which we will remove from the filenames
        var invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.newlines)
            .union(.illegalCharacters)
            .union(.controlCharacters)
        // If we are exporting to markdown, then there are even more invalid characters
        if selectedOutputFormat == "MD" {
            invalidCharacters = invalidCharacters.union(CharacterSet(charactersIn: "[#]^"))
        }
        // Filter out the illegal characters
        let output = inputFilename.components(separatedBy: invalidCharacters).joined(separator: "")
        // Filter out Emojis for more reliable unzipping
        return output.unicodeScalars.filter { !($0.properties.isEmoji && $0.properties.isEmojiPresentation) }.map { String($0) }.joined()
    }
    
    func exportNotes() {
        // Validate
        if outputFilePath == "Select output file location" {
            showNoOutputSelectedAlert = true
            return
        }
        if selectedNotesAccount == "" {
            return
        }
        
        // Open the progress window since we are starting a long process.
        showProgressWindow = true
        // Do the export in the global DispatcheQueue as an async operation so that it does not block the UI
        DispatchQueue.global(qos: .userInitiated).async {
            // Generate a UUID to use when creating the temporary directories for this particular export
            let temporaryWorkingDirectoryName: String = UUID().uuidString
            
            // Get notes from the selected account using AppleScript (this takes a while)
            let notes = getNotesUsingAppleScript(noteAccountName: selectedNotesAccount)
            print("Finished getting Apple Notes and their contents via. AppleScript automation")
            
            // Create the temporary directory
            let temporaryWorkingDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(temporaryWorkingDirectoryName, isDirectory: true)
            createDirectoryIfNotExists(location: temporaryWorkingDirectory)
            print("Created temporary working directory: \(temporaryWorkingDirectory.absoluteString)")
            
            // Create a direcory within the temp that represents the root of the exported notes account
            var zipRootDirectoryName = outputFileURL?.lastPathComponent
            zipRootDirectoryName = zipRootDirectoryName?.replacingOccurrences(of: ".zip", with: "")
            let zipRootDirectory: URL = temporaryWorkingDirectory.appendingPathComponent(zipRootDirectoryName ?? "export", isDirectory: true)
            createDirectoryIfNotExists(location: zipRootDirectory)
            
            // Loop through the notes and write them to output files, dynamically creating their containing folders as needed
            for note in notes {
                // ** Create the containing directories of the note file
                // Start at the root
                var currentPath = URL(string: zipRootDirectory.absoluteString)
                // Loop through each string in the path array and create the directories if they are not already created
                for directory in note.path {
                    // Set the current path to the current directory name, sanitized
                    currentPath = URL(string: currentPath!.absoluteString)!
                        .appendingPathComponent(sanitizeFileNameString(inputFilename: directory), isDirectory:true)
                    // Create it if it does not exist
                    createDirectoryIfNotExists(location: currentPath!)
                }
                // Set the path to the filename of the note based on the current format
                let outputFileName = sanitizeFileNameString(inputFilename: note.title)
                let outputDirectoryURL: URL = URL(string: currentPath!.absoluteString)!
                // Write the note to the file
                note.toOutputFile(location: outputDirectoryURL, fileName: outputFileName, format: selectedOutputFormat, shouldExportAttachments: true)
            }
            
            // ZIP the working directory to the output file directory
            zipDirectory(inputDirectory: zipRootDirectory, outputZipFile: outputFileURL!)
            print("Zipped output directory to the user-selected output file")
            
            // Hide the progress window now that we are done
            showProgressWindow = false
            print("Done!")
        }
    }
    
    /**
     Select the output file location. It is a ZIP file in the directory of the user's choosing.
     */
    func selectOutputFile() {
        let savePanel = NSSavePanel()
        // Default file name of something like:   Apple Notes Export 2023-05-25.zip
        savePanel.allowedContentTypes = [UTType.zip]
        //savePanel.nameFieldStringValue = "Apple Notes Export " + ISO8601DateFormatter().string(from: Date()).split(separator: "T")[0] + ".zip"
        savePanel.nameFieldStringValue = "applenotes.zip"
        
        if savePanel.runModal() == .OK, let exportURL = savePanel.url {
            self.outputFilePath = exportURL.path
            self.outputFileURL = exportURL
        }
    }
    
    func setNotesAccounts(notesAccounts: [String]) {
        self.notesAccounts = notesAccounts
        self.selectedNotesAccount = notesAccounts.first ?? ""
        self.loaded = true
    }
    
    // State of the interface and form inputs
    @State private var notesAccounts: [String] = ["Loading..."]
    @State private var selectedNotesAccount = "Loading..."
    @State private var loaded: Bool = false
    @State private var selectedOutputFormat = "HTML"
    @State private var outputFilePath = "Select output file location"
    @State private var outputFileURL: URL?
    @State private var showProgressWindow: Bool = false
    @State private var showNoOutputSelectedAlert: Bool = false
    @State private var showErrorExportingAlert: Bool = false
    
    // Get version number
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    
    // Body of the ContentView
    let outputFormats: [String] = [
        "HTML",
        // "PDF",   // Disabled until I can figure these two out
        // "RTFD",
        "MD",
        "RTF",
        "TXT",
    ]
    var body: some View {
        VStack(alignment: .leading) {
            Text("Step 1: Select Notes Account")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
            Picker("Input", selection: $selectedNotesAccount) {
                ForEach(self.notesAccounts, id: \.self) { account in
                    Text(account).tag(account)
                }
            }.labelsHidden()
            
            Text("Step 2: Choose Output Document Format")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
            HStack() {
                Picker("Output", selection: $selectedOutputFormat) {
                    ForEach(outputFormats, id: \.self) {
                        Text($0)
                    }
                }.labelsHidden().pickerStyle(.segmented)
                // Button {
                //     // open settings
                // } label: {
                //     Image(systemName: "gear")
                // }.disabled(true)
            }
            
            Text("Step 3: Select Output File Destination").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            HStack() {
                Image(systemName: "info.circle")
                Text("Notes and folder structure are preserved in ZIP file for portability.")
            }
            HStack() {
                Image(systemName: "folder")
                Text(outputFilePath).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    selectOutputFile()
                } label: {
                    Text("Select")
                }.padding(.top, 7.0)
            }
            
            Text("Step 4: Export!").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            Button(action: {
                exportNotes()
            }) {
                Text("Export").frame(maxWidth: .infinity).font(.headline)
            }
            .buttonStyle(BorderedProminentButtonStyle())
            .disabled(!loaded)
            
            Text("Apple Notes Exporter v\(appVersion!) - Copyright © 2024 [Konstantin Zaremski](https://www.zaremski.com) - Licensed under the [MIT License](https://raw.githubusercontent.com/kzaremski/apple-notes-exporter/main/LICENSE)")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.vertical, 5.0)
        }
        .frame(width: 500.0, height: 320.0)
        .padding(10.0)
        .onAppear() {
            // Load the Apple Notes Accounts on startup
            DispatchQueue.global(qos: .userInitiated).async {
                var result:[String] = []
                    result = AppleScript.stringArray(script: """
                        set theAccountNames to {}
                        tell application "Notes"
                            repeat with theAccount in accounts
                                copy name of theAccount as string to end of theAccountNames
                            end repeat
                        end tell
                        return theAccountNames
                    """)
                // Set the accounts
                setNotesAccounts(notesAccounts: result)
            }
        }
        .sheet(isPresented: $showProgressWindow) {
            VStack {
                ProgressView {
                    Text("Exporting")
                    .bold()
                }
            }
            .frame(width: 160.0, height: 120.0)
            .allowsHitTesting(true)
            .onAppear {
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // Check if the pressed key is the Escape key
                    if event.keyCode == 53 {
                        // Prevent the event from propagating, hence preventing dismissal
                        return nil
                    }
                    return event
                }
            }
        }
        .alert(isPresented: $showNoOutputSelectedAlert) {
            Alert(
                title: Text("No Output File Chosen"),
                message: Text("Please choose the location for the ZIP file containing the exported Apple Notes."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

struct BorderedProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(8)
            .foregroundColor(.white)
            .background(configuration.isPressed ? Color.blue.opacity(0.8) : Color.blue)
            .cornerRadius(6)
            
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
