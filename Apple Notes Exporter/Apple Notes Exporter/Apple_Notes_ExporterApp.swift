//
//  Apple_Notes_ExporterApp.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI

extension Scene {
    func windowResizabilityContentSize() -> some Scene {
        if #available(macOS 13.0, *) {
            return windowResizability(.contentSize)
        } else {
            return self
        }
    }
}

@main
struct Apple_Notes_ExporterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }.windowResizabilityContentSize()
    }
}
