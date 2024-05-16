//
//  NoteSelectorView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/13/24.
//

import SwiftUI

struct MenuItem: Identifiable {
    var id = UUID()
    var name: String
    var image: String
    var subMenuItems: [MenuItem]?
}

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
    @State var item: ICItem
    @State var selected: Bool = false
    
    init(item: ICItem) {
        self.item = item
        self.selected = item.selected
    }
    
    var body: some View {
        HStack {
            Image(systemName: item.icon).padding([.leading], 5).frame(width: 20)
            Text("\(item.description)").frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1) // Limit the text to one line
                .truncationMode(.tail)
            Toggle("", isOn: $selected)
                .toggleStyle(.checkbox)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NoteSelectorView: View {
    @Binding var showNoteSelectorView: Bool
    @Binding var selectedNotesCount: Int
    @Binding var fromAccountsCount: Int
    @Binding var initialLoadComplete: Bool
    
    @State var data = AppleNotesExporterData.root
    
    var body: some View {
        VStack {
            Text("Select the accounts, folders, and notes that you would like to include in the export.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            
            VStack {
                List {
                    if (initialLoadComplete) {
                        if data.count > 0 {
                            OutlineGroup(data, children: \.children) { item in
                                SelectorLineItem(item: item)
                            }
                        } else {
                            Text("No notes or note accounts were found!")
                        }
                    } else {
                        LoaderLine(label: "Querying Apple Notes for accounts, this may take a few minutes...")
                    }
                }
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
                    Text("Cancel")
                }
                Button {
                    //
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
