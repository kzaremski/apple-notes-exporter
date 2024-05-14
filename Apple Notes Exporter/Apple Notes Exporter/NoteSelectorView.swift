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

struct NoteSelectorView: View {
    @Binding var showNoteSelectorView: Bool
    @Binding var selectedNotesCount: Int
    @Binding var fromAccountsCount: Int
    
    let items = ["Item 1", "Item 2", "Item 3", "Item 4", "Item 5"] // Example items
    
    var body: some View {
        VStack {
            Text("Select the accounts and foldes that you would like to include in the export.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            
            VStack {
                List {
                    ForEach(items, id: \.self) { item in
                        HStack {
                            Image(systemName: "globe")
                            Text(item)
                        }
                    }
                    List {
                        ForEach(items, id: \.self) { item in
                            HStack {
                                Image(systemName: "globe")
                                Text(item)
                            }
                        }
                    }
                    LoaderLine(label: "Querying Apple Notes for accounts...")
                }
                //.listStyle(PlainListStyle())
            }
            .frame(maxHeight: .infinity)
            .border(Color.gray, width: 1)
            .padding([.top, .bottom], 5)
                   
            HStack {
                HStack {
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
