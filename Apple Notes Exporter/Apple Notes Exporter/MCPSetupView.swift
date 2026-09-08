//
//  MCPSetupView.swift
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

// MARK: - MCP Server Location

/// Where the bundled MCP server lives and what a client needs to launch it.
///
/// The server is a stdio process that an AI client spawns; it is not something
/// the app runs or exports to. All the app can usefully do is tell the user
/// where the binary is and hand them a config block to paste.
enum MCPServer {
    static let executableName = "notes-export-mcp"
    /// Key the server is listed under in a client's config.
    static let serverKey = "apple-notes"

    /// Absolute path to the embedded server, or nil if it is missing from the
    /// bundle (an incomplete build, or the app run from a stripped copy).
    static var executableURL: URL? {
        guard let url = Bundle.main.sharedSupportURL?
            .appendingPathComponent(executableName) else { return nil }
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The block a user pastes into an MCP client's configuration file.
    static func configurationJSON(for url: URL) -> String {
        // Built by hand rather than through JSONEncoder so the output stays in
        // this exact shape and key order, which is what the user is matching
        // against the surrounding file they are pasting into.
        let escapedPath = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "mcpServers": {
            "\(serverKey)": {
              "command": "\(escapedPath)"
            }
          }
        }
        """
    }

    /// Copy the configuration to the clipboard. Returns false when the server
    /// could not be found, so callers can say so rather than silently no-op.
    @discardableResult
    static func copyConfigurationToClipboard() -> Bool {
        guard let url = executableURL else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(configurationJSON(for: url), forType: .string)
        return true
    }

    /// Reveal the server binary selected in Finder.
    @discardableResult
    static func revealInFinder() -> Bool {
        guard let url = executableURL else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}

// MARK: - Setup View

struct MCPSetupView: View {
    @Binding var showMCPSetupView: Bool

    @State private var copied = false

    private var serverURL: URL? { MCPServer.executableURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to an AI Assistant")
                .font(.title)
                .lineLimit(1)

            Text("Apple Notes Exporter includes a Model Context Protocol server, so an assistant such as Claude Desktop can list and export your notes directly. The assistant starts the server itself; there is nothing to leave running here.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let serverURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server").font(.headline)
                    HStack(spacing: 8) {
                        Text(serverURL.path)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Reveal in Finder") { MCPServer.revealInFinder() }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Configuration").font(.headline)
                        Spacer()
                        Button(copied ? "Copied" : "Copy Config") {
                            MCPServer.copyConfigurationToClipboard()
                            copied = true
                        }
                        .disabled(copied)
                    }
                    ScrollView {
                        Text(MCPServer.configurationJSON(for: serverURL))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 120)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(SwiftUI.Color.gray.opacity(0.12))
                    )
                    Text("Merge this into your assistant's MCP configuration file. In Claude Desktop that is Settings, Developer, Edit Config.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label(
                    "The MCP server is missing from this copy of the app. Reinstall Apple Notes Exporter to restore it.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").foregroundColor(.secondary)
                // The server reads the same protected database the app does, and
                // inherits the permissions of whatever launched it.
                Text("The server needs Full Disk Access to read your notes. Grant it to the assistant that launches the server, not just to this app.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Done") { showMCPSetupView = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }
}
