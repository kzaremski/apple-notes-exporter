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
