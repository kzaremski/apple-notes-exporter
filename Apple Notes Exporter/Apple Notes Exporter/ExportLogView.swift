//
//  ExportLogView.swift
//  Apple Notes Exporter
//
//  Displays detailed export log in a separate window
//

import SwiftUI
import AppKit

struct ExportLogView: View {
    @EnvironmentObject var exportViewModel: ExportViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export Log")
                .font(.title)

            // Use NSTextView for selectable text with color support
            SelectableLogView(logEntries: exportViewModel.exportLog)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(SwiftUI.Color.gray.opacity(0.3), lineWidth: 1)
                )

            // Close button
            HStack {
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
        textView.textColor = NSColor.white
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
            var color: NSColor = .white

            // Determine color based on entry content
            if entry.contains("✓") {
                color = .green
            } else if entry.contains("✗") {
                color = .red
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
