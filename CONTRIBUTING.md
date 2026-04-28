# Contributing

Thanks for your interest in Apple Notes Exporter! Contributions of all kinds are welcome - bug fixes, new features, documentation, whatever you've got.

## Getting Set Up

1. Fork the repo and clone your fork
2. Set up your local signing config (see [Signing](#signing) below)
3. Open `Apple Notes Exporter/Apple Notes Exporter.xcodeproj` in Xcode
4. The app needs **Full Disk Access** to read the Apple Notes database
5. Build and run:

```sh
make build        # Debug build (CLI + MCP embedded in the .app bundle)
make run          # Build and launch
make test         # Run tests
make clean        # Clean build artifacts
make logs         # Stream app logs
make test-formats # Export a sample note via the embedded CLI to every format
```

## Signing

The Apple Developer team ID is kept out of the committed `project.pbxproj` so that every contributor can build locally without trampling each other's team settings. Instead, each developer creates a local override.

First time:

```sh
cp "Apple Notes Exporter/Apple Notes Exporter/Config/Signing.local.xcconfig.example" \
   "Apple Notes Exporter/Apple Notes Exporter/Config/Signing.local.xcconfig"
```

Then edit `Signing.local.xcconfig` and fill in `LOCAL_DEVELOPMENT_TEAM` with your team ID (available at [developer.apple.com](https://developer.apple.com/account) under "Membership details"). The file is gitignored.

If you're just building locally without a paid developer account, you can leave the team empty and Xcode will fall back to ad-hoc signing — enough to run the Debug build on your own machine.

## Project Layout

```
Apple Notes Exporter/
  Apple Notes Exporter/                     # Main app target (SwiftUI)
    AppleNotesExporterApp.swift             # App entry + menu commands
    AppleNotesExporterView.swift            # Main export UI
    AppleNotesKit/                          # C parser for the Notes SQLite DB
    HTMLAttachmentProcessor.swift           # Attachment placeholders -> real HTML
    NoteHTMLGenerator.swift                 # Protobuf -> HTML
    TableParser.swift                       # Table protobuf -> HTML/Markdown
    AppIntents.swift                        # Shortcuts actions
    ExportSupport.swift                     # Shared helpers (across all targets)
    Models/                                 # Data models, format converters
    ViewModels/                             # MVVM view models
    Repository/                             # DB access abstraction
    Config/                                 # xcconfig files for signing
  Apple Notes Exporter CLI/                 # notes-export command-line tool
  Apple Notes Exporter MCP/                 # notes-export-mcp server
```

The CLI and MCP binaries are built as dependencies of the main app and embedded into `Contents/SharedSupport/` of the `.app` bundle.

## Developer Certificate of Origin (DCO)

This project uses the [Developer Certificate of Origin](https://developercertificate.org/) (DCO) instead of a CLA. By signing off on your commits, you certify that you wrote the code (or have the right to submit it) and agree to license it under the project's GPLv3.

**Every commit in a PR must include a `Signed-off-by:` trailer** matching the commit author. Git adds this automatically with the `-s` flag:

```sh
git commit -s -m "fix(db): handle missing ZTITLE1 column on iOS 17"
```

The trailer looks like:

```
Signed-off-by: Jane Doe <jane@example.com>
```

A CI check (`.github/workflows/dco.yml`) verifies every commit in a PR has a matching sign-off. If a commit is missing one, you can fix it with:

```sh
# Last commit only:
git commit --amend --signoff

# All commits in the branch:
git rebase --signoff main
```

Then force-push to update your PR.

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

Keep the description short and to the point. A body with extra detail is fine for bigger changes but not required.

Do not use em-dashes in commit messages or code comments; use a regular hyphen, comma, or parentheses instead.

## Submitting a PR

1. Branch off `main`
2. Make your changes, make sure it builds (`make build`)
3. Sign off every commit (`git commit -s`, see [DCO](#developer-certificate-of-origin-dco))
4. Open a PR describing what you changed and why
5. Reference any related issues (e.g. "Fixes #22")

Note: changes to `*.pbxproj`, `*.xcconfig`, `*.entitlements`, `*.xcscheme`, or anything under `.github/` require review from the project owner via CODEOWNERS.

## Add Yourself to CONTRIBUTORS.txt

If your PR gets merged, add a line to `CONTRIBUTORS.txt` as part of your PR:

```
- Your Name (GitHub: @yourusername) - What you did.
```

## Reporting Bugs

When filing an issue, it helps to include:

- Your macOS version
- Steps to reproduce
- Export log output (Cmd+L in the app)
- The attachment type or note content involved, if relevant

## Things to Know

- The Apple Notes SQLite schema changes across macOS/iOS versions. Column resolution (e.g. `ZTITLE1` vs `ZTITLE2`) is handled in `AppleNotesKit.c` via schema probing.
- Drawings and scanned documents use fallback files on disk rather than blobs in the database. The paths go through `~/Library/Group Containers/group.com.apple.notes/Accounts/<accountId>/` with a 3-tier fallback (account-specific, container root, cross-account).
- The app uses MVVM with a Repository pattern. `async/await` and `TaskGroup` for concurrency.
- Logging goes through `OSLog` via the `Logger` extensions.
- The CLI and MCP targets share code with the main app; changes to `ExportSupport.swift`, `NotesModels.swift`, etc. affect all three targets.

## License

By contributing you agree that your work will be licensed under the project's [GNU General Public License v3.0](LICENSE) and that you certify the [Developer Certificate of Origin](https://developercertificate.org/) by signing off on your commits.
