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
    func privilegedCopy(sourcePath: String, destinationPath: String) -> Bool {
        let authorizationRef: AuthorizationRef? = nil
        
        var authStatus: OSStatus = AuthorizationCreate(nil, nil, [], &authorizationRef)
        guard authStatus == errAuthorizationSuccess else {
            print("Failed to create authorization: \(authStatus)")
            return false
        }
        
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = URL(fileURLWithPath: destinationPath)
        
        var arguments = [String]()
        arguments.append("-R") // Recursive copy
        arguments.append(sourceURL.path)
        arguments.append(destinationURL.path)
        
        let task = Process()
        task.launchPath = "/bin/cp"
        task.arguments = arguments
        
        // Set up the authorization rights
        var authorizationRightExecute = kAuthorizationRightExecute.withCString { $0 }
        var rights: [AuthorizationItem] = [
            AuthorizationItem(name: &authorizationRightExecute, valueLength: 0, value: nil, flags: 0)
        ]
        let rightsCount = UInt32(rights.count)
        var items = AuthorizationRights(count: rightsCount, items: &rights)
        var authFlags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        
        // Pre-authorize the authorization reference
        authStatus = AuthorizationCopyRights(authorizationRef!, &items, nil, authFlags, nil)
        guard authStatus == errAuthorizationSuccess else {
            print("Authorization copy rights failed: \(authStatus)")
            return false
        }
        
        // Execute the privileged task
        authStatus = AuthorizationExecuteWithPrivileges(authorizationRef!, task.launchPath!, AuthorizationFlags(), task.arguments!, nil)
        guard authStatus == errAuthorizationSuccess else {
            print("Failed to execute privileged task: \(authStatus)")
            return false
        }
        
        return true
    }

    
    func getNoteAccounts() {
        let success = privilegedCopy(sourcePath: "~/Library/Group\\ Containers/group.com.apple.notes/NoteStore.sqlite", destinationPath: "$TMPDIR")
        
        // Connect to the local AppleNotes SQLite3 database
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("NoteStore.sqlite")
                
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
