//
//  LicensePermissionsView.swift
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
import FullDiskAccess
import AppKit
import OSLog

struct LicensePermissionsView: View {
    @ObservedObject var sharedState: AppleNotesExporterState
    @Binding var showLicensePermissionsView: Bool
    
    @State private var agreedToLicense = false
    @State private var fullDiskPermissionGranted = false
    @State private var checkingFullDiskPermission = false
    
    @State private var permissionCheckTimer: Timer?
    
    func requestFullDiskAccess() {
        DispatchQueue.main.async {
            FullDiskAccess.promptIfNotGranted(
                title: "Enable Full Disk Access for\nApple Notes Exporter",
                message: "Apple Notes Exporter requires Full Disk Access to access your Apple Notes database file.",
                settingsButtonTitle: "Open Settings",
                skipButtonTitle: "Later",
                canBeSuppressed: false,
                icon: nil
            )
        }
    }
    
    func hasFullDiskAccess() -> Bool {
        let path = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes/"
        return FileManager.default.isReadableFile(atPath: path)
        //return FullDiskAccess.isGranted
    }
    
    func checkPermission() {
        Logger.noteQuery.debug("Checking for Full Disk Access permission...")
        checkingFullDiskPermission = true
        let startTime = Date()
        
        let granted = hasFullDiskAccess()
        
        // Calculate how long to wait to ensure at least 1 second of loading
        let elapsed = Date().timeIntervalSince(startTime)
        let minimumDelay = max(0, 1.0 - elapsed)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumDelay) {
            self.fullDiskPermissionGranted = granted
            self.checkingFullDiskPermission = false
            
            if granted {
                self.permissionCheckTimer?.invalidate()
                self.permissionCheckTimer = nil
            }
        }
    }

    func startPermissionCheckLoop() {
        permissionCheckTimer?.invalidate() // avoid duplicates
        
        // Precheck if the app is launched already having the permission
        let granted = hasFullDiskAccess()
        if granted {
            // If the app is opened already having the permissions, do not start the loop to check
            self.fullDiskPermissionGranted = true
            self.checkingFullDiskPermission = false
            return
        }
        
        // Request and check immediately
        self.requestFullDiskAccess()
        self.checkPermission()
        
        // Continue checking every 3 seconds if not granted
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            // Only continue checking if permission is not granted
            if !self.fullDiskPermissionGranted {
                self.checkPermission()
            } else {
                self.permissionCheckTimer?.invalidate()
                self.permissionCheckTimer = nil
            }
        }
        
        permissionCheckTimer = timer
    }
    
    var body: some View {
        VStack {
            VStack {
                ScrollView {
                    VStack{
                        Text("GNU General Public License v3.0").font(.title2).multilineTextAlignment(.leading).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Apple Notes Exporter")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Copyright © 2026 Konstantin Zaremski")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(.red)
                        Text("You should have received a copy of the GNU General Public License along with this program. If not, see https://www.gnu.org/licenses/.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        
                        Divider()
                        Text("Third-Party Licenses").font(.title2).multilineTextAlignment(.leading).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 5)

                        Text("This software uses the following open-source libraries. Full license texts are bundled with the application.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 5)

                        VStack(alignment: .leading, spacing: 8) {
                            LicenseEntryView(
                                name: "FullDiskAccess",
                                licenseType: "MIT License",
                                copyright: "Copyright (c) 2024 Mahdi Bchatnia",
                                url: "https://github.com/inket/FullDiskAccess",
                                filename: "FullDiskAccess-LICENSE"
                            )
                            LicenseEntryView(
                                name: "swift-html-to-pdf",
                                licenseType: "Apache 2.0 License (with Runtime Library Exception)",
                                copyright: "Copyright coenttb",
                                url: "https://github.com/coenttb/swift-html-to-pdf",
                                filename: "swift-html-to-pdf-LICENSE"
                            )
                            LicenseEntryView(
                                name: "SwiftProtobuf",
                                licenseType: "Apache 2.0 License (with Runtime Library Exception)",
                                copyright: "Copyright 2008 Google Inc.",
                                url: "https://github.com/apple/swift-protobuf",
                                filename: "SwiftProtobuf-LICENSE"
                            )
                            LicenseEntryView(
                                name: "combine-schedulers",
                                licenseType: "MIT License",
                                copyright: "Copyright (c) 2020 Point-Free, Inc.",
                                url: "https://github.com/pointfreeco/combine-schedulers",
                                filename: "combine-schedulers-LICENSE"
                            )
                            LicenseEntryView(
                                name: "swift-clocks",
                                licenseType: "MIT License",
                                copyright: "Copyright (c) 2022 Point-Free",
                                url: "https://github.com/pointfreeco/swift-clocks",
                                filename: "swift-clocks-LICENSE"
                            )
                            LicenseEntryView(
                                name: "swift-concurrency-extras",
                                licenseType: "MIT License",
                                copyright: "Copyright (c) 2023 Point-Free",
                                url: "https://github.com/pointfreeco/swift-concurrency-extras",
                                filename: "swift-concurrency-extras-LICENSE"
                            )
                            LicenseEntryView(
                                name: "swift-dependencies",
                                licenseType: "MIT License",
                                copyright: "Copyright (c) 2022 Point-Free, Inc.",
                                url: "https://github.com/pointfreeco/swift-dependencies",
                                filename: "swift-dependencies-LICENSE"
                            )
                            LicenseEntryView(
                                name: "swift-syntax",
                                licenseType: "Apache 2.0 License (with Runtime Library Exception)",
                                copyright: "Copyright (c) 2014-2023 Apple Inc. and the Swift project authors",
                                url: "https://github.com/swiftlang/swift-syntax",
                                filename: "swift-syntax-LICENSE"
                            )
                            LicenseEntryView(
                                name: "xctest-dynamic-overlay",
                                licenseType: "MIT License",
                                copyright: "Copyright (c) 2021 Point-Free, Inc.",
                                url: "https://github.com/pointfreeco/xctest-dynamic-overlay",
                                filename: "xctest-dynamic-overlay-LICENSE"
                            )
                        }

                        Divider()
                            .padding(.top, 10)

                        Text("Acknowledgements").font(.title2).multilineTextAlignment(.leading).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 5)

                        Text("This project's protobuf schema for Apple Notes is based on the groundwork and research done by threeplanetssoftware.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 5)

                        VStack(alignment: .leading, spacing: 8) {
                            LicenseEntryView(
                                name: "apple_cloud_notes_parser",
                                licenseType: "MIT License",
                                copyright: "Copyright (c) 2019 Three Planets Software",
                                url: "https://github.com/threeplanetssoftware/apple_cloud_notes_parser",
                                filename: "threeplanetssoftware-LICENSE"
                            )
                        }
                    }
                    .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .leading)
            .border(SwiftUI.Color.gray, width: 1)
            .padding([.top, .bottom], 5)
            
            Toggle("By using Apple Notes Exporter I hereby agree to the above license terms.", isOn: $agreedToLicense)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.bottom], 5)
            
            HStack {
                Image(systemName: "info.circle")
                Text("Apple Notes Exporter needs to be granted Full Disk Access.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if fullDiskPermissionGranted {
                    HStack{
                        Image(systemName: "checkmark.circle.fill")
                        Text("Granted")
                    }.foregroundColor(.green)
                } else {
                    if checkingFullDiskPermission {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .padding([.top, .bottom], -15)
                            .padding([.trailing], -10)
                            .scaleEffect(0.5)
                    } else {
                        Image(systemName: "x.circle.fill")
                            .foregroundColor(.red)
                    }
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.bottom], 10)
            
            HStack {
                Button {
                    exit(0)
                } label: {
                    Text("Cancel")
                }.frame(maxWidth: .infinity, alignment: .trailing)
                
                Button {
                    // Mark license as accepted and persist to UserDefaults
                    sharedState.licenseAccepted = true
                    UserDefaults.standard.set(true, forKey: "licenseAcceptedGPLv3")
                    // Start loading immediately before dismissing
                    sharedState.reload()
                    showLicensePermissionsView = false
                } label: {
                    Text("Continue")
                }
                .disabled(!agreedToLicense || !fullDiskPermissionGranted)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            startPermissionCheckLoop()
        }
        .onDisappear {
            permissionCheckTimer?.invalidate()
        }
    }
}

/// A reusable view for displaying a third-party license entry with expandable full text
struct LicenseEntryView: View {
    let name: String
    let licenseType: String
    let copyright: String
    let url: String
    let filename: String

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: { expanded.toggle() }) {
                HStack {
                    Text(expanded ? "▼" : "▶").font(.caption).frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(name) — \(licenseType)").font(.body).bold()
                        Text(copyright).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerOnHover()

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Link("View on GitHub", destination: URL(string: url)!)
                        .font(.caption)
                        .pointerOnHover()

                    if let path = Bundle.main.path(forResource: filename, ofType: "txt", inDirectory: "Licenses"),
                       let text = try? String(contentsOfFile: path, encoding: .utf8) {
                        Text(text)
                            .font(.system(size: 9, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                            .cornerRadius(4)
                    } else {
                        Text("License text bundled as \(filename).txt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.leading, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
