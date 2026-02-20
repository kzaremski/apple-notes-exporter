//
//  ContentView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI
import Foundation

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
    @EnvironmentObject var notesViewModel: NotesViewModel
    @EnvironmentObject var exportViewModel: ExportViewModel

    /// Get description for each export format
    private func formatDescription(for format: String) -> String {
        switch format {
        case "HTML":
            return "Standard web format with full styling and images."
        case "PDF":
            return "Portable document format for sharing and printing."
        case "MD":
            return "Markdown format for documentation, wikis, and Obsidian, etc."
        case "TXT":
            return "Plain text format compatible with any editor."
        case "RTF":
            return "Rich text format for word processors."
        case "TEX":
            return "For typesetting within LaTeX software."
        default:
            return ""
        }
    }

    /// Get SF Symbol icon name for each export format
    private func formatIcon(for format: String) -> String {
        switch format {
        case "HTML":
            return "globe"
        case "PDF":
            return "doc.richtext"
        case "TEX":
            return "function"
        case "MD":
            return "number"
        case "RTF":
            return "doc.text"
        case "TXT":
            return "text.alignleft"
        default:
            return "doc"
        }
    }

    func setProgressWindow(_ state: Bool?) {
        self.sharedState.showProgressWindow = state ?? !self.sharedState.showProgressWindow
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

        // Convert output format string to enum
        guard let format = ExportFormat(rawValue: outputFormat) else {
            return
        }

        // Reset
        sharedState.update()

        // Show the export progress window
        setProgressWindow(true)

        // Do the export using the new ExportViewModel
        Task {
            await exportViewModel.exportNotes(
                notesViewModel.selectedNotes,
                toDirectory: outputURL!,
                format: format,
                includeAttachments: true
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

        // Use async begin() instead of blocking runModal() to avoid race conditions
        openPanel.begin { response in
            if response == .OK, let exportURL = openPanel.url {
                self.outputURL = exportURL
                self.outputPath = exportURL.path as String
            }
        }
    }
    
    private enum ActiveAlert {
        case noneSelected
        case noOutput
    }
    
    init(sharedState: AppleNotesExporterState) {
        self.sharedState = sharedState
    }
    
    // ** State
    // Data
    @ObservedObject private var sharedState: AppleNotesExporterState
    // Preferences
    @State private var outputFormat = "HTML"
    @State private var outputPath: String = ""
    @State private var outputURL: URL? = nil
    // Show/hide different views
    @State private var showLicensePermissionsView: Bool = !UserDefaults.standard.bool(forKey: "licenseAccepted")
    @State private var showNoteSelectorView: Bool = false
    @State private var showFormatOptionsView: Bool = false
    @State private var showProgressWindow: Bool = false
    @State private var showErrorExportingAlert: Bool = false
    @State private var showAlert: Bool = false
    @State private var activeAlert: ActiveAlert = .noneSelected
    @State private var showConfigurePopover: Bool = false
    
    // Adjust spacing for macOS 15+ which has increased title font spacing
    private var titleBottomPadding: CGFloat {
        if #available(macOS 15.0, *) {
            return -5
        } else {
            return 0
        }
    }

    // Body of the ContentView
    var body: some View {
        VStack(alignment: .leading) {
            Text("Step 1: Select Notes")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
                .padding(.bottom, titleBottomPadding)
            HStack() {
                Image(systemName: "list.bullet.clipboard")
                Text(notesViewModel.loadingState.isLoading ? "Querying database" : "\(self.sharedState.selectedNotesCount) note\(self.sharedState.selectedNotesCount == 1 ? "" : "s") from \(self.sharedState.fromAccountsCount) account\(self.sharedState.fromAccountsCount == 1 ? "" : "s")")
                    .overlay(
                        GeometryReader { geometry in
                            if notesViewModel.loadingState.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(0.5)
                                    .offset(x: geometry.size.width + 2, y: -7)
                            }
                        }
                    )
                Spacer()
                Button {
                    showNoteSelectorView = true
                } label: {
                    Image(systemName: "scope")
                    Text("Select")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Text("Step 2: Choose Export Format")
                .font(.title)
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .padding(.top, 5)
                .padding(.bottom, titleBottomPadding)

            HStack(spacing: 6) {
                ForEach(OUTPUT_FORMATS, id: \.self) { format in
                    let isSelected = outputFormat == format
                    Button(action: {
                        outputFormat = format
                    }) {
                        VStack(spacing: 3) {
                            Image(systemName: formatIcon(for: format))
                                .font(.system(size: 16))
                                .frame(height: 20)
                            Text(format)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundColor(isSelected ? .white : .secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? SwiftUI.Color.accentColor : SwiftUI.Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? SwiftUI.Color.clear : SwiftUI.Color.gray.opacity(0.3), lineWidth: 1)
                    )
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text(formatDescription(for: outputFormat))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    let configurableFormats = ["HTML", "PDF", "TEX", "RTF"]
                    if configurableFormats.contains(outputFormat) {
                        showFormatOptionsView = true
                    } else {
                        showConfigurePopover = true
                    }
                } label: {
                    let isConfigurable = ["HTML", "PDF", "TEX", "RTF"].contains(outputFormat)
                    Image(systemName: "gear")
                        .foregroundColor(isConfigurable ? .primary : .secondary)
                        .opacity(isConfigurable ? 1.0 : 0.8)
                    Text("Options")
                        .foregroundColor(isConfigurable ? .primary : .secondary)
                        .opacity(isConfigurable ? 1.0 : 0.8)
                }
                .popover(isPresented: $showConfigurePopover, arrowEdge: .trailing) {
                    VStack {
                        Text("There are no configuration options available for this format.")
                    }
                    .frame(width: 240, height: 60)
                }
            }

            Text("Step 3: Choose Output Folder")
                .font(.title)
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .padding(.top, 5)
                .padding(.bottom, titleBottomPadding)
            
            HStack() {
                Image(systemName: "folder")
                Text(
                    outputPath != "" ? outputPath : "Choose an output folder"
                ).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    selectOutputFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                    Text("Choose")
                }
            }
            
            Text("Step 4: Export!")
                .font(.title)
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .padding(.top, 5)
                .padding(.bottom, titleBottomPadding)
            Button(action: {
                triggerExportNotes()
            }) {
                Text("Export").frame(maxWidth: .infinity).font(.headline)
            }
            .buttonStyle(BorderedProminentButtonStyle())
            
            Text("Apple Notes Exporter v\(APP_VERSION!) - Copyright © 2025 [Konstantin Zaremski](https://konstantin.zarem.ski) - Licensed under the [MIT License](https://raw.githubusercontent.com/kzaremski/apple-notes-exporter/main/LICENSE)")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.vertical, 5.0)
                .pointerOnHover()
        }
        .frame(width: 500.0, height: 320.0)
        .padding(10.0)
        .onAppear {
            // If license was previously accepted, auto-load notes on launch
            if sharedState.licenseAccepted && !showLicensePermissionsView {
                sharedState.reload()
            }
        }
        .sheet(isPresented: $sharedState.showProgressWindow) {
            ExportView(
                sharedState: sharedState
            )
            .frame(width: 400)
            .fixedSize(horizontal: false, vertical: true)
            .allowsHitTesting(true)
            .onAppear {
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // Detect Escape Key Press
                    if event.keyCode == 53 {
                        // Prevent Propagation
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
                showNoteSelectorView: $showNoteSelectorView
            ).frame(width: 600, height: 400)
        }
        .sheet(isPresented: $showFormatOptionsView) {
            if let format = ExportFormat(rawValue: outputFormat) {
                FormatOptionsView(
                    showOptionsView: $showFormatOptionsView,
                    format: format
                )
            }
        }
        .sheet(isPresented: $showLicensePermissionsView) {
            LicensePermissionsView(
                sharedState: sharedState,
                showLicensePermissionsView: $showLicensePermissionsView
            ).frame(width: 600, height: 400)
            .onAppear {
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // Detect Escape Key Press
                    if event.keyCode == 53 {
                        // Prevent Propagation
                        return nil
                    }
                    return event
                }
            }
        }
    }
}

// MARK: - Pointer Cursor for Links

extension View {
    /// Show a pointing hand cursor on hover (for hyperlinks)
    func pointerOnHover() -> some View {
        self.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct BorderedProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(8)
            .foregroundColor(.white)
            .background(configuration.isPressed ? SwiftUI.Color.blue.opacity(0.8) : SwiftUI.Color.blue)
            .cornerRadius(6)
            
    }
}
