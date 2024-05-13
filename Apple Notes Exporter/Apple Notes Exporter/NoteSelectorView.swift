//
//  NoteSelectorView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/13/24.
//

import SwiftUI

struct NoteSelectorView: View {
    @Binding var showNoteSelectorView: Bool
    @Binding var selectedNotesCount: Int
    @Binding var fromAccountsCount: Int
    let data = [
            ListItem(name: "Parent 1", children: [
                ListItem(name: "Child 1"),
                ListItem(name: "Child 2")
            ]),
            ListItem(name: "Parent 2", children: [
                ListItem(name: "Child 3"),
                ListItem(name: "Child 4")
            ])
        ]


    var body: some View {
        VStack {
            Text("Select the accounts, folders, and notes that you would like to include in the export.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Spacer()
            HStack {
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
