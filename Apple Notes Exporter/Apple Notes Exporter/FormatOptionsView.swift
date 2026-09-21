//
//  FormatOptionsView.swift
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

import SwiftUI

struct FormatOptionsView: View {
    @EnvironmentObject var exportViewModel: ExportViewModel
    @Binding var showOptionsView: Bool
    let format: ExportFormat

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("\(format.displayName) Export Options")
                .font(.title)
                .padding(.bottom, 5)

            // Only wrap non-LaTeX views in ScrollView
            if format == .tex {
                LaTeXOptionsView(config: $exportViewModel.configurations.latex)
                    .padding(.trailing, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch format {
                        case .html:
                            HTMLOptionsView(config: $exportViewModel.configurations.html)
                        case .pdf:
                            PDFOptionsView(config: $exportViewModel.configurations.pdf)
                        case .pdfVector:
                            PDFVectorOptionsView(config: $exportViewModel.configurations.pdfVector)
                        case .rtf:
                            RTFOptionsView(config: $exportViewModel.configurations.rtf)
                        default:
                            Text("No configuration options available for this format.")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                }
            }

            // Buttons
            HStack {
                Spacer()
                Button {
                    // Reload configurations to discard changes
                    exportViewModel.configurations = ExportConfigurations.load()
                    showOptionsView = false
                } label: {
                    Image(systemName: "xmark")
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    exportViewModel.saveConfigurations()
                    showOptionsView = false
                } label: {
                    Image(systemName: "checkmark")
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
            .padding(.trailing, 20)
        }
        .padding(.vertical, 20)
        .padding(.leading, 20)
        .padding(.trailing, 0)
        .frame(width: 600)
        .frame(maxHeight: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape key
                    // Reload configurations to discard changes
                    exportViewModel.configurations = ExportConfigurations.load()
                    showOptionsView = false
                    return nil
                }
                return event
            }
        }
    }
}

// MARK: - HTML Options

struct HTMLOptionsView: View {
    @Binding var config: HTMLConfiguration
    var showFolderIndexes: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Font Settings")
                .font(.headline)

            HStack {
                Text("Font Family:")
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $config.fontFamily) {
                    ForEach(HTMLConfiguration.FontFamily.allCases, id: \.self) { family in
                        Text(family.rawValue).tag(family)
                    }
                }
                .frame(width: 150)
            }

            HStack {
                Text("Font Size:")
                    .frame(width: 120, alignment: .leading)
                TextField("", text: Binding(
                    get: { String(format: "%.0f", config.fontSizePoints) },
                    set: { config.fontSizePoints = Double($0) ?? config.fontSizePoints }
                ))
                    .frame(width: 60)
                Stepper("", value: $config.fontSizePoints, in: 8...72, step: 1)
                Text("pt")
            }

            Divider()

            Text("Layout")
                .font(.headline)

            HStack {
                Text("Margin:")
                    .frame(width: 120, alignment: .leading)
                TextField("", text: Binding(
                    get: { String(format: "%.0f", config.marginSize) },
                    set: { config.marginSize = Double($0) ?? config.marginSize }
                ))
                    .frame(width: 60)
                Picker("", selection: $config.marginUnit) {
                    ForEach(HTMLConfiguration.MarginUnit.allCases, id: \.self) { unit in
                        Text(unit.displayName).tag(unit)
                    }
                }
                .frame(width: 80)
            }

            if showFolderIndexes {
                Divider()

                Text("Folder Indexes")
                    .font(.headline)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .padding(.top, 2)
                    Text("Adds an index.html in each folder listing the notes and subfolders, so you can browse the export in a web browser like the Notes tree.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Write index.html in each folder", isOn: $config.writeFolderIndexes)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Text("Image Attachments")
                .font(.headline)

            Toggle("Embed images inline (base64)", isOn: $config.embedImagesInline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if config.embedImagesInline {
                Toggle("Also link to image files", isOn: $config.linkEmbeddedImages)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
            }
        }
    }
}

// MARK: - PDF Options

struct PDFOptionsView: View {
    @Binding var config: PDFConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HTMLOptionsView(config: $config.htmlConfiguration, showFolderIndexes: false)

            Divider()

            Text("PDF Settings")
                .font(.headline)

            HStack {
                Text("Page Size:")
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $config.pageSize) {
                    ForEach(PDFConfiguration.PageSize.allCases, id: \.self) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .frame(width: 150)
            }
        }
    }
}

// MARK: - Vector PDF Options

struct PDFVectorOptionsView: View {
    @Binding var config: PDFVectorConfiguration

    private let labelWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Page")
                .font(.headline)

