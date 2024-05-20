//
//  Note.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/12/24.
//

import Foundation

// ICItem Types based on what comes out of the Apple Events
enum ICItemType {
    case ICAccount
    case ICFolder
    case ICNote
    case ICAttachment
    case Invalid
}

class ICItem: Identifiable, Hashable, CustomStringConvertible {
    let id: UUID                    // UUID for identification within OutlineGroups
    var type: ICItemType            // Type of the ICItem (ICAccount, ICFolder, ICNote, ICAttachment)
    var children: [ICItem]? = nil   // Children (if this ICItem can have children)
    var selected: Bool = false      // If the ICItem is selected for exporting
    var xid: String                 // XID of the ICItem itself
    var container: String           // XID of the ICItem's parent container (parent ICItem)
    var name: String                // Name of the ICItem (eg. title of note, folder name, account name)
    var creationDate: Date          // Date of creation (if applicable)
    var modificationDate: Date      // Date of last modification (if applicable)
    var content: String             // Body/content of the item (if applicable)
    
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
        self.selected = false
        self.container = ""
        self.name = ""
        self.content = ""
        self.creationDate = Date()
        self.modificationDate = Date()
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
