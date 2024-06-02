//
//  Note.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/12/24.
//

import Foundation
import WebKit

enum ICItemError: Error {
    case pdfCreationError(description: String)
}

// ICItem Types based on what comes out of the Apple Events
enum ICItemType {
    case ICAccount
    case ICFolder
    case ICNote
    case ICAttachment
    case Invalid
}

class ICItem: Identifiable, Hashable, CustomStringConvertible {
    let id: UUID                            // UUID for identification within OutlineGroups
    var xid: String                         // XID of the ICItem itself
    var type: ICItemType                    // Type of the ICItem (ICAccount, ICFolder, ICNote, ICAttachment)
    var children: [ICItem]? = nil           // Children (if this ICItem can have children)
    var selected: Bool = false              // If the item is selected for exporting
    var proportionSelected: Float = 0.0     // Proportion of the item that is selected
    var container: String = ""              // XID of the ICItem's parent container (parent ICItem)
    var account: String = ""                // XID of the account that owns this ICItem
    var name: String = ""                   // Name of the ICItem (eg. title of note, folder name, account name)
    var creationDate: Date = Date()         // Date of creation (if applicable)
    var modificationDate: Date = Date()     // Date of last modification (if applicable)
    var body: String = ""                   // Body of the note (if applicable)
    var exporting: Bool = false             // Flag for if the note is exporting
    var pending: Bool {
        // If it is a note/attachment, it is pending when it is exporting
        if (self.type == .ICNote || self.type == .ICAttachment) && self.children == nil {
            return exporting
        // Otherwise, it is pending when any of its children (recursively) are pending
        } else if self.type == .ICAccount || self.type == .ICFolder || self.children != nil {
            // Check if the current item's children are pending
            if let children = self.children {
                for child in children {
                    if child.pending {
                        return true
                    }
                }
            }
            
            // If not found, return nil
            return false
        }
        return false
    }
    var loaded: Bool = false                // Flag for if the note is completely loaded
    var saved: Bool = false                 // Flag for if the note has been saved to an output file
    var attachmentsExported: Bool = false   // Flag for if the note's attachments have been exported
    var exported: Bool {
        // If it is a note/attachment it is exported when it has been saved
        if (self.type == .ICNote || self.type == .ICAttachment) && self.children == nil {
            return saved
        // Otherwise, it is pending when any of its children (recursively) are pending
        } else if self.type == .ICAccount || self.type == .ICFolder || self.children != nil {
            // Check if the current item's children are not exported
            if let children = self.children {
                for child in children {
                    if !child.exported {
                        return false
                    }
                }
            }
            
            // If not found, it is exported
            return true
        }
        return true
    }
    var failed: Bool = false                // Flag for if the note has failed exporting
    var error: Bool {
        // If it is a note, it is an error when it has failed
        if (self.type == .ICNote || self.type == .ICAttachment) && self.children == nil {
            return failed
        // Otherwise, has an error when any of its children (recursively) have errors
        } else if self.type == .ICAccount || self.type == .ICFolder || self.children != nil {
            // Check if the current item's children have an error
            if let children = self.children {
                for child in children {
                    if child.error {
                        return true
                    }
                }
            }
            
            // If it is a note and it has an error, then it has an error
            if self.type == .ICNote {
                return failed
            }
            
            // If not found, return nil
            return false
        }
        return false
    }
    var logString: String = ""              // String that contains a mini-logfile for this specific note, that will be viewable by the user
    
    init(xid: String) {
        self.id = UUID()
        self.xid = xid
        // Infer type based on XID
        if xid.contains("ICNote") {
            self.type = .ICNote
        } else if xid.contains("ICAccount") {
            self.type = .ICAccount
        } else if xid.contains("ICAttachment") {
            self.type = .ICAttachment
        } else if xid.contains("ICFolder") {
            self.type = .ICFolder
        } else {
            self.type = .Invalid
            print("Warning: This XID did not yield a clue as to what kind of object it is: \(xid)")
        }
    }
    