            HStack {
                Text("Page Size:")
                    .frame(width: labelWidth, alignment: .leading)
                Picker("", selection: $config.pageSize) {
                    ForEach(PDFConfiguration.PageSize.allCases, id: \.self) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .frame(width: 150)
            }

            HStack {
                Text("Orientation:")
                    .frame(width: labelWidth, alignment: .leading)
                Picker("", selection: $config.orientation) {
                    ForEach(PDFVectorConfiguration.Orientation.allCases, id: \.self) { orientation in
                        Text(orientation.rawValue).tag(orientation)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            HStack {
                Text("Margin:")
                    .frame(width: labelWidth, alignment: .leading)
                TextField("", text: Binding(
                    get: { String(format: "%.0f", config.margin) },
                    set: { config.margin = Double($0) ?? config.margin }
                ))
                    .frame(width: 60)
                Stepper("", value: $config.margin, in: 0...144, step: 4)
                Text("pt")
                    .foregroundColor(.secondary)
            }

            Divider()

            Text("Split Page")
                .font(.headline)

            HStack {
                Text("Split:")
                    .frame(width: labelWidth, alignment: .leading)
                Picker("", selection: $config.splitMode) {
                    ForEach(PDFVectorConfiguration.SplitMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            Text(config.splitMode.blurb)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, labelWidth)

            // iPad pickers only mean anything for the iPad split, so they
            // stay visible but inert otherwise rather than making the sheet
            // jump around as the mode changes.
            HStack {
                Text("iPad Size:")
                    .frame(width: labelWidth, alignment: .leading)
                Picker("", selection: $config.iPadModel) {
                    ForEach(PDFVectorConfiguration.IPadModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .disabled(config.splitMode != .iPadScreen)

            HStack {
                Text("iPad Orientation:")
                    .frame(width: labelWidth, alignment: .leading)
                Picker("", selection: $config.iPadOrientation) {
                    ForEach(PDFVectorConfiguration.Orientation.allCases, id: \.self) { orientation in
                        Text(orientation.rawValue).tag(orientation)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .disabled(config.splitMode != .iPadScreen)

            Divider()

            Text("Handwriting")
                .font(.headline)

            Toggle(isOn: $config.maximizeContent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Maximize writing size")
                    Text("Trim the empty canvas and scale the writing up to fill the page.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Toggle(isOn: $config.avoidSplittingStrokes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Never split a stroke across pages")
                    Text("Break between strokes so a line of writing is not cut in half.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Maximum Zoom:")
                    .frame(width: labelWidth, alignment: .leading)
                TextField("", text: Binding(
                    get: { String(format: "%.1f", config.maximumScale) },
                    set: { config.maximumScale = Double($0) ?? config.maximumScale }
                ))
                    .frame(width: 60)
                Stepper("", value: $config.maximumScale, in: 1...12, step: 0.5)
                Text("×")
                    .foregroundColor(.secondary)
            }
            .disabled(!config.maximizeContent)

            Text("Handwriting is redrawn as vector paths, so it stays sharp at any zoom or print size. Notes without Apple Pencil handwriting export as a regular PDF.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - LaTeX Options

struct LaTeXOptionsView: View {
    @Binding var config: LaTeXConfiguration
    @State private var showPlaceholders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Template")
                    .font(.headline)

                Spacer()

                Button {
                    showPlaceholders.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                    Text(showPlaceholders ? "Hide Placeholders" : "Show Placeholders")
                }

                Button {
                    config.template = LaTeXConfiguration.defaultTemplate
                } label: {
                    Image(systemName: "arrow.uturn.left")
                    Text("Reset to Default")
                }
            }

            if showPlaceholders {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Available Placeholders:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(LaTeXConfiguration.placeholders, id: \.self) { placeholder in
                            SelectableText(text: placeholder)
                        }
                    }
                }
                .padding()
                .background(SwiftUI.Color(NSColor.separatorColor).opacity(0.5))
                .cornerRadius(6)
            }

            TextEditor(text: $config.template)
                .font(.system(.body, design: .monospaced))
                .frame(maxHeight: .infinity)
                .border(SwiftUI.Color(NSColor.separatorColor), width: 1)
        }
    }
}

// MARK: - Selectable Text Helper

struct SelectableText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.isBordered = false
        textField.isEditable = false
        textField.isSelectable = true
        textField.backgroundColor = .clear
        textField.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textField.stringValue = text
        textField.lineBreakMode = .byTruncatingTail
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
    }
}

// MARK: - RTF Options

struct RTFOptionsView: View {
    @Binding var config: RTFConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Font Settings")
                .font(.headline)

            HStack {
                Text("Font Family:")
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $config.fontFamily) {
                    ForEach(RTFConfiguration.FontFamily.allCases, id: \.self) { family in
                        Text(family.rawValue).tag(family)
                    }
                }
                .frame(width: 150)
            }

            HStack {
                Text("Font Size:")
                    .frame(width: 120, alignment: .leading)
                TextField("", text: Binding(
                    get: { String(format: "%.0f", config.fontSizePoints) },
                    set: { config.fontSizePoints = Double($0) ?? config.fontSizePoints }
                ))
                    .frame(width: 60)
                Stepper("", value: $config.fontSizePoints, in: 8...72, step: 1)
                Text("pt")
            }
        }
    }
}
