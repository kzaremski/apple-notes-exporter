//
//  ContentView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct MenuItem: Identifiable {
    let id = UUID()
    let title: String
    let action: () -> Void
}

extension NSAppleEventDescriptor {
    func toStringArray() -> [String] {
        guard let listDescriptor = self.coerce(toDescriptorType: typeAEList) else {
            return []
        }
        
        return (0..<listDescriptor.numberOfItems)
            .compactMap { listDescriptor.atIndex($0 + 1)?.stringValue }
    }
    
    func toStringDictionary() -> [String : String] {
        guard let listDescriptor = self.coerce(toDescriptorType: typeAERecord) else {
            return [:]
        }
        
        print(listDescriptor)
        
        return [:]
        
        //return (0..<listDescriptor.numberOfItems).compactMap { listDescriptor.atIndex($0 + 1)?.stringValue }
    }
    
        /*func convertToSwiftObject(descriptor: NSAppleEventDescriptor) -> Any? {
        switch descriptor.descriptorType {
        case .nullDescriptor:
            return nil
        case .booleanDescriptor:
            return descriptor.booleanValue
        case .typeUTF8Text, .typeUnicodeText:
            return descriptor.stringValue
        case .typeInteger:
            return descriptor.intValue
        case .typeFloat:
            return descriptor.floatValue
        case .typeDouble:
            return descriptor.doubleValue
        case .dateDescriptor:
            return descriptor.dateValue
        case .descriptorTypeAlias:
            return descriptor.fileURLValue
        case .listDescriptor:
            var swiftArray = [Any]()
            for i in 1...descriptor.numberOfItems {
                if let itemDescriptor = descriptor.descriptor(at: i) {
                    if let item = convertToSwiftObject(itemDescriptor) {
                        swiftArray.append(item)
                    }
                }
            }
            return swiftArray
        case .recordDescriptor:
            var swiftDictionary = [String: Any]()
            if let keysDescriptor = descriptor.coerce(toDescriptorType: .typeAEList) {
                let keysCount = keysDescriptor.numberOfItems
                for i in 1...keysCount {
                    if let keyDescriptor = keysDescriptor.descriptor(at: i),
                       let key = keyDescriptor.stringValue,
                       let valueDescriptor = descriptor.descriptor(forKeyword: keyDescriptor.typeCodeValue) {
                        if let value = convertToSwiftObject(valueDescriptor) {
                            swiftDictionary[key] = value
                        }
                    }
                }
            }
            return swiftDictionary
        default:
            return descriptor.stringValue
        }
    }*/
}

struct AppleScript {
    /**
     Runs an AppleScript script string with an expected string array result.
     */
    func stringArray(script: String) -> [String] {
        // Create the new NSAppleScript instance
        if let scriptObject = NSAppleScript(source: script) {
            // Error dictionary
            var errorDict: NSDictionary? = nil
            // Execute the script, adding to the errorDict if there are errors
            let resultDescriptor = scriptObject.executeAndReturnError(&errorDict)
            // If there are no errors, return the resultDescriptor after converting it to a string array
            if errorDict == nil {
                return resultDescriptor.toStringArray()
            }
        }
        // Return an empty string if no result
        return []
    }
    
    func stringDictionary(script: String) -> [String : String] {
        // Create the new NSAppleScript instance
        if let scriptObject = NSAppleScript(source: script) {
            // Error dictionary
            var errorDict: NSDictionary? = nil
            // Execute the script, adding to the errorDict if there are errors
            let resultDescriptor = scriptObject.executeAndReturnError(&errorDict)
            // If there are no errors, return the resultDescriptor after converting it to a string array
            if errorDict == nil {
                return resultDescriptor.toStringDictionary()
            }
        }
        // Return an empty string if no result
        return [:]
    }
}

struct ContentView: View {
    func exportNotes() {
        // Script to export the notes from the current account
        let exportScript = """
            set noteList to {}
            tell application "Notes"
                repeat with theAccount in accounts
                    if name of theAccount as string = "\(selectedNotesAccount)" then
                        set chosenAccount to theAccount
                    end if
                end repeat
                repeat with noteFolder in folders
                    repeat with myNote in notes of noteFolder
                        set noteTitle to name of myNote
                        set noteBody to body of myNote
        --body:noteBody,
                        set noteItem to {title:noteTitle, folder:noteFolder}
                        set end of noteList to noteItem
                    end repeat
                end repeat
                return noteList
            end tell
        """
        
        AppleScript().stringDictionary(script: exportScript)
    }
    
    init() {
        self._selectedNotesAccount = State(initialValue: notesAccounts.first ?? "")
    }
    
    /**
     Select the output file location. It is a ZIP file in the directory of the user's choosing.
     */
    func selectOutputFile() {
        guard let documentURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        
        let savePanel = NSSavePanel()
        // Default file name of something like:   Apple Notes Export 2023-05-25.zip
        savePanel.allowedContentTypes = [UTType.zip]
        savePanel.nameFieldStringValue = "Apple Notes Export " + ISO8601DateFormatter().string(from: Date()).split(separator: "T")[0] + ".zip"
        
        if savePanel.runModal() == .OK, let exportURL = savePanel.url {
            self.outputFilePath = exportURL.path
            self.outputFileURL = exportURL
        }
    }
    
    // State of the interface and form inputs
    @State private var notesAccounts: [String] = AppleScript().stringArray(script: """
            tell application "Notes"
                set theAccountNames to {}
                repeat with theAccount in accounts
                    copy name of theAccount as string to end of theAccountNames
                end repeat
            end tell
        """)
    @State private var selectedNotesAccount = ""
    @State private var selectedOutputFormat = "HTML"
    @State private var outputFilePath = "Select output file location"
    @State private var outputFileURL: URL?
    
    // Body of the ContentView
    var body: some View {
        VStack(alignment: .leading) {
            Text("Step 1: Select Notes Account")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
            Picker("Input", selection: $selectedNotesAccount) {
                ForEach(self.notesAccounts, id: \.self) {
                    Text($0).tag($0)
                }
            }.labelsHidden()
            
            Text("Step 2: Choose Output Document Format")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
            Picker("Output", selection: $selectedOutputFormat) {
                ForEach(["HTML","PDF","RTFD"], id: \.self) {
                    Text($0)
                }
            }.labelsHidden().pickerStyle(.segmented)
            /*ControlGroup {
             Button {} label: {
             Image(systemName: "doc.text")
             Text("HTML")
             }
             Button {} label: {
             Image(systemName: "doc.append")
             Text("PDF")
             }
             Button {} label: {
             Image(systemName: "doc.richtext")
             Text("RTFD")
             }
             }*/
            
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
                Text("Export").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
            
            Text("Apple Notes Exporter v0.1 - Copyright © 2023 Konstantin Zaremski - Licensed under the [MIT License](https://raw.githubusercontent.com/kzaremski/apple-notes-exporter/main/LICENSE)")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.vertical, 5.0)
        }
        .frame(width: 500.0, height: 320.0)
        .padding(10.0)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
