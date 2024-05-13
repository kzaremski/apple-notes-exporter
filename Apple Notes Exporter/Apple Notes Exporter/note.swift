//
//  Note.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/12/24.
//

import Foundation

struct Note {
    var ID: String = ""
    var title: String = ""
    var content: String = ""
    var creationDate: Date = Date()
    var modificationDate: Date = Date()
    var path: [String] = []
    var attachments: [String] = []
    var tags: [String] = []
    // Selection (selected notes are the notes that will be exported)
    var selected: Bool = false
    // Loaded notes are notes that have been loaded from Apple Notes via. AppleScript
    var loaded: Bool = false
    var exported: Bool = false
    var exportedAttachments: Bool = false
    
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

struct NoteFolder {
    var notes: [Note]
    var folders: [NoteFolder]
    var name: String
    
    mutating func addNote(note: Note) {
        self.notes.append(note)
    }
    
    mutating func addFolder(folder: NoteFolder) {
        self.folders.append(folder)
    }
}

struct NoteAccount {
    var container: NoteFolder
    var name: String
    var xID: String
    
    static func getAllAccounts() {
        
    }
}
