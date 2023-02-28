//
//  ContentView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Step 1: Select Notes Account")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
            Menu {
                Text("Testing 0")
                Text("Testing 1")
                Text("Testing 2")
                Text("Testing 3")
            } label: {
                Text("iCloud Notes: konstantin.zaremski@gmail.com")
            }
            
            Text("Step 2: Choose Output Document Format").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            ControlGroup {
                Button {} label: {
                    Image(systemName: "doc.text")
                    Text("HTML")
                }
                Button {} label: {
                    Image(systemName: "doc.append")
                    Text("PDF")
                }
            }
            
            Text("Step 3: Select Output File Destination").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            HStack() {
                Image(systemName: "info.circle")
                Text("Notes and folder structure are preserved in ZIP file for portability.")
            }
            HStack() {
                Image(systemName: "folder")
                Text("Select output file location.").frame(maxWidth: .infinity, alignment: .leading)
                Button {} label: {
                    Text("Browse")
                }.padding(.top, 7.0)
            }
            
            Text("Step 4: Export!").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            Button {} label: {
                Text("Export").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
            
            Text("Apple Notes Exporter v0.1 - Copyright © 2023 Konstantin Zaremski - Licensed under the [MIT License](https://kzaremski)")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.vertical, 5.0)
        }
        .frame(width: 500.0, height: 320.0)
        .padding(10.0)
    }
    
    func greeting() {
        print("Hello, World!")
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            
    }
}