    init(from: ICItem) {
        self.id = UUID()
        self.xid = from.xid
        self.type = from.type
        self.children = nil
        self.selected = from.selected
        self.proportionSelected = 0.0
        self.container = from.container
        self.account = from.account
        self.name = from.name
        self.creationDate = from.creationDate
        self.modificationDate = from.modificationDate
        self.body = from.body
        self.exporting = false
        self.loaded = false
        self.failed = false
        self.logString = ""
        self.attachmentsExported = false
        // Calculate the proportion selected
        updateProportionSelected()
    }
    
    /**
     Log a message in the note's log.
     */
    func log(_ message: String) {
        // Determine the date string to label the log with
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateString = dateFormatter.string(from: Date())
        let logLine = "[\(dateString)] \(message)"
        print(logLine)
        self.logString += "\(logLine)\n"
    }
 
    /**
     Append a new ICItem as a child to this ICItem instance.
     */
    func appendChild(child: ICItem) {
        if self.children == nil {
            self.children = [child]
        } else {
            self.children!.append(child)
        }
    }
    
    var description: String {
        return "\(name)"
    }
    
    var icon: String {
        switch type {
        case .ICAccount:
            return "globe"
        case .ICFolder:
            return "folder"
        case .ICNote:
            return "doc"
        case .ICAttachment:
            return "paperclip"
        case .Invalid:
            return "exclamationmark.questionmark"
        }
    }
    
    // Equality
    static func == (lhs: ICItem, rhs: ICItem) -> Bool {
        return lhs.id == rhs.id
    }
    
    // Implementation of hashability
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    func loadName() {
        switch type {
        case .ICAccount:
            self.name = AppleNotesScriptLayer.getAccountName(xid: self.xid)
        case .ICFolder:
            self.name = AppleNotesScriptLayer.getFolderName(xid: self.xid)
        case .ICNote:
            self.name = AppleNotesScriptLayer.getNoteName(xid: self.xid)
        case .ICAttachment:
            self.name = AppleNotesScriptLayer.getAttachmentName(xid: self.xid)
            // If the attachment does not have a name, it's name is now the last part of the XID
            if self.name == "" {
                self.name = self.xid.components(separatedBy: "/").last!
            }
        case .Invalid:
            self.name = self.xid
        }
    }
    
    func loadContainer() {
        switch type {
        case .ICAccount:
            self.container = ""
        case .ICFolder:
            self.container = AppleNotesScriptLayer.getFolderContainer(xid: self.xid)
        case .ICNote:
            self.container = AppleNotesScriptLayer.getNoteContainer(xid: self.xid)
        case .ICAttachment:
            self.container = ""
        case .Invalid:
            self.container = ""
        }
    }
    
    func load() {
        switch type {
        case .ICAccount:
            self.name = AppleNotesScriptLayer.getAccountName(xid: self.xid)
        case .ICFolder:
            self.name = AppleNotesScriptLayer.getFolderName(xid: self.xid)
        case .ICNote:
            do {
                // Get the whole note contents
                let noteDict = try AppleNotesScriptLayer.getNote(xid: self.xid)
             
                // Make sure that the name and IDs match what we already have
                if noteDict["name"]! != self.name || noteDict["id"]! != self.xid {
                    log("Discrepancy in note XID and note name, integrity of exported notes is not possible.\nDetails:\n --> Expected XID: \(self.xid), Actual XID: \(noteDict["id"] ?? "")\n --> Expected name: \(self.name), Actual name: \(noteDict["name"] ?? "")")
                    self.failed = true
                    return
                }
                // Update the new values
                self.body = noteDict["body"]!
                self.creationDate = appleDateStringToDate(inputString: noteDict["creationDate"]!)
                self.modificationDate = appleDateStringToDate(inputString: noteDict["modificationDate"]!)
                if noteDict["attachments"]! != "" {
                    // Create a new attachment for each ICItem
                    for attachmentXID in noteDict["attachments"]!.components(separatedBy: ",") {
                        let ICAttachment = ICItem(xid: attachmentXID)
                        ICAttachment.loadName()
                        appendChild(child: ICAttachment)
                    }
                } else {
                    self.children = nil
                }
            } catch {
                self.failed = true
                log("Failed to load: \(error)")
            }
        case .ICAttachment:
            self.name = AppleNotesScriptLayer.getAttachmentName(xid: self.xid)
        case .Invalid:
            self.name = self.xid
        }
        // Identify self as being loaded
        self.loaded = true
    }
    
