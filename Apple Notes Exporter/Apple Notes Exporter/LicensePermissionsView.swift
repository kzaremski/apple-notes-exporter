//
//  LicensePermissionsView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 7/30/25.
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
                        //Text("MIT License")
                        //    .padding(.bottom, 5)
                        //    .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Apple Notes Exporter").font(.title2).multilineTextAlignment(.leading).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Copyright © 2026 Konstantin Zaremski")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(.red)
                        
                        
                        Divider()
                        Text("Third-Party Licenses").font(.title2).multilineTextAlignment(.leading).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 5)

                        Text("This software uses the following open-source libraries:")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 5)

                        VStack(alignment: .leading, spacing: 4) {
                            Link("FullDiskAccess - MIT License", destination: URL(string: "https://github.com/inket/FullDiskAccess/blob/main/LICENSE")!)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .pointerOnHover()

                            Link("swift-html-to-pdf - Apache 2.0 License", destination: URL(string: "https://github.com/coenttb/swift-html-to-pdf/blob/main/LICENCE")!)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .pointerOnHover()

                            Link("SwiftProtobuf - Apache 2.0 License", destination: URL(string: "https://github.com/apple/swift-protobuf/blob/main/LICENSE.txt")!)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .pointerOnHover()
                        }

                        Divider()
                            .padding(.top, 10)

                        Text("Acknowledgements").font(.title2).multilineTextAlignment(.leading).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 5)

                        Text("This project benefited from the groundwork and research done by threeplanetssoftware on Apple Notes protobuf formats and database parsing.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 5)

                        Link("apple_cloud_notes_parser by threeplanetssoftware", destination: URL(string: "https://github.com/threeplanetssoftware/apple_cloud_notes_parser")!)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pointerOnHover()
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
                    UserDefaults.standard.set(true, forKey: "licenseAccepted")
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
