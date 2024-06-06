//
//  NoteSelectorView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/13/24.
//

import SwiftUI

struct LoaderLine: View {
    let label: String
    
    var body: some View {
        HStack{
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .padding(.trailing, -15)
                .scaleEffect(0.5)
            Text(label)
        }
    }
}

struct SelectorLineItem: View {
    @ObservedObject var sharedState: AppleNotesExporterState
    var itemXID: String
    
    private func getImage(level: Float) -> String {
        if level == 1.0 {
            return "checkmark.square"
        } else if level == 0.0 {
            return "square"
        } else {
            return "minus.square"
        }
    }
    
    func toggleSelected() {
        self.sharedState.itemByXID[itemXID]!.toggleSelected()
        self.sharedState.update()
    }
    
    init(sharedState: AppleNotesExporterState, itemXID: String) {
        self.sharedState = sharedState
        self.itemXID = itemXID
    }
    
    var body: some View {
        HStack {
            Image(systemName: self.sharedState.itemByXID[itemXID]!.icon).padding([.leading], 5).frame(width: 20)
            Text("\(self.sharedState.itemByXID[itemXID]!.description)").frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1) // Limit the text to one line
                .truncationMode(.tail)
            
            Button {
                toggleSelected()
            } label: {
                Image(systemName: getImage(level: self.sharedState.itemByXID[itemXID]!.proportionSelected)).padding([.leading], 5).frame(width: 23)
            }
            .buttonStyle(BorderlessButtonStyle())
            
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NoteSelectorView: View {
    @ObservedObject var sharedState: AppleNotesExporterState
    @Binding var showNoteSelectorView: Bool
    
    var body: some View {
        VStack {
            Text("Select the accounts, folders, and notes that you would like to include in the export.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            
            VStack {
                List {
                    if (sharedState.initialLoadComplete) {
                        if sharedState.root.count > 0 {
                            OutlineGroup(sharedState.root, children: \.children) { item in
                                SelectorLineItem(sharedState: sharedState, itemXID: item.xid)
                            }
                        } else {
                            Text("No notes or note accounts were found!")
                        }
                    } else {
                        LoaderLine(label: sharedState.initialLoadMessage)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .leading)
            .border(Color.gray, width: 1)
            .padding([.top, .bottom], 5)
            
            HStack {
                HStack {
                    Image(systemName: "info.circle")
                    Text("Notes that are locked with a password cannot be exported.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Button {
                    showNoteSelectorView = false
                } label: {
                    Text("Done")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
