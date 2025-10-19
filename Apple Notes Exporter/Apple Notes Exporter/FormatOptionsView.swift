//
//  FormatOptionsView.swift
//  Apple Notes Exporter
//
//  Configuration view for export format options
//

import SwiftUI

struct FormatOptionsView: View {
    @EnvironmentObject var exportViewModel: ExportViewModel
    @Binding var showOptionsView: Bool
    let format: ExportFormat

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("\(format.rawValue) Export Options")
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
                        case .rtf:
                            RTFOptionsView(config: $exportViewModel.configurations.rtf)
                        case .markdown, .txt:
                            Text("No configuration options available for this format.")
                                .foregroundColor(.secondary)
                        default:
                            EmptyView()
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
        }
    }
}

// MARK: - PDF Options

struct PDFOptionsView: View {
    @Binding var config: PDFConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HTMLOptionsView(config: $config.htmlConfiguration)

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
