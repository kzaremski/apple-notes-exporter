//
//  ExportProgressView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/28/23.
//

import SwiftUI

struct ExportProgressView: View {    
    var body: some View {
        VStack {
            ProgressView {
                Text("Exporting")
                .bold()
            }
        }.frame(width: 160.0, height: 120.0).interactiveDismissDisabled()
    }
}

struct ExportProgressView_Previews: PreviewProvider {
    static var previews: some View {
        ExportProgressView()
    }
}
