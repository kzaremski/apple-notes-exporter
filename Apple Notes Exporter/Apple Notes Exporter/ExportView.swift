//
//  ExportView.swift
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
import OSLog

struct ExportView: View {
    @ObservedObject var sharedState: AppleNotesExporterState
    @EnvironmentObject var exportViewModel: ExportViewModel

    var body: some View {
        VStack(spacing: 10) {
            // Export status
            VStack(alignment: .leading, spacing: 3) {
                Text("Exporting Notes")
                    .font(.title)

                if case .exporting(let progress) = exportViewModel.exportState {
                    ProgressView(value: progress.percentage) {
                        Text(progress.message)
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .progressViewStyle(LinearProgressViewStyle())
                } else if case .completed(let stats) = exportViewModel.exportState {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Export completed successfully!")
                                .font(.headline)
                        }

                        // Show statistics
                        if stats.failedAttachments > 0 {
                            HStack {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.orange)
                                Text("\(stats.failedAttachments) attachment\(stats.failedAttachments == 1 ? "" : "s") failed")
                                    .font(.headline)
                                    .foregroundColor(.orange)
                            }
                        }

                        if stats.failedNotes > 0 {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text("\(stats.failedNotes) note\(stats.failedNotes == 1 ? "" : "s") failed")
                                    .font(.headline)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                } else if case .cancelled = exportViewModel.exportState {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.orange)
                        Text("Export cancelled")
                            .font(.headline)
                    }
                } else if case .error(let message) = exportViewModel.exportState {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Export failed")
                                .font(.headline)
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            // Action buttons
            HStack {
                Button {
                    sharedState.showExportLog()
                } label: {
                    Text("View Export Log")
                }

                Spacer()

                if case .exporting = exportViewModel.exportState {
                    Button {
                        Logger.noteExport.info("User triggered export cancellation")
                        exportViewModel.cancelExport()
                    } label: {
                        Text(exportViewModel.shouldCancel ? "Cancelling..." : "Cancel Export")
                    }
                    .disabled(exportViewModel.shouldCancel)
                } else {
                    Button {
                        exportViewModel.reset()
                        sharedState.showProgressWindow = false
                    } label: {
                        Text("Done")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(15)
    }
}

