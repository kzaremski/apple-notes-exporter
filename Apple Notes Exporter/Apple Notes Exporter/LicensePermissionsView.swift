//
//  LicensePermissionsView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 7/30/25.
//

import SwiftUI
import FullDiskAccess
import AppKit

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
        print("Checking for Full Disk Access permission...")
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
                        Text("Copyright © 2025 Konstantin Zaremski")
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
                        
                        
                        Text("Third-Party Licenses").font(.title2).multilineTextAlignment(.leading).lineLimit(1)
                            .padding(.bottom, 5)
                            .padding(.top, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Divider()
                        Text("FullDiskAccess (https://github.com/inket/FullDiskAccess)").font(.title3).multilineTextAlignment(.leading).lineLimit(1)
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Copyright © 2024 Mahdi Bchatnia")
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
                        
                        Divider()
                        Text("HtmlToPdf (https://github.com/coenttb/swift-html-to-pdf)").font(.title3).multilineTextAlignment(.leading).lineLimit(1)
                            .padding([.top, .bottom], 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Apache License 2.0").multilineTextAlignment(.leading).lineLimit(1)
                            .frame(maxWidth: .infinity)
                        Text("Version 2.0, January 2004")
                            .frame(maxWidth: .infinity)
                        Text("http://www.apache.org/licenses/")
                            .frame(maxWidth: .infinity)


                        Text("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION")
                            .font(.headline)
                            .padding([.top, .bottom], 5)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("1. Definitions.")
                            .font(.subheadline)
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\"License\" shall mean the terms and conditions for use, reproduction, and distribution as defined by Sections 1 through 9 of this document.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\"Licensor\" shall mean the copyright owner or entity authorized by the copyright owner that is granting the License.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\"Legal Entity\" shall mean the union of the acting entity and all other entities that control, are controlled by, or are under common control with that entity. For the purposes of this definition, \"control\" means (i) the power, direct or indirect, to cause the direction or management of such entity, whether by contract or otherwise, or (ii) ownership of fifty percent (50%) or more of the outstanding shares, or (iii) beneficial ownership of such entity.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\"You\" (or \"Your\") shall mean an individual or Legal Entity exercising permissions granted by this License.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\"Source\" form shall mean the preferred form for making modifications, including but not limited to software source code, documentation source, and configuration files.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\"Object\" form shall mean any form resulting from mechanical transformation or translation of a Source form, including but not limited to compiled object code, generated documentation, and conversions to other media types.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\"Work\" shall mean the work of authorship, whether in Source or Object form, made available under the License, as indicated by a copyright notice that is included in or attached to the work (an example is provided in the Appendix below).")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\"Derivative Works\" shall mean any work, whether in Source or Object form, that is based on (or derived from) the Work and for which the editorial revisions, annotations, elaborations, or other modifications represent, as a whole, an original work of authorship. For the purposes of this License, Derivative Works shall not include works that remain separable from, or merely link (or bind by name) to the interfaces of, the Work and Derivative Works thereof.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\"Contribution\" shall mean any work of authorship, including the original version of the Work and any modifications or additions to that Work or Derivative Works thereof, that is intentionally submitted to Licensor for inclusion in the Work by the copyright owner or by an individual or Legal Entity authorized to submit on behalf of the copyright owner. For the purposes of this definition, \"submitted\" means any form of electronic, verbal, or written communication sent to the Licensor or its representatives, including but not limited to communication on electronic mailing lists, source code control systems, and issue tracking systems that are managed by, or on behalf of, the Licensor for the purpose of discussing and improving the Work, but excluding communication that is conspicuously marked or otherwise designated in writing by the copyright owner as \"Not a Contribution.\"")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\"Contributor\" shall mean Licensor and any individual or Legal Entity on behalf of whom a Contribution has been received by Licensor and subsequently incorporated within the Work.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("2. Grant of Copyright License.")
                            .font(.subheadline)
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Subject to the terms and conditions of this License, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable copyright license to reproduce, prepare Derivative Works of, publicly display, publicly perform, sublicense, and distribute the Work and such Derivative Works in Source or Object form.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("3. Grant of Patent License.")
                            .font(.subheadline)
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Subject to the terms and conditions of this License, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable (except as stated in this section) patent license to make, have made, use, offer to sell, sell, import, and otherwise transfer the Work, where such license applies only to those patent claims licensable by such Contributor that are necessarily infringed by their Contribution(s) alone or by combination of their Contribution(s) with the Work to which such Contribution(s) was submitted. If You institute patent litigation against any entity (including a cross-claim or counterclaim in a lawsuit) alleging that the Work or a Contribution incorporated within the Work constitutes direct or contributory patent infringement, then any patent licenses granted to You under this License for that Work shall terminate as of the date such litigation is filed.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("4. Redistribution.")
                            .font(.subheadline)
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("You may reproduce and distribute copies of the Work or Derivative Works thereof in any medium, with or without modifications, and in Source or Object form, provided that You meet the following conditions:")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("(a) You must give any other recipients of the Work or Derivative Works a copy of this License; and")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("(b) You must cause any modified files to carry prominent notices stating that You changed the files; and")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("(c) You must retain, in the Source form of any Derivative Works that You distribute, all copyright, patent, trademark, and attribution notices from the Source form of the Work, excluding those notices that do not pertain to any part of the Derivative Works; and")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("(d) If the Work includes a \"NOTICE\" text file as part of its distribution, then any Derivative Works that You distribute must include a readable copy of the attribution notices contained within such NOTICE file, excluding those notices that do not pertain to any part of the Derivative Works, in at least one of the following places: within a NOTICE text file distributed as part of the Derivative Works; within the Source form or documentation, if provided along with the Derivative Works; or, within a display generated by the Derivative Works, if and wherever such third-party notices normally appear. The contents of the NOTICE file are for informational purposes only and do not modify the License. You may add Your own attribution notices within Derivative Works that You distribute, alongside or as an addendum to the NOTICE text from the Work, provided that such additional attribution notices cannot be construed as modifying the License.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("You may add Your own copyright statement to Your modifications and may provide additional or different license terms and conditions for use, reproduction, or distribution of Your modifications, or for any such Derivative Works as a whole, provided Your use, reproduction, and distribution of the Work otherwise complies with the conditions stated in this License.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("5. Submission of Contributions.")
                            .font(.subheadline)
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Unless You explicitly state otherwise, any Contribution intentionally submitted for inclusion in the Work by You to the Licensor shall be under the terms and conditions of this License, without any additional terms or conditions. Notwithstanding the above, nothing herein shall supersede or modify the terms of any separate license agreement you may have executed with Licensor regarding such Contributions.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("6. Trademarks.")
                            .font(.subheadline)
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("This License does not grant permission to use the trade names, trademarks, service marks, or product names of the Licensor, except as required for reasonable and customary use in describing the origin of the Work and reproducing the content of the NOTICE file.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("7. Disclaimer of Warranty.")
                            .font(.subheadline)
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Unless required by applicable law or agreed to in writing, Licensor provides the Work (and each Contributor provides its Contributions) on an \"AS IS\" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied, including, without limitation, any warranties or conditions of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A PARTICULAR PURPOSE. You are solely responsible for determining the appropriateness of using or redistributing the Work and assume any risks associated with Your exercise of permissions under this License.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("8. Limitation of Liability.")
                            .font(.subheadline)
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("In no event and under no legal theory, whether in tort (including negligence), contract, or otherwise, unless required by applicable law (such as deliberate and grossly negligent acts) or agreed to in writing, shall any Contributor be liable to You for damages, including any direct, indirect, special, incidental, or consequential damages of any character arising as a result of this License or out of the use or inability to use the Work (including but not limited to damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses), even if such Contributor has been advised of the possibility of such damages.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("9. Accepting Warranty or Additional Liability.")
                            .font(.subheadline)
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("While redistributing the Work or Derivative Works thereof, You may choose to offer, and charge a fee for, acceptance of support, warranty, indemnity, or other liability obligations and/or rights consistent with this License. However, in accepting such obligations, You may act only on Your own behalf and on Your sole responsibility, not on behalf of any other Contributor, and only if You agree to indemnify, defend, and hold each Contributor harmless for any liability incurred by, or claims asserted against, such Contributor by reason of your accepting any such warranty or additional liability.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Runtime Library Exception to the Apache 2.0 License:")
                            .font(.headline)
                            .padding([.top, .bottom], 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("As an exception, if you use this Software to compile your source code and portions of this Software are embedded into the binary product as a result, you may redistribute such product without providing attribution as would otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.")
                            .padding(.bottom, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                    }
                    .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .leading)
            .border(Color.gray, width: 1)
            .padding([.top, .bottom], 5)
            
            Toggle("I hereby agree to the above license terms.", isOn: $agreedToLicense)
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
            // Start the load of the Apple Notes Database
            sharedState.reload()
        }
    }
}
