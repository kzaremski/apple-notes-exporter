//
//  ContentView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI
import AppKit
import SQLite3
import Foundation

struct MenuItem: Identifiable {
    let id = UUID()
    let title: String
    let action: () -> Void
}

struct ContentView: View {
    func getNoteAccounts() {
        // Connect to the local AppleNotes SQLite3 database
        let sourceURL = URL(fileURLWithPath: "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite", relativeTo: FileManager.default.homeDirectoryForCurrentUser)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
            print("File copied to temporary directory: \(tempURL.path)")
        } catch {
            print("Error copying file: \(error)")
        }
        
        var db: OpaquePointer?
        if sqlite3_open(tempURL.path, &db) == SQLITE_OK {
            // Database connection is open, perform SQLite operations

            // Close the database connection when done
            if sqlite3_close(db) == SQLITE_OK {
                print("Database connection closed successfully.")
            } else {
                print("Failed to close the database connection.")
            }
        } else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("Failed to open the database: \(errorMessage)")
        }
          

        print("File URL: \(tempURL.path)")

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
                Button {} label: {
                    Text("Browse")
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
