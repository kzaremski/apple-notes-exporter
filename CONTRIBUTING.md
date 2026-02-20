# Contributing

Thanks for your interest in Apple Notes Exporter! Contributions of all kinds are welcome - bug fixes, new features, documentation, whatever you've got.

## Getting Set Up

1. Fork the repo and clone your fork
2. Open `Apple Notes Exporter/Apple Notes Exporter.xcodeproj` in Xcode
3. The app needs **Full Disk Access** to read the Apple Notes database
4. Build and run:

```sh
make build      # Debug build
make run        # Build and launch
make test       # Run tests
make clean      # Clean build artifacts
make logs       # Stream app logs
```

## Project Layout

```
Apple Notes Exporter/
  Apple Notes Exporter/
    AppleNotesExporterApp.swift          # App entry point
    AppleNotesExporterView.swift         # Main UI
    AppleNotesDatabaseParser.swift       # SQLite + protobuf parsing
    HTMLAttachmentProcessor.swift        # Attachment placeholders -> real content
    TableParser.swift                    # Table protobuf -> HTML/Markdown
    notestore.pb.swift                   # Generated protobuf models
    Models/                              # Data models, export converters
    ViewModels/                          # MVVM view models
    Repository/                          # DB access abstraction
    Views/                               # Other SwiftUI views
```

## Commit Messages

We use [Conventional Commits](https://www.conventionalcommits.org/). All commits should be prefixed with a type:

- `fix:` bug fix
- `feat:` new feature
- `refactor:` restructuring without behavior change
- `docs:` documentation
- `chore:` build/dependency/CI stuff
- `style:` formatting, whitespace
- `test:` adding or fixing tests
- `perf:` performance improvement

A scope in parentheses is optional but helpful:

```
fix(db): use correct account column for fallback image paths
feat(export): add support for com.apple.drawing.2 attachments
docs: add contributing guidelines
```

Keep the description short and to the point. A body with extra detail is fine for bigger changes but not required. We don't tie commit types to version numbers or anything like that - just use the type that fits.

## Submitting a PR

1. Branch off `main`
2. Make your changes, make sure it builds (`make build`)
3. Open a PR describing what you changed and why
4. Reference any related issues (e.g. "Fixes #22")

## Add Yourself to CONTRIBUTORS.txt

If your PR gets merged, add a line to `CONTRIBUTORS.txt` as part of your PR:

```
- Your Name (GitHub: @yourusername) — What you did.
```

## Reporting Bugs

When filing an issue, it helps to include:

- Your macOS version
- Steps to reproduce
- Export log output (Cmd+L in the app)
- The attachment type or note content involved, if relevant

## Things to Know

- The Apple Notes database schema changes across macOS/iOS versions. When referencing columns like `ZACCOUNT`, check for the version-specific variant (e.g. `ZACCOUNT7` on iOS 16+) using `getTableColumns()`.
- Drawings and scanned documents use fallback files on disk rather than blobs in the database. The paths go through `~/Library/Group Containers/group.com.apple.notes/Accounts/<accountId>/`.
- The app uses MVVM with a Repository pattern. `async/await` and `TaskGroup` for concurrency.
- Logging goes through `OSLog` via the `Logger` extensions.

## License

By contributing you agree that your work will be licensed under the project's [MIT License](LICENSE).
