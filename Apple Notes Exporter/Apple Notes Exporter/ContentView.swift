//
//  ContentView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI
import Foundation

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
}

struct ContentView: View {
    func runAppleScript(script: String) {
        if let scriptObject = NSAppleScript(source: script) {
            var errorDict: NSDictionary? = nil
            let resultDescriptor = scriptObject.executeAndReturnError(&errorDict)
            
            if errorDict == nil {
                let subjectLines = resultDescriptor.toStringArray()
                for line in subjectLines {
                    print(line)
                }
            }
        }
    }
    
    func getNoteAccounts() {
        let loadAllScript = """
            set noteList to {}
            return { "test" }
            tell application "Notes"
                repeat with noteFolder in folders
                    repeat with myNote in notes of noteFolder
                        set noteTitle to name of myNote
                        set noteBody to body of myNote
                        set noteItem to {title:noteTitle, body:noteBody}
                        set end of noteList to noteItem
                    end repeat
                end repeat
                return noteList
            end tell
        """
        
        let countScript = """
            set AppleScript's text item delimiters to linefeed
            set noteList to {}
            tell application "Notes"
                repeat with noteFolder in folders
                    repeat with myNote in notes of noteFolder
                        set noteTitle to name of myNote
                        set end of noteList to noteTitle
                    end repeat
                end repeat
            end tell
            return noteList
        """
        
        runAppleScript(script: countScript)
    }
    
    let notesAccountMenuItems: [MenuItem] = [
        MenuItem(title: "Option 1") {
            // Handle action for Option 1
            
        },
        MenuItem(title: "Option 2") {
            // Handle action for Option 2
        },
    ]
    
    // Body of the
    var body: some View {
        VStack(alignment: .leading) {
            Text("Step 1: Select Notes Account")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
            Menu {
                ForEach(notesAccountMenuItems) { item in
                    Button(action: item.action) {
                        Text(item.title)
                    }
                }
            } label: {
                Text("Select Notes Account")
            }
            
            Text("Step 2: Choose Output Document Format")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
            ControlGroup {
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
            }
            
            Text("Step 3: Select Output File Destination").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            HStack() {
                Image(systemName: "info.circle")
                Text("Notes and folder structure are preserved in ZIP file for portability.")
            }
            HStack() {
                Image(systemName: "folder")
                Text("Select output file location.").frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    print("test")
                } label: {
                    Text("Select")
                }.padding(.top, 7.0)
            }
            
            Text("Step 4: Export!").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            Button(action: {
                getNoteAccounts()
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
    
    func greeting() {
        print("Hello, World!")
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
