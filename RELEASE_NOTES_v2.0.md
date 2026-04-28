## v2.0 - Biggest release since v1.0

### New scripting interfaces
- **CLI** (`notes-export`) for headless terminal use, JSON output, full filter support
- **MCP server** (`notes-export-mcp`) for AI assistants like Claude Desktop
- **Apple Shortcuts** integration via App Intents
- All embedded inside the .app at `Contents/SharedSupport/`

### Twelve new export formats (18 total)
JSON, JSONL, XML, CSV, OPML, Org Mode, reStructuredText, AsciiDoc, DOCX, ODT, EPUB, ENEX

### Fixes
- Internal `applenotes:note/...` links rewrite to relative paths in MD/HTML exports (#32)
- Incremental sync now prunes notes deleted from Apple Notes (#31)
- Gallery attachments resolve correctly for On My Mac and cross-account notes (#27)
- Handwritten note titles export with their recognized text instead of "Untitled"
- Attachments without filenames get correct extensions via magic-byte sniffing (no more `.bin`)
- Ghost-image leak from deleted attachments fixed (#26)
- `com.apple.paper.doc.scan` UTI now recognized (#28)
- PDF export now available in CLI and MCP (uses headless WebKit)

### Other
- Redesigned app icon by [@Schneppi](https://github.com/Schneppi)
- License dialog re-shows on launch if Full Disk Access is revoked
- Bundled GPL v3 full text with expandable view in license dialog
- 18-format menu shortcuts: Cmd+1-6 / Cmd+Opt+1-6 / Cmd+Ctrl+1-6 by row
- All previously-open issues resolved

### Contributors
Thanks to [@AnotherCoolDude](https://github.com/AnotherCoolDude) (Christian Hovenbitzer) for the CLI and MCP server, [@Schneppi](https://github.com/Schneppi) (Sascha Schneppmüller) for the icon, and [@nikolsky2](https://github.com/nikolsky2) (Sergey Nikolsky) for past contributions.
