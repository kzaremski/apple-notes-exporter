//
//  ExportView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/13/24.
//

import SwiftUI
import OSLog

struct ExportLineItem: View {
    @ObservedObject var sharedState: AppleNotesExporterState
    var item: ICItem
    @State var logPopoverVisible = false
    
    private func getImage() -> String {
        if self.item.error {
            return "⚠️"
        } else if self.item.exported && self.item.logString == "" {
            return "✅"
        } else if self.item.exported && self.item.logString != "" {
            return "⚠️✅"
        } else {
            return "⏳"
        }
    }
    
    init(sharedState: AppleNotesExporterState, item: ICItem) {
        self.sharedState = sharedState
        self.item = item
    }
    
    var body: some View {
        HStack {
            Image(systemName: item.icon).padding([.leading], 5).frame(width: 20)
            Text("\(item.description)").frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1) // Limit the text to one line
                .truncationMode(.tail)
            
            // If the item is exporting, show the loader
            if self.item.pending {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .padding(0)
                    .scaleEffect(0.5)
                    .frame(width: 20, height: 15)
            } else {
                if self.item.error || self.item.logString != "" {
                    Button {
                        self.logPopoverVisible = !self.logPopoverVisible
                    } label: {
                        Text(getImage())
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .popover(isPresented: $logPopoverVisible, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
                        ScrollView {
                            Text(
                                self.item.logString != "" ?
                                self.item.logString : (self.item.children != nil ? "An error occured while exporting this item's children." : "An error occurred while exporting this item.")
                            ).frame(width: 350, alignment: .leading)
                                .multilineTextAlignment(.leading).padding(10)
                                .contextMenu(ContextMenu(menuItems: {
                                    Button("Copy", action: {
                                        NSPasteboard.general.setString(self.item.logString, forType: .string)
                                    })
                                }))
                        }
                    }
                } else {
                    Text(getImage())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ExportView: View {
    @ObservedObject var sharedState: AppleNotesExporterState

    var body: some View {
        VStack {
            VStack {
                List {
                    if sharedState.selectedRoot.count > 0 {
                        OutlineGroup(sharedState.selectedRoot, children: \.children) { item in
                            ExportLineItem(sharedState: sharedState, item: item)
                        }
                    } else {
                        Text("No notes were selected for export. If you are seeing this, this is a bug.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .leading)
            .border(Color.gray, width: 1)
            .padding([.top, .bottom], 5)
            
            ProgressView(value: sharedState.exportPercentage)
                .progressViewStyle(LinearProgressViewStyle())
            
            HStack {
                HStack {
                    Text(sharedState.exportMessage)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                if sharedState.exporting {
                    Button {
                        Logger.noteExport.info("User triggered export cancellation")
                        sharedState.shouldCancelExport = true
                    } label: {
                        Text(sharedState.shouldCancelExport ? "Cancelling" : "Cancel Export")
                    }.disabled(sharedState.shouldCancelExport)
                } else {
                    Button {
                        sharedState.showProgressWindow = false
                    } label: {
                        Text("Done")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
