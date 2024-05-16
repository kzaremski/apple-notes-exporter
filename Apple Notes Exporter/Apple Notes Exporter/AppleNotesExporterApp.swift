//
//  Apple_Notes_ExporterApp.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI

let APP_VERSION = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
let OUTPUT_FORMATS: [String] = [
    "PDF",
    "HTML",
    "TEX",
    "MD",
    "RTF",
    "TXT",
]
let OUTPUT_TYPES: [String] = [
    "Folder",
    "TAR Archive",
    "ZIP Archive",
]

extension Scene {
    func windowResizabilityContentSize() -> some Scene {
        if #available(macOS 13.0, *) {
            return windowResizability(.contentSize)
        } else {
            return self
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

class AppleNotesExporterData {
    static var root: [ICItem] = []
}

@main
struct Apple_Notes_ExporterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup(id: "main") {
            AppleNotesExporterView().onAppear {
                NSWindow.allowsAutomaticWindowTabbing = false
            }
            
        }
        .commands {
            CommandGroup(replacing: .newItem, addition: { })
        }
        .windowResizabilityContentSize()
    }
}
