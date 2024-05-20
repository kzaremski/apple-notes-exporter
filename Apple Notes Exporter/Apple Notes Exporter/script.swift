//
//  AppleScript.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 7/11/23.
//

import Foundation

extension NSAppleEventDescriptor {
    func toStringArray() -> [String] {
        guard let listDescriptor = self.coerce(toDescriptorType: typeAEList) else {
            return []
        }
        
        return (0..<listDescriptor.numberOfItems)
            .compactMap { listDescriptor.atIndex($0 + 1)?.stringValue }
    }
    
    func toArray() -> [NSAppleEventDescriptor] {
        guard let listDescriptor = self.coerce(toDescriptorType: typeAEList) else {
            return []
        }
        
        return (0..<listDescriptor.numberOfItems)
            .compactMap { listDescriptor.atIndex($0 + 1) }
    }
}

/**
 NSAppleScript wrappers with coercions to desired Swift types.
 */
struct AppleScript {
    /**
     Runs an AppleScript with an expected string array result/output.
     */
    static func stringArrayOutput(_ script: String) -> [String] {
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
        // Return an empty array if no result
        return []
    }
    
    /**
     Runs an AppleScript with an expected string result/output.
     */
    static func stringOutput(_ script: String) -> String {
        // Create the new NSAppleScript instance
        if let scriptObject = NSAppleScript(source: script) {
            // Error dictionary
            var errorDict: NSDictionary? = nil
            // Execute the script, adding to the errorDict if there are errors
            let resultDescriptor = scriptObject.executeAndReturnError(&errorDict)
            // If there are no errors, return the resultDescriptor after converting it to a string array
            if errorDict == nil {
                // If the descriptor can be properly coerced into a string, return that string value
                if let value = resultDescriptor.stringValue {
                    return value
                }
            }
        }
        // Return an empty string if no result
        return ""
    }
    
    /**
     Runs an AppleScript without parsing the result descriptor, only returning the result descriptor.
     */
    static func wildcard(_ script: String) -> NSAppleEventDescriptor? {
        // Create the new NSAppleScript instance
        if let scriptObject = NSAppleScript(source: script) {
            // Error dictionary
            var errorDict: NSDictionary? = nil
            // Execute the script, adding to the errorDict if there are errors
            let resultDescriptor = scriptObject.executeAndReturnError(&errorDict)
            // If there are no errors, return the resultDescriptor
            if errorDict == nil {
               return resultDescriptor
            }
        }
        // Return an empty event descriptor
        return nil
    }
}

struct AppleNotesScriptLayer {
    static func getAllAccounts() -> [String] {
        let output = AppleScript.stringOutput(
            """
            tell application id "com.apple.Notes"
                set AppleScript's text item delimiters to ","
                return id of accounts as string
            end tell
            """
        );
        
        if output == "" {
            return []
        } else {
            return output.components(separatedBy: ",")
        }
    }
    
    static func getAccountName(xid: String) -> String {
        let output = AppleScript.stringOutput(
            """
            tell application id "com.apple.Notes"
                return name of account id "\(xid)"
            end tell
            """
        );
        
        return output
    }
    
    static func getAccountNotes(xid: String) -> [String] {
        let output = AppleScript.stringOutput(
            """
            tell application id "com.apple.Notes"
                set AppleScript's text item delimiters to ","
                set theAccount to account id "\(xid)"
                return id of note of theAccount as string
            end tell
            """
        );
        
        if output == "" {
            return []
        } else {
            return output.components(separatedBy: ",")
        }
    }
    
    static func getAccountNotesRich(xid: String) -> [[String:String]] {
        // Get output from the get all accoutn notes script
        let scriptOutput = AppleScript.wildcard(
            """
            tell application id "com.apple.Notes"
                set AppleScript's text item delimiters to "\n"
                set theAccount to account id "\(xid)"
                return {id of note of theAccount as string, name of note of theAccount as string, container of note of theAccount}
            end tell
            """
        );
        
        // Empty output array
        var output: [[String:String]] = []
        
        // If the script output isnt nil (no error), do things with it
        if scriptOutput != nil {
            // Parse the result descriptor as an array
            let scriptOutputArray = scriptOutput!.toArray()
            // The component parts of that array represent different values
            let xids = scriptOutputArray[0].stringValue!.components(separatedBy: "\n")
            let names = scriptOutputArray[1].stringValue!.components(separatedBy: "\n")
            let containers = scriptOutputArray[2].toArray()
            
            // For each note in the returned notes
            for index in 0..<xids.count {
                // Get the container object at the current note's index
                let containerDescriptor = containers[index]
                // Empty container XID
                var containerXID: String = ""
                // Extract the XID of the container from the AppleScript container class
                if let keyData = containerDescriptor.forKeyword(AEKeyword(keyAEKeyData)) {
                    containerXID = keyData.stringValue!
                }
                // Create the string dictionary that will represent the note
                let note: [String:String] = [
                    "xid": xids[index],
                    "name": names[index],
                    "container": containerXID
                ]
                // Append the dictionary to the output array
                output.append(note)
            }
        }
        
        // Return the output array
        return output
    }
    
    static func getFolderName(xid: String) -> String {
        let output = AppleScript.stringOutput(
            """
            tell application id "com.apple.Notes"
                return name of folder id "\(xid)"
            end tell
            """
        );
        
        return output
    }
    
    static func getNoteName(xid: String) -> String {
        let output = AppleScript.stringOutput(
            """
            tell application id "com.apple.Notes"
                return name of note id "\(xid)"
            end tell
            """
        );
        
        return output
    }
    
    static func getNoteContainerPath(xid: String) -> String {
        let output = AppleScript.stringOutput(
            """
            tell application id "com.apple.Notes"
                set activeNote to note id "\(xid)"
                set containerPath to ""
                
                set currentContainer to container of activeNote
                set containerPath to id of currentContainer as string
                
                repeat
                    try
                        set parentContainer to container of currentContainer
                        set containerPath to (id of parentContainer as string) & "," & containerPath
                        set currentContainer to parentContainer
                    on error
                        exit repeat
                    end try
                end repeat
                
                return containerPath
            end tell
            """
        );
        
        return output
    }
    
    static func getNoteContainer(xid: String) -> String {
        let output = AppleScript.stringOutput(
            """
            tell application id "com.apple.Notes"
                set theContainer to container of note id "\(xid)"
                return id of theContainer as string
            end tell
            """
        );
        
        return output
    }
    
    static func getFolderContainer(xid: String) -> String {
        let output = AppleScript.stringOutput(
            """
            tell application id "com.apple.Notes"
                set theContainer to container of folder id "\(xid)"
                return id of theContainer as string
            end tell
            """
        );
        
        return output
    }
    
    static func getNoteLockedStatus(xid: String) -> Bool {
        return false
    }
    
    static func getNoteCreationDate(xid: String) -> Date {
        return Date()
    }
    
    static func getNoteModificationDate(xid: String) -> Date {
        return Date()
    }
    
    static func getNoteBody(xid: String) -> String {
        return ""
    }
    
    static func getNoteAttachmentsXIDs(xid: String) -> [String] {
        return []
    }
    
    static func getNotePath(xid: String) -> String {
        return ""
    }
    
    static func getAttachmentName(xid: String) -> String {
        let output = AppleScript.stringOutput(
            """
            tell application id "com.apple.Notes"
                return name of attachment id "\(xid)"
            end tell
            """
        );
        
        return output
    }
}
