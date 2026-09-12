//
//  utilities.swift
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

import Foundation

// MARK: - Shared Constants (used by both GUI app and CLI)

let APP_VERSION = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.1"

let OUTPUT_FORMATS: [String] = [
    "HTML",
    "PDF",
    "TEX",
    "MD",
    "RTF",
    "TXT",
    "JSON",
    "JSONL",
    "XML",
    "CSV",
    "OPML",
    "ORG",
    "RST",
    "ADOC",
    "DOCX",
    "ODT",
    "EPUB",
    "ENEX",
]
