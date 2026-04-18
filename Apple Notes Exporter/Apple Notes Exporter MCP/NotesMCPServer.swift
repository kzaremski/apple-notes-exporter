//
//  NotesMCPServer.swift
//  Apple Notes Exporter MCP
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

import Foundation
import MCP

// MARK: - MCP Server Entry Point
//
// Server work runs on a detached Task while the main thread stays on
// RunLoop.main.run(), so WebKit callbacks used for PDF rendering are
// delivered on the main run loop.

@main
struct NotesMCPServer {
    static func main() {
        Task { @MainActor in
            do {
                try await runServer()
                exit(0)
            } catch {
                fputs("MCP server error: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    static func runServer() async throws {
        let marketingVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        let server = Server(
            name: "apple-notes-exporter",
            version: "\(marketingVersion).\(buildNumber)",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MCPToolHandlers.allTools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await MCPToolHandlers.dispatch(params: params)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
