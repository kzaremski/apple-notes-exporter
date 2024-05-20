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
    @ObservedObject var sharedState: AppleNotesExporterState
    @Binding var showNoteSelectorView: Bool
    @Binding var selectedNotesCount: Int
    @Binding var fromAccountsCount: Int
    @Binding var initialLoadComplete: Bool
    
    var body: some View {
        VStack {
            Text("Select the accounts, folders, and notes that you would like to include in the export.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            
            VStack {
                List {
                    if (initialLoadComplete) {
                        if sharedState.root.count > 0 {
                            OutlineGroup(sharedState.root, children: \.children) { item in
                                SelectorLineItem(item: item)
                            }
                        } else {
                            Text("No notes or note accounts were found!")
                        }
                    } else {
                        LoaderLine(label: sharedState.initialLoadMessage)
                        if false {
                            HStack {
                                VStack {
                                    Image(systemName: "info.circle")
                                }.frame(maxHeight: .infinity, alignment: .top)
                                
                                VStack {
                                    Text("If you have a very large notes library querying them can take a long time. If you just want to select accounts and folders, you can skip querying notes for their details. Notes will still appear in the selector, but will have their ID in place of their titles. Skipping this initial query will not affect export time.")
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(nil)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: .infinity, alignment: .leading)
                            
                            Button {
                                //showNoteSelectorView = false
                            } label: {
                                Text("Skip Note Query")
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding([.leading], 20)
                            .padding([.top], 10)
                        }
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
