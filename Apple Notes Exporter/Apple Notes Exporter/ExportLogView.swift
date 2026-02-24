//
//  ExportLogView.swift
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
import AppKit

struct ExportLogView: View {
    @EnvironmentObject var exportViewModel: ExportViewModel
    var onClose: () -> Void

    @State private var logFilter: LogFilter = .all

    enum LogFilter: String, CaseIterable {
        case all = "Show All"
        case errorsOnly = "Show Errors Only"
    }

    var filteredLogEntries: [String] {
        switch logFilter {
        case .all:
            return exportViewModel.exportLog
        case .errorsOnly:
            return exportViewModel.exportLog.filter { $0.contains("✗") }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export Log")
                .font(.title)

            // Use NSTextView for selectable text with color support
            SelectableLogView(logEntries: filteredLogEntries)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(SwiftUI.Color.gray.opacity(0.3), lineWidth: 1)
                )

            // Filter controls and close button below log
            HStack {
                // Radio buttons horizontally on the left
                HStack(spacing: 15) {
                    ForEach(LogFilter.allCases, id: \.self) { filter in
                        Button(action: {
                            logFilter = filter
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: logFilter == filter ? "circle.inset.filled" : "circle")
                                    .font(.system(size: 12))
                                Text(filter.rawValue)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                Button {
                    onClose()
                } label: {
                    Text("Close")
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            // Handle Esc key to close window
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Esc key
                    onClose()
                    return nil
                }
                return event
            }
        }
    }
}

// MARK: - Selectable Log View

struct SelectableLogView: NSViewRepresentable {
    let logEntries: [String]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        // Configure text view
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        // Configure scroll view
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Create attributed string with colors
        let attributedString = NSMutableAttributedString()

        for entry in logEntries {
            var color: NSColor = .labelColor

            // Determine color based on entry content (use adaptive colors for light/dark mode)
            if entry.contains("✓") {
                // Success: darker green for light mode, brighter green for dark mode
                color = NSColor.systemGreen
            } else if entry.contains("✗") {
                // Error: darker red for light mode, brighter red for dark mode
                color = NSColor.systemRed
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            ]

            let line = NSAttributedString(string: entry + "\n", attributes: attributes)
            attributedString.append(line)
        }

        // Update text view
        textView.textStorage?.setAttributedString(attributedString)

        // Auto-scroll to bottom
        textView.scrollToEndOfDocument(nil)
    }
}
