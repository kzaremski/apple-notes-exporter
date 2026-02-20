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
                includeAttachments: exportViewModel.configurations.includeAttachments
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
    // Preferences (persisted across launches)
    @AppStorage("outputFormat") private var outputFormat = "HTML"
    @AppStorage("outputPath") private var outputPath: String = ""
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
    @State private var showSyncWarning: Bool = false
    @State private var now: Date = Date()
    private let syncTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    /// Formatted "last synced" string based on manifest in the selected output directory
    private var lastSyncedText: String {
        // Reference `now` so SwiftUI re-evaluates when the timer ticks
        _ = now
        guard let url = outputURL,
              let manifest = SyncManifest.load(from: url) else {
            return "Last synced never"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last synced \(formatter.localizedString(for: manifest.lastSync, relativeTo: Date()))"
    }

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
        VStack {
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
                    .animation(.easeInOut(duration: 0.15), value: isSelected)
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text(formatDescription(for: outputFormat))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.15), value: outputFormat)

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

            Text("Step 3: Choose Output Options")
                .font(.title)
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .padding(.top, 5)
                .padding(.bottom, titleBottomPadding)
            
            HStack() {
                Image(systemName: "folder")
                Text(
                    outputPath != "" ? (outputPath + (exportViewModel.configurations.concatenateOutput ? "/Exported Notes.\(outputFormat.lowercased())" : "")) : "Choose an output folder"
                ).frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .animation(.easeInOut(duration: 0.15), value: outputPath)
                .animation(.easeInOut(duration: 0.15), value: exportViewModel.configurations.concatenateOutput)
                Button {
                    selectOutputFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                    Text("Choose")
                }
            }

            VStack(spacing: 4) {
                HStack {
                    Toggle("Add date to filename", isOn: $exportViewModel.configurations.addDateToFilename)
                    Spacer()
                    Picker("", selection: $exportViewModel.configurations.filenameDateFormat) {
                        ForEach(FilenameDateFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .frame(width: 210)
                    .opacity(exportViewModel.configurations.addDateToFilename ? 1 : 0)
                    .disabled(!exportViewModel.configurations.addDateToFilename)
                }
                HStack {
                    Toggle("Include attachments", isOn: $exportViewModel.configurations.includeAttachments)
                    Spacer()
                }
                HStack {
                    Toggle("Concatenate into single file", isOn: $exportViewModel.configurations.concatenateOutput)
                        .disabled(exportViewModel.configurations.incrementalSync)
                    Spacer()
                }
                HStack {
                    Toggle("Incremental sync", isOn: $exportViewModel.configurations.incrementalSync)
                        .disabled(exportViewModel.configurations.concatenateOutput)
                    Spacer()
                }
            }
            .onChange(of: exportViewModel.configurations.addDateToFilename) { _ in exportViewModel.saveConfigurations() }
            .onChange(of: exportViewModel.configurations.filenameDateFormat) { _ in exportViewModel.saveConfigurations() }
            .onChange(of: exportViewModel.configurations.includeAttachments) { _ in exportViewModel.saveConfigurations() }
            .onChange(of: exportViewModel.configurations.concatenateOutput) { _ in exportViewModel.saveConfigurations() }
            .onChange(of: exportViewModel.configurations.incrementalSync) { _ in
                exportViewModel.saveConfigurations()
                showSyncWarning = exportViewModel.configurations.incrementalSync
            }

            // Sync overwrite warning
            VStack {
                if showSyncWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Sync will overwrite previously exported files. Apple Notes is the source of truth.")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(SwiftUI.Color.orange.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(SwiftUI.Color.orange.opacity(0.35), lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSyncWarning)

            Text("Step 4: Export!")
                .font(.title)
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .padding(.top, 5)
                .padding(.bottom, titleBottomPadding)
            Button(action: {
                triggerExportNotes()
            }) {
                Group {
                    if #available(macOS 13.0, *) {
                        Text(exportViewModel.configurations.incrementalSync ? "Sync (\(lastSyncedText))" : "Export")
                            .frame(maxWidth: .infinity).font(.headline)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.15), value: exportViewModel.configurations.incrementalSync)
                    } else {
                        Text(exportViewModel.configurations.incrementalSync ? "Sync (\(lastSyncedText))" : "Export")
                            .frame(maxWidth: .infinity).font(.headline)
                    }
                }
            }
            .buttonStyle(BorderedProminentButtonStyle())
            .onReceive(syncTimer) { now = $0 }
            
            Text("Apple Notes Exporter v\(APP_VERSION!) - Copyright © 2026 [Konstantin Zaremski](https://konstantin.zarem.ski) - Licensed under the [MIT License](https://raw.githubusercontent.com/kzaremski/apple-notes-exporter/main/LICENSE)")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.vertical, 5.0)
                .pointerOnHover()
        }
        }
        .frame(width: 500.0, height: showSyncWarning ? 455.0 : 410.0, alignment: .top)
        .padding(10.0)
        .onAppear {
            // Initialize sync warning state from persisted config
            showSyncWarning = exportViewModel.configurations.incrementalSync
            // Restore output URL from persisted path
            if !outputPath.isEmpty {
                outputURL = URL(fileURLWithPath: outputPath)
            }
            // If license was previously accepted, auto-load notes on launch
            if sharedState.licenseAccepted && !showLicensePermissionsView {
                sharedState.reload()
            }
        }
        .onReceive(sharedState.$triggerSelectNotes) { triggered in
            if triggered {
                sharedState.triggerSelectNotes = false
                showNoteSelectorView = true
            }
        }
        .onReceive(sharedState.$triggerChooseFolder) { triggered in
            if triggered {
                sharedState.triggerChooseFolder = false
                selectOutputFolder()
            }
        }
        .onReceive(sharedState.$triggerExport) { triggered in
            if triggered {
                sharedState.triggerExport = false
                triggerExportNotes()
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
