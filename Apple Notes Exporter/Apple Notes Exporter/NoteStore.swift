//
//  NotesDatabase.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 7/31/25.
//

import SQLite3
import Foundation

struct Note {
    let title: String
    let content: String
    let created: Date
    let modified: Date
}

class NoteStore: ObservableObject {
    static let shared = NoteStore() // singleton instance

    @Published var tableNames: [String] = []
    @Published var notes: [Note] = []

    private var db: OpaquePointer?
    private let dbPath = "/Users/kzaremski/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"

    private init() {
        guard openDatabase() else { return }
        fetchTableNames()
        notes = fetchAllNotes()
        sqlite3_close(db)
    }
    
    private func openDatabase() -> Bool {
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            return true
        } else {
            print("Unable to open database at \(dbPath)")
            return false
        }
    }
    
    func close() {
        sqlite3_close(db)
    }
    
    private func fetchTableNames() {
        let query = "SELECT name FROM sqlite_master WHERE type='table';"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0) {
                    let tableName = String(cString: cString)
                    tableNames.append(tableName)
                }
            }
            sqlite3_finalize(statement)
        } else {
            print("Failed to prepare table list query.")
        }
    }
    
    func fetchAllNotes() -> [Note] {
        var notes: [Note] = []
        
        let query = """
        SELECT ZNOTE.ZTITLE, ZNOTEBODY.ZCONTENT, ZNOTE.ZCREATIONDATE, ZNOTE.ZMODIFICATIONDATE
        FROM ZNOTE
        LEFT JOIN ZNOTEBODY ON ZNOTE.ZNOTEBODY = ZNOTEBODY.Z_PK
        WHERE ZNOTE.ZMARKEDFORDELETION IS NULL OR ZNOTE.ZMARKEDFORDELETION = 0;
        """
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let title = sqlite3_column_text(statement, 0).flatMap { String(cString: $0) } ?? "(Untitled)"
                let content = sqlite3_column_text(statement, 1).flatMap { String(cString: $0) } ?? ""
                
                let creationInterval = sqlite3_column_double(statement, 2)
                let modifiedInterval = sqlite3_column_double(statement, 3)
                let created = Date(timeIntervalSinceReferenceDate: creationInterval)
                let modified = Date(timeIntervalSinceReferenceDate: modifiedInterval)
                
                notes.append(Note(title: title, content: content, created: created, modified: modified))
            }
            sqlite3_finalize(statement)
        } else {
            print("Failed to prepare notes query.")
        }
        
        return notes
    }
}
