//
//  AppleNotesExporterView.swift
//  Apple Notes Exporter
//
//  Copyright (C) 2026 Konstantin Zaremski
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
        case "JSON":
            return "Structured note data for APIs and data processing."
        case "JSONL":
            return "One JSON object per line for LLM and RAG pipelines."
        case "XML":
            return "Structured note data in XML for interoperability."
        case "CSV":
            return "Flat table format for spreadsheets and databases."
        case "OPML":
            return "Outline format for RSS readers and outliners."
        case "ORG":
            return "Emacs Org-mode format for notes and task management."
        case "RST":
            return "reStructuredText for Sphinx and Python documentation."
        case "ADOC":
            return "AsciiDoc format for technical documentation."
        case "DOCX":
            return "Microsoft Word format for Office and Google Docs."
        case "ODT":
            return "OpenDocument text for LibreOffice and open-source editors."
        case "EPUB":
            return "E-book format for Kindle, Apple Books, and readers."
        case "ENEX":
            return "Evernote export format for import into Evernote, Joplin, etc."
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
        case "JSON":
            return "curlybraces"
        case "JSONL":
            return "list.dash"
        case "XML":
            return "chevron.left.forwardslash.chevron.right"
        case "CSV":
            return "rectangle.split.3x3"
        case "OPML":
            return "list.bullet.indent"
        case "ORG":
            return "leaf"
        case "RST":
            return "text.book.closed"
        case "ADOC":
            return "doc.plaintext"
        case "DOCX":
            return "doc.fill"
        case "ODT":
            return "doc.text.fill"
        case "EPUB":
            return "book"
        case "ENEX":
            return "square.and.arrow.up.on.square"
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
        // A destination left over from a different container would fail late
        // and confusingly, so treat it as unset here.
        normalizeOutputPathForContainer()
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
    /// Forget the chosen destination when the container changes.
    ///
    /// The three containers do not mean the same thing by "output": ZIP names
    /// a file, the other two name a directory. Carrying a path across a switch
    /// leaves a value the new mode has to reinterpret, so the user picks again
    /// with the right panel.
    func clearOutputPathIfContainerChanged(wasZip: Bool, wasSingle: Bool, nowZip: Bool, nowSingle: Bool) {
        guard wasZip != nowZip || wasSingle != nowSingle else { return }
        outputPath = ""
        outputURL = nil
    }

    /// Drop a stored destination the current container cannot use.
    ///
    /// outputPath is persisted, so clearing it only when the container changes
    /// is not enough: an archive path chosen in a previous session comes back
    /// on the next launch even if Folder is now selected, and the export then
    /// tries to create a directory where that .zip file already sits. A folder
    /// path under ZIP is fine, since the archive is named inside it.
    func normalizeOutputPathForContainer() {
        guard !outputPath.isEmpty else { return }
        let ext = (outputPath as NSString).pathExtension.lowercased()
        // Only extensions this app produces are treated as a filename; a
        // directory legitimately called "my.notes" must not be discarded.
        let ours = Set(ExportFormat.allCases.map(\.fileExtension)).union(["zip"])

        let isZip = exportViewModel.configurations.zipOutput
        let isSingle = exportViewModel.configurations.concatenateOutput && !isZip

        let stale: Bool
        if isZip {
            stale = ours.contains(ext) && ext != "zip"
        } else if isSingle {
            // The extension has to match the format being written, so
            // switching MD to TXT invalidates the stored name too.
            stale = ours.contains(ext) && ext != ExportFormat(rawValue: outputFormat)?.fileExtension
        } else {
            stale = ours.contains(ext)
        }
        guard stale else { return }
        outputPath = ""
        outputURL = nil
    }

    /// The filename and type to offer in a save panel, or nil when the
    /// container writes into a directory instead.
    func savePanelTarget() -> (name: String, type: UTType?)? {
        if exportViewModel.configurations.zipOutput {
            return ("\(ExportViewModel.zipRootName).zip", .zip)
        }
        guard exportViewModel.configurations.concatenateOutput,
              let format = ExportFormat(rawValue: outputFormat) else { return nil }
        let ext = format.fileExtension
        // Not every export extension maps to a registered type (adoc, enex and
        // friends); leaving it unset just means the panel does not filter.
        return ("\(concatenatedFileBaseName).\(ext)", UTType(filenameExtension: ext))
    }

    func selectOutputFolder() {
        // ZIP and Single File both produce exactly one file, so the user names
        // that file rather than picking a directory to be filled.
        if let (suggestedName, contentType) = savePanelTarget() {
            let savePanel = NSSavePanel()
            if let contentType { savePanel.allowedContentTypes = [contentType] }
            savePanel.canCreateDirectories = true
            savePanel.nameFieldStringValue = suggestedName
            savePanel.prompt = "Choose"
            savePanel.begin { response in
                if response == .OK, let exportURL = savePanel.url {
                    self.outputURL = exportURL
                    self.outputPath = exportURL.path
                }
            }
            return
        }

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
    // Show/hide different views.
    // Show license/permissions view on first launch OR when Full Disk Access has been
    // revoked since the last launch (e.g. user toggled it off in System Settings).
    @State private var showLicensePermissionsView: Bool = {
        let licenseAccepted = UserDefaults.standard.bool(forKey: "licenseAcceptedGPLv3")
        return !licenseAccepted || !hasNotesDatabaseAccess()
    }()
    @State private var showNoteSelectorView: Bool = false
    @State private var showFormatOptionsView: Bool = false
    @State private var showMCPSetupView: Bool = false
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

            // Format selector grid: 3 rows of 6
            let columns = 6
            let rows = Int(ceil(Double(OUTPUT_FORMATS.count) / Double(columns)))
            VStack(spacing: 4) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<columns, id: \.self) { col in
                            let index = row * columns + col
                            if index < OUTPUT_FORMATS.count {
                                let format = OUTPUT_FORMATS[index]
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
                            } else {
                                // Empty placeholder to maintain grid alignment
                                SwiftUI.Color.clear
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
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
            
            HStack(spacing: 8) {
                let canConcatenate = ExportFormat(rawValue: outputFormat)?.supportsConcatenation ?? false
                let isZip = exportViewModel.configurations.zipOutput
                let isSingle = exportViewModel.configurations.concatenateOutput && !isZip

                OutputContainerButton(
                    title: "Folder",
                    icon: "folder",
                    isSelected: !isZip && !isSingle
                ) {
                    clearOutputPathIfContainerChanged(wasZip: isZip, wasSingle: isSingle,
                                                      nowZip: false, nowSingle: false)
                    exportViewModel.configurations.zipOutput = false
                    exportViewModel.configurations.concatenateOutput = false
                    exportViewModel.saveConfigurations()
                }
                OutputContainerButton(
                    title: "ZIP Archive",
                    icon: "doc.zipper",
                    isSelected: isZip
                ) {
                    clearOutputPathIfContainerChanged(wasZip: isZip, wasSingle: isSingle,
                                                      nowZip: true, nowSingle: false)
                    exportViewModel.configurations.zipOutput = true
                    exportViewModel.configurations.concatenateOutput = false
                    // A sync manifest has to live in a folder that persists
                    // between runs, so it cannot travel inside an archive.
                    exportViewModel.configurations.incrementalSync = false
                    showSyncWarning = false
                    exportViewModel.saveConfigurations()
                }
                OutputContainerButton(
                    title: "Single File",
                    icon: "doc.text",
                    isSelected: isSingle,
                    isEnabled: canConcatenate,
                    disabledHelp: "\(outputFormat) is a packaged format, so its notes cannot be joined into one file."
                ) {
                    clearOutputPathIfContainerChanged(wasZip: isZip, wasSingle: isSingle,
                                                      nowZip: false, nowSingle: true)
                    exportViewModel.configurations.concatenateOutput = true
                    exportViewModel.configurations.zipOutput = false
                    exportViewModel.configurations.incrementalSync = false
                    showSyncWarning = false
                    exportViewModel.saveConfigurations()
                }
            }
            .padding(.bottom, 6)

            HStack() {
                Image(systemName: exportViewModel.configurations.zipOutput
                        ? "doc.zipper"
                        : (exportViewModel.configurations.concatenateOutput ? "doc.text" : "folder"))
                Text({
                    if exportViewModel.configurations.zipOutput {
                        guard outputPath != "" else { return "Choose where to save the archive" }
                        if outputPath.lowercased().hasSuffix(".zip") { return outputPath }
                        return outputPath + "/\(ExportViewModel.zipRootName).zip"
                    }
                    let format = ExportFormat(rawValue: outputFormat)
                    let single = exportViewModel.configurations.concatenateOutput
                        && (format?.supportsConcatenation ?? false)
                    if single, let ext = format?.fileExtension {
                        guard outputPath != "" else { return "Choose where to save the file" }
                        if outputPath.lowercased().hasSuffix("." + ext) { return outputPath }
                        return outputPath + "/\(concatenatedFileBaseName).\(ext)"
                    }
                    guard outputPath != "" else { return "Choose an output folder" }
                    return outputPath
                }()).frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .animation(.easeInOut(duration: 0.15), value: outputPath)
                .animation(.easeInOut(duration: 0.15), value: exportViewModel.configurations.concatenateOutput)
                .animation(.easeInOut(duration: 0.15), value: exportViewModel.configurations.zipOutput)
                Button {
                    selectOutputFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                    Text("Choose")
                }
            }

            VStack(spacing: outputOptionRowSpacing) {
                let isZip = exportViewModel.configurations.zipOutput
                let isSingle = exportViewModel.configurations.concatenateOutput && !isZip

                // One file the user already named: there is no per-note
                // filename for a date to prefix.
                if !isSingle {
                    OutputOptionRow(
                        title: "Add date to filename",
                        help: "Prefix each exported file with the note's creation date, so files sort chronologically.",
                        isOn: $exportViewModel.configurations.addDateToFilename
                    ) {
                        Picker("", selection: $exportViewModel.configurations.filenameDateFormat) {
                            ForEach(FilenameDateFormat.allCases, id: \.self) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .frame(width: 210)
                        .opacity(exportViewModel.configurations.addDateToFilename ? 1 : 0)
                        .disabled(!exportViewModel.configurations.addDateToFilename)
                    }
                    .transition(.opacity)
                }

                OutputOptionRow(
                    title: "Include attachments",
                    help: "Export images, PDFs, drawings, and other files attached to each note.",
                    isOn: $exportViewModel.configurations.includeAttachments
                )

                OutputOptionRow(
                    title: "Shared Attachments folder",
                    help: "Collect every attachment in one Attachments folder at the top level, instead of a folder beside each note.",
                    isOn: $exportViewModel.configurations.sharedAttachmentsFolder,
                    isEnabled: exportViewModel.configurations.includeAttachments
                )

                // A manifest has to persist in a folder between runs, so it
                // cannot travel inside an archive or a single joined file.
                if !isSingle && !isZip {
                    OutputOptionRow(
                        title: "Incremental sync",
                        help: "Only export notes that are new or changed since the last export to this folder. Notes deleted from Apple Notes are removed from the output.",
                        isOn: $exportViewModel.configurations.incrementalSync
                    )
                    .transition(.opacity)
                }
            }
            .onChange(of: exportViewModel.configurations.addDateToFilename) { _ in exportViewModel.saveConfigurations() }
            .onChange(of: exportViewModel.configurations.filenameDateFormat) { _ in exportViewModel.saveConfigurations() }
            .onChange(of: exportViewModel.configurations.includeAttachments) { _ in exportViewModel.saveConfigurations() }
            .onChange(of: exportViewModel.configurations.sharedAttachmentsFolder) { _ in exportViewModel.saveConfigurations() }
            .onChange(of: exportViewModel.configurations.concatenateOutput) { _ in exportViewModel.saveConfigurations() }
            .onChange(of: exportViewModel.configurations.incrementalSync) { _ in
                exportViewModel.saveConfigurations()
                showSyncWarning = exportViewModel.configurations.incrementalSync
            }
            .onChange(of: outputFormat) { newFormat in
                // Auto-disable concatenation when switching to a format that doesn't support it
                let supportsConcat = ExportFormat(rawValue: newFormat)?.supportsConcatenation ?? false
                normalizeOutputPathForContainer()
                if !supportsConcat && exportViewModel.configurations.concatenateOutput {
                    // Fall back to Folder rather than leaving a selection the
                    // new format cannot honour.
                    exportViewModel.configurations.concatenateOutput = false
                    exportViewModel.saveConfigurations()
                }
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
                    // Fade only. A .move transition slides this banner, and
                    // everything below it, every time the option is toggled.
                    .transition(.opacity)
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
            
            Text("Apple Notes Exporter v\(APP_VERSION) - Copyright © 2026 [Konstantin Zaremski](https://konstantin.zarem.ski) - Licensed under the [GNU GPL v3](https://raw.githubusercontent.com/kzaremski/apple-notes-exporter/main/LICENSE)")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.vertical, 5.0)
                .pointerOnHover()
        }
        }
        .frame(width: 500.0, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10.0)
        .onAppear {
            // Initialize sync warning state from persisted config
            showSyncWarning = exportViewModel.configurations.incrementalSync
            // Restore output URL from persisted path, discarding one the
            // current container cannot use.
            normalizeOutputPathForContainer()
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
        .sheet(isPresented: $showMCPSetupView) {
            MCPSetupView(showMCPSetupView: $showMCPSetupView)
        }
        .onChange(of: sharedState.triggerMCPSetup) { trigger in
            if trigger {
                showMCPSetupView = true
                sharedState.triggerMCPSetup = false
            }
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


// MARK: - Step 3 option rows

/// Rows in Step 3 share a fixed height. Without it the row carrying the date
/// picker is taller than the plain checkbox rows, so the gaps between the
/// checkboxes read as uneven even though the stack spacing is uniform.
// Row pitch is height + spacing. The date picker is the tallest thing in any
// row at roughly 22pt, so the height stays above that to avoid clipping it and
// the gap is taken out of the spacing instead. Together these halve the visible
// gap between checkboxes compared with the original 26 + 4.
private let outputOptionRowHeight: CGFloat = 24
private let outputOptionRowSpacing: CGFloat = 0

/// A "?" affordance carrying a tooltip. Uses `.help`, so it appears on hover
/// and is also exposed to VoiceOver rather than being purely decorative.
private struct OptionHelpTip: View {
    let text: String

    @State private var isShowingHelp = false

    var body: some View {
        Button {
            isShowingHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .contentShape(Rectangle())
        }
        .buttonStyle(HelpTipButtonStyle(isActive: isShowingHelp))
        .popover(isPresented: $isShowingHelp, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
        // A Button is a real control, so .help also gives the hover tooltip.
        .help(text)
        .accessibilityLabel(Text(text))
    }
}

/// Press feedback for the help icons. A plain button style leaves them inert,
/// so they look like decoration rather than something you can click.
private struct HelpTipButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(
                configuration.isPressed || isActive ? SwiftUI.Color.accentColor : SwiftUI.Color.secondary
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// One checkbox row: toggle, help tip, and optional trailing controls.
private struct OutputOptionRow<Trailing: View>: View {
    let title: String
    let help: String
    @Binding var isOn: Bool
    var isEnabled: Bool
    let trailing: () -> Trailing

    init(
        title: String,
        help: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.help = help
        self._isOn = isOn
        self.isEnabled = isEnabled
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            Toggle(title, isOn: $isOn)
                .disabled(!isEnabled)
            OptionHelpTip(text: help)
                .opacity(isEnabled ? 1 : 0.4)
            Spacer()
            trailing()
        }
        .frame(height: outputOptionRowHeight)
    }
}

extension OutputOptionRow where Trailing == EmptyView {
    init(title: String, help: String, isOn: Binding<Bool>, isEnabled: Bool = true) {
        self.init(title: title, help: help, isOn: isOn, isEnabled: isEnabled) { EmptyView() }
    }
}


/// Folder vs ZIP selector above the output path. Deliberately mirrors the
/// format tiles in Step 2 (same icon size, padding, corner radius and selected
/// treatment) so the two controls read as the same kind of choice, but with
/// two buttons they each take half the width instead of being narrow.
private struct OutputContainerButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var isEnabled: Bool = true
    var disabledHelp: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(height: 20)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundColor(isSelected ? .white : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? SwiftUI.Color.accentColor : SwiftUI.Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? SwiftUI.Color.clear : SwiftUI.Color.gray.opacity(0.3), lineWidth: 1)
        )
        .help(isEnabled ? "" : (disabledHelp ?? ""))
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.15), value: isEnabled)
    }
}
