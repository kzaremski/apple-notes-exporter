//
//  ContentView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI
import WebKit
import Foundation
import UniformTypeIdentifiers
import AppKit
import Cocoa

extension Binding {
    func onChange(_ handler: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue
                handler(newValue)
            }
        )
    }
}

struct AppleNotesExporterView: View {
    @Environment(\.openURL) var openURL

    func setProgressWindow(_ state: Bool?) {
        showProgressWindow = state ?? !showProgressWindow
    }
    
    func triggerExportNotes() {
        // ** Validate
        // No notes selected
        if self.sharedState.selectedNotesCount == 0 {
            self.activeAlert = .noneSelected
            self.showAlert = true
            return
        }
        // No output folder or file chosen
        if self.outputPath == "" {
            self.activeAlert = .noOutput
            self.showAlert = true
            return
        }
        
        // Reset
        sharedState.update()
        
        // Show the export progress window
        setProgressWindow(true)
        // Do the export in the global DispatcheQueue as an async operation so that it does not block the UI
        DispatchQueue.global(qos: .userInitiated).async {
            exportNotes(
                sharedState: sharedState,
                outputURL: outputURL!,
                outputFormat: outputFormat
            )
        }
    }
    
    /**
     Select the output folder.
     */
    func selectOutputFolder() {
        let openPanel = NSOpenPanel()
        
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.canChooseFiles = false
        openPanel.prompt = "Select Folder"

        if openPanel.runModal() == .OK, let exportURL = openPanel.url {
            self.outputURL = exportURL
            self.outputPath = exportURL.path as String
        }
    }
    
    private enum ActiveAlert {
        case noneSelected
        case noOutput
    }
    
    // ** State
    // If the initial load is complete
    @State private var initialLoadComplete: Bool = false
    // Data
    @ObservedObject private var sharedState = AppleNotesExporterState()
    // Preferences
    @State private var outputFormat = "HTML"
    @State private var outputPath: String = ""
    @State private var outputURL: URL? = nil
    // Show/hide different views
    @State private var showNoteSelectorView: Bool = false
    @State private var showProgressWindow: Bool = false
    @State private var showErrorExportingAlert: Bool = false
    @State private var showAlert: Bool = false
    @State private var activeAlert: ActiveAlert = .noneSelected
    
    // Body of the ContentView
    var body: some View {
        VStack(alignment: .leading) {
            Text("Step 1: Select Notes")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
            HStack() {
                Image(systemName: "list.bullet.clipboard")
                Text("\(self.sharedState.selectedNotesCount) note\(self.sharedState.selectedNotesCount == 1 ? "" : "s") from \(self.sharedState.fromAccountsCount) account\(self.sharedState.fromAccountsCount == 1 ? "" : "s")")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    showNoteSelectorView = true
                } label: {
                    Text("Select")
                }
            }
            
            Text("Step 2: Choose Export Format")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
            HStack() {
                Picker("Output", selection: $outputFormat) {
                    ForEach(OUTPUT_FORMATS, id: \.self) {
                        Text($0)
                    }
                }.labelsHidden().pickerStyle(.segmented)
                // Button {
                //     // open settings
                // } label: {
                //     Image(systemName: "gear")
                // }.disabled(true)
            }
            
            Text("Step 3: Set Output Folder").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            .labelsHidden()
            .pickerStyle(.segmented)
            
            HStack() {
                Image(systemName: "folder")
                Text(
                    outputPath != "" ? outputPath : "Choose an output folder"
                ).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    selectOutputFolder()
                } label: {
                    Text("Select")
                }//.padding(.top, 7.0)
            }
            
            Text("Step 4: Export!").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            Button(action: {
                triggerExportNotes()
            }) {
                Text("Export").frame(maxWidth: .infinity).font(.headline)
            }
            .buttonStyle(BorderedProminentButtonStyle())
            
            Text("Apple Notes Exporter v\(APP_VERSION!) - Copyright © 2024 [Konstantin Zaremski](https://www.zaremski.com) - Licensed under the [MIT License](https://raw.githubusercontent.com/kzaremski/apple-notes-exporter/main/LICENSE)")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.vertical, 5.0)
        }
        .frame(width: 500.0, height: 300.0)
        .padding(10.0)
        .onAppear() {
            DispatchQueue.global(qos: .userInitiated).async {
                self.initialLoadComplete = false
                initialLoad(sharedState: sharedState)
                self.initialLoadComplete = true
            }
        }
        .sheet(isPresented: $showProgressWindow) {
            ExportView(
                showProgressWindow: $showProgressWindow,
                sharedState: sharedState
            )
            .frame(width: 600, height: 400)
            .allowsHitTesting(true)
            .onAppear {
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // Check if the pressed key is the Escape key
                    if event.keyCode == 53 {
                        // Prevent the event from propagating, hence preventing dismissal
                        return nil
                    }
                    return event
                }
            }
        }
        .alert(isPresented: $showAlert) {
            switch self.activeAlert {
            case .noneSelected:
                Alert(
                    title: Text("No Notes Selected for Export"),
                    message: Text("Please select at least one note that you would like to export."),
                    dismissButton: .default(Text("OK"))
                )
            case .noOutput:
                Alert(
                    title: Text("No Output Folder Chosen"),
                    message: Text("Please choose folder where you would like the exported notes to be saved."),
                    dismissButton: .default(Text("OK"))
                )
            }
            
        }
        .sheet(isPresented: $showNoteSelectorView) {
            NoteSelectorView(
                sharedState: sharedState,
                showNoteSelectorView: $showNoteSelectorView,
                initialLoadComplete: $initialLoadComplete
            ).frame(width: 600, height: 400)
        }
    }
}

struct BorderedProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(8)
            .foregroundColor(.white)
            .background(configuration.isPressed ? Color.blue.opacity(0.8) : Color.blue)
            .cornerRadius(6)
            
    }
}

struct AppleNotesExporterView_Previews: PreviewProvider {
    static var previews: some View {
        AppleNotesExporterView()
    }
}