    func updateProportionSelected() {
        switch type {
        case .ICAccount, .ICFolder:
            // Guard clause to check if children is nil (for things that may contain a child)
            guard let children = self.children else {
                self.proportionSelected = 0.0
                return
            }
            
            // Proportion selected (proportion of each item x in children / number of children)
            var x: Float = 0.0
            let n: Int = children.count
            // Total up x
            for item in children {
                item.updateProportionSelected()
                x += item.proportionSelected
            }
            // Calculate the proportion
            let p: Float = Float(x) / Float(n)
            self.proportionSelected = p
        case .ICNote:
            self.proportionSelected = self.selected ? 1.0 : 0.0
        case .ICAttachment:
            self.proportionSelected = 0.0
        case .Invalid:
            self.proportionSelected = 0.0
        }
    }
    
    func toggleSelected(to: Bool? = nil) {
        // Get the proportion selected
        self.updateProportionSelected()
        
        // Decide if we should select all or select none
        let newSelected: Bool = (to != nil ? to! : self.proportionSelected != 1.0)
        
        switch type {
        case .ICAccount, .ICFolder:
            // Not selectable if there are no children
            if self.children == nil {
                self.selected = false
                break
            }
            // Toggle all sub-items
            for item in self.children! {
                item.toggleSelected(to: newSelected)
            }
        case .ICNote:
            self.selected = newSelected
        case .ICAttachment:
            break
        case .Invalid:
            break
        }
        
        // Update the proportion selected
        self.updateProportionSelected()
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
        <title>\(self.name)</title>
    </head>
    <body>
        <style>
            body {
                padding: 2em;
                font-family: sans-serif;
                white-space: pre;
            }
        </style>
        <div width="500">
        \(self.body)
        </div>
    </body>
</html>
"""
        return outputHTMLString
    }
    
    func toPDF() throws -> Data {
        // DispatchGroup
        let group = DispatchGroup()
        group.enter()
        
        // Empty data
        var outputData: Data = Data()
                
        // HTML string
        let htmlString = self.toHTMLString()
        
        // Error String
        var errorString: String?
        
        // Run on the main thread
        DispatchQueue.main.async {
            let htmlToPDFConverter = HTMLtoPDF(htmlString: htmlString)
            // Run the conversion
            htmlToPDFConverter.convert { result in
                switch result {
                case .success(let data):
                    outputData = data
                case .failure(let error):
                    errorString = "\(error)"
                }
                // Leave the group after processing the result
                group.leave()
            }
        }
        
        // When the DispatchGroup is done
        group.wait()
        
        // Throw error if the error string has contents
        if errorString != nil {
            throw ICItemError.pdfCreationError(description: errorString ?? "No error description available.")
        }
        // Otherwise return the data
        return outputData
    }
    
    func toLaTeXString() -> String {
        // Get the HTML string of the content (less common tags)
        let htmlStringLines = self.body
            .replacingOccurrences(of: "<div>", with: "")
            .replacingOccurrences(of: "</div>", with: "")
            .replacingOccurrences(of: "<br>", with: "")
            .replacingOccurrences(of: "<object>", with: "")
            .replacingOccurrences(of: "</object>", with: "")
            .replacingOccurrences(of: "\\", with: "\textbackslash")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "%", with: "\\%")
            .components(separatedBy: "\n")
        
        // Create an output string
        var outputString =
"""
\\documentclass[12pt, letterpaper]{article}
\\title{\(self.name)}
\\date{\(self.creationDate)}
\\begin{document}
\\maketitle
"""
        
        // For each HTML line
        for htmlLine in htmlStringLines {
            // Markdown line
            var latexLine = htmlLine
            
            // ** Conversion
            // Headings
            latexLine = latexLine.replacingOccurrences(of: "<h1>", with: "\n\\section*{").replacingOccurrences(of: "</h1>", with: "}")
            latexLine = latexLine.replacingOccurrences(of: "<h2>", with: "\n\\section*{").replacingOccurrences(of: "</h2>", with: "}")
            latexLine = latexLine.replacingOccurrences(of: "<h3>", with: "\n\\section*{").replacingOccurrences(of: "</h3>", with: "}")
            latexLine = latexLine.replacingOccurrences(of: "<h4>", with: "\n\\section*{").replacingOccurrences(of: "</h4>", with: "}")
            latexLine = latexLine.replacingOccurrences(of: "<h5>", with: "\n\\section*{").replacingOccurrences(of: "</h5>", with: "}")
            latexLine = latexLine.replacingOccurrences(of: "<h6>", with: "\n\\section*{").replacingOccurrences(of: "</h6>", with: "}")
            // Lists
            latexLine = latexLine.replacingOccurrences(of: "<ul>", with: "\n\\begin{itemize}").replacingOccurrences(of: "</ul>", with: "\\end{itemize}")
            latexLine = latexLine.replacingOccurrences(of: "<ol>", with: "\n\\begin{enumerate}").replacingOccurrences(of: "</ul>", with: "\\end{enumerate}")
            latexLine = latexLine.replacingOccurrences(of: "li", with: "\n\\item ").replacingOccurrences(of: "</ul>", with: " \n")
            // Styles
            latexLine = latexLine.replacingOccurrences(of: "<b>", with: "\\textbf{").replacingOccurrences(of: "</b>", with: "}")
            latexLine = latexLine.replacingOccurrences(of: "<i>", with: "\\textit{").replacingOccurrences(of: "</i>", with: "}")
            latexLine = latexLine.replacingOccurrences(of: "<tt>", with: "\\texttt{").replacingOccurrences(of: "</tt>", with: "}")
            
            // Add the markdown line to the output string
            outputString = outputString + "\n" + latexLine
        }
        
        outputString = outputString + "\n\\end{document}\n"
        
        // Return the parsed markdown
        return outputString
    }
    
    func toMarkdownString() -> String {
        // Get the HTML string of the content (less common tags)
        let htmlStringLines = self.body
            .replacingOccurrences(of: "<div>", with: "")
            .replacingOccurrences(of: "</div>", with: "")
            .replacingOccurrences(of: "<br>", with: "")
            .replacingOccurrences(of: "<object>", with: "")
            .replacingOccurrences(of: "</object>", with: "")
            .split(separator: "\n")
        
        // Create an output string
        var outputString = ""

        // Mode
        //let MD_CONVERSION_MODE_NORMAL = 0
        //let MD_CONVERSION_MODE_ORDEREDLIST = 1
        //let MD_CONVERSION_MODE_UNORDEREDLIST = 2
        //let MD_CONVERSION_MODE_TABLE = 3
        //var mode = MD_CONVERSION_MODE_NORMAL
        
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
            
            // Add the markdown line to the output string
            outputString = outputString + "\n" + markdownLine
        }
        
        // Return the parsed markdown
        return outputString
    }
    
    func toAttributedStringWithImages() throws -> NSAttributedString {
        // Get the HTML content of the note
        let htmlString = self.toHTMLString()
        
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
        
        // Return the new attributed string
        return attributedString
    }
    
    func toAttributedString() throws -> NSAttributedString {
        // Get the HTML content of the note
        let htmlString = self.toHTMLString()
        
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
        
        // Return the new attributed string
        return attributedString
    }
    
    func save(toFolder: URL, format: String?, withAttachments: Bool) {
        if self.type == .ICNote {
            // Can't save if it isn't loaded yet!
            if loaded == false {
                return
            }
            
            // Determine the save filename
            var fileNumber: Int = 1
            var fileURL: URL = toFolder
            var attachmentsFolderURL: URL = toFolder
            repeat {
                fileURL = toFolder.appendingPathComponent("\(sanitizeFileNameString(self.name))\(fileNumber > 1 ? " (\(fileNumber))" : "").\(format!.lowercased())")
                attachmentsFolderURL = toFolder.appendingPathComponent("\(sanitizeFileNameString(self.name))\(fileNumber > 1 ? " (\(fileNumber))" : "") Attachments")
                fileNumber += 1
            } while FileManager.default.fileExists(atPath: fileURL.path)
            
            // Export/save the note to the output file
            //     Different formats require different procedures
            if format == "PDF" {
                do {
                    let outputData = try self.toPDF()
                    try outputData.write(to: fileURL)
                } catch {
                    self.log("Failed to save note content as PDF: \(error)")
                    self.failed = true
                }
            } else if format == "HTML" {
                do {
                    let outputData = self.toHTMLString().data(using: .utf8)!
                    try outputData.write(to: fileURL)
                } catch {
                    self.log("Failed to save note content as HTML: \(error)")
                    self.failed = true
                }
            } else if format == "TEX" {
                do {
                    let outputData = self.toLaTeXString().data(using: .utf8)!
                    try outputData.write(to: fileURL)
                } catch {
                    self.log("Failed to save note content as TEX: \(error)")
                    self.failed = true
                }
            } else if format == "MD" {
                do {
                    let outputData = self.toMarkdownString().data(using: .utf8)!
                    try outputData.write(to: fileURL)
                } catch {
                    self.log("Failed to save note content as MD: \(error)")
                    self.failed = true
                }
            } else if format == "RTF" {
                do {
                    let attributedString = try self.toAttributedString()
                    let rtfAttributedString = attributedString.rtf(
                        from: NSRange(location: 0, length: attributedString.length),
                        documentAttributes: [:]
                    )!
                    try rtfAttributedString.write(to: fileURL)
                } catch {
                    self.log("Failed to save note content as RTF: \(error)")
                    self.failed = true
                }
            } else {
                do {
                    let attributedString = try self.toAttributedString()
                    let outputData = attributedString.string.data(using: .utf8)!
                    try outputData.write(to: fileURL)
                } catch {
                    self.log("Failed to save note content as TXT: \(error)")
                    self.failed = true
                }
            }
            
            // Update the saved status
            self.saved = true
            
            if withAttachments {
                // Export/save the attachments to the folder path that was determined
                guard let attachments = self.children else {
                    return
                }
                
                // Create the attachments folder
                createDirectoryIfNotExists(location: attachmentsFolderURL)
                
                // For each attachment
                for attachment in attachments {
                    attachment.exporting = true
                    attachment.save(toFolder: attachmentsFolderURL, format: "", withAttachments: false)
                    attachment.exporting = false
                }
            }
        } else if self.type == .ICAttachment {
            // Determine the save filename
            var fileNumber: Int = 1
            var fileURL: URL = toFolder
            repeat {
                let sanitizedNameString = sanitizeFileNameString(self.name)
                var fileNameParts = sanitizedNameString.components(separatedBy: ".")
                if fileNameParts.count > 1 && fileNumber > 1 {
                    fileNameParts[fileNameParts.count - 2] = "\(fileNameParts[fileNameParts.count - 2]) (\(fileNumber))"
                }
                fileURL = toFolder.appendingPathComponent(fileNameParts.joined(separator: "."))
                fileNumber += 1
            } while FileManager.default.fileExists(atPath: fileURL.path)
            
            // Save the attachment
            do {
                try AppleNotesScriptLayer.saveAttachment(xid: self.xid, path: fileURL)
                self.saved = true
            } catch {
                self.log("Failed to save attachment \(self.xid): \(error)")
                self.failed = true
            }
        }
    }
    
    /**
     Find a child ICItem by XID.
     - Parameter xid: The XID of the ICItem to find.
     - Returns: The ICItem with the given XID, or nil if not found.
     */
    func find(xid: String) -> ICItem? {
        // Check if the current item's children contain the desired xid
        if let children = self.children {
            for child in children {
                if child.xid == xid {
                    return child
                }
                if let found = child.find(xid: xid) {
                    return found
                }
            }
        }
        
        // If not found, return nil
        return nil
    }
}
