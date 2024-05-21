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
    var selected: Bool              // If the item is selected for exporting
    var proportionSelected: Float   // Proportion of the item that is selected
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
        self.proportionSelected = 0.0
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
    
    func updateProportionSelected() {
        switch type {
        case .ICAccount, .ICFolder:
            // Not selectable if there are no children
            if self.children == nil {
                self.proportionSelected = 0.0
            }
            // Proportion selected (proportion of each item x in children / number of children)
            var x: Float = 0.0
            let n: Int = self.children!.count
            // Total up x
            for item in children! {
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
