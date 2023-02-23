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
            Text("Step 1 — Select Notes Account")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
            Text("Step 2 — Choose Output Document Format").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            Text("Step 3 — Select Output File Destination").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            Text("Notes and folder structure are preserved in ZIP file for portability.")
            Text("Step 4 — Export!").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            Button {} label: {
                Text("Export").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).padding(.top, -10.0)
            
            Text("Apple Notes Exporter v0.1 - Copyright © 2023 Konstantin Zaremski")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.vertical, 5.0)
        }
        .frame(width: 500.0, height: 200.0)
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

