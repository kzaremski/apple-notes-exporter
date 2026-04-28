# Apple Notes Exporter - Makefile
# For terminal-based development workflow

.PHONY: help build run clean logs test test-formats rebuild install icon \
        release release-archive release-export release-notarize release-zip release-clean

# Configuration
PROJECT = Apple Notes Exporter/Apple Notes Exporter.xcodeproj
SCHEME = Apple Notes Exporter
CONFIG = Debug
BUILD_DIR = Apple Notes Exporter/build
APP_NAME = Apple Notes Exporter.app
BUNDLE_ID = com.konstantinzaremski.Apple-Notes-Exporter
ICON_SVG = icon/icon.svg
ICON_DIR = icon
ICONSET_DIR = Apple Notes Exporter/Apple Notes Exporter/Assets.xcassets/AppIcon.appiconset

# Code signing flags for local dev builds without a valid cert.
UNSIGNED = CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Release configuration. The notary profile must be set up once on this
# machine via:
#   xcrun notarytool store-credentials "$(NOTARY_PROFILE)" \
#     --apple-id <your-apple-id> --team-id Q7TB7B38LW --password <app-specific-password>
RELEASE_DIR     = release
RELEASE_TEAM_ID = Q7TB7B38LW
NOTARY_PROFILE  = ANE-NOTARYTOOL

# Read versions from the Release build settings so the zip name stays in sync
# with whatever the .xcconfig / project says. Slow (one xcodebuild call), so
# only invoke when the variables are actually used (=).
RELEASE_VERSION  = $(shell xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release -showBuildSettings 2>/dev/null | awk '/^ +MARKETING_VERSION = /{print $$3}' | head -1)
RELEASE_BUILD    = $(shell xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release -showBuildSettings 2>/dev/null | awk '/^ +CURRENT_PROJECT_VERSION = /{print $$3}' | head -1)
# Naming convention from past releases:
#   build 1  -> AppleNotesExporter_v<VERSION>.zip
#   build N  -> AppleNotesExporter_v<VERSION>-<N>.zip
RELEASE_SUFFIX   = $(if $(filter 1,$(RELEASE_BUILD)),,-$(RELEASE_BUILD))
RELEASE_ZIP_NAME = AppleNotesExporter_v$(RELEASE_VERSION)$(RELEASE_SUFFIX)

# Default target
help:
	@echo "Apple Notes Exporter - Make targets:"
	@echo ""
	@echo "  make build        - Build the app (Debug; CLI + MCP embedded in SharedSupport)"
	@echo "  make run          - Build and run the app"
	@echo "  make clean        - Clean build artifacts"
	@echo "  make rebuild      - Clean and build"
	@echo "  make logs         - Stream app logs (run in separate terminal)"
	@echo "  make test         - Run unit tests"
	@echo "  make test-formats - Export a sample note via the embedded CLI to every format"
	@echo "                      OUTPUT=/path FILTER=title FORMATS=\"pdf html\""
	@echo "  make install      - Build and install to /Applications"
	@echo "  make icon         - Generate app icon from icon/icon.svg"
	@echo ""
	@echo "Release flow:"
	@echo "  make release         - Archive, export, notarize, staple, and produce a"
	@echo "                          downloadable .zip in release/."
	@echo "  make release-archive - Just the .xcarchive step."
	@echo "  make release-export  - Export the .app from the archive (Developer ID)."
	@echo "  make release-notarize- Submit to Apple notary, wait, staple."
	@echo "  make release-zip     - Produce AppleNotesExporter_v<VERSION>[-<BUILD>].zip"
	@echo "  make release-clean   - Remove the release/ output directory."
	@echo ""
	@echo "The notes-export CLI and notes-export-mcp server are built as dependencies"
	@echo "of the main app target and embedded into Contents/SharedSupport/ of the .app."

# Build the project. UNSIGNED flags let local dev builds work without a dev cert.
build:
	@echo "🔨 Building $(SCHEME)..."
	@set -o pipefail && xcodebuild -project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration $(CONFIG) \
		-derivedDataPath "$(BUILD_DIR)" \
		$(UNSIGNED) \
		build 2>&1 | tee build.log | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED|^/" || true
	@if grep -q "BUILD FAILED" build.log 2>/dev/null; then \
		echo ""; \
		echo "❌ Build failed! Errors:"; \
		grep "error:" build.log | head -20; \
		exit 1; \
	elif grep -q "BUILD SUCCEEDED" build.log 2>/dev/null; then \
		echo "✅ Build succeeded"; \
	fi

# Export a note (or matching subset) to every supported format under OUTPUT.
# Usage:
#   make test-formats OUTPUT=/path/to/dir                     # all notes, every format
#   make test-formats OUTPUT=/path FILTER="vacation"          # notes whose title contains "vacation"
#   make test-formats OUTPUT=/path FILTER=test FORMATS="pdf html md"  # subset of formats
OUTPUT ?= $(HOME)/Downloads/ane-format-test
FILTER ?=
FORMATS ?= html pdf markdown rtf txt tex json jsonl xml csv opml org rst adoc docx odt epub enex

test-formats: build
	@CLI="$(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME)/Contents/SharedSupport/notes-export"; \
	if [ ! -x "$$CLI" ]; then echo "❌ Embedded CLI not found at $$CLI"; exit 1; fi; \
	mkdir -p "$(OUTPUT)"; \
	FILTER_ARG=""; \
	if [ -n "$(FILTER)" ]; then FILTER_ARG="--title-contains $(FILTER)"; fi; \
	echo ""; \
	echo "📤 Testing all export formats"; \
	echo "   Output:  $(OUTPUT)"; \
	echo "   Filter:  $${FILTER:-<none, all notes>}"; \
	echo "   CLI:     $$CLI"; \
	echo ""; \
	printf "%-10s %-4s %-5s %-5s %s\n" "FORMAT" "RC" "EXP" "FAIL" "OUTPUT"; \
	echo "-------------------------------------------------------------"; \
	passed=0; failed=0; \
	for f in $(FORMATS); do \
		dir="$(OUTPUT)/$$f"; \
		rm -rf "$$dir"; \
		mkdir -p "$$dir"; \
		result=$$("$$CLI" export --output "$$dir" --format "$$f" $$FILTER_ARG 2>&1); \
		rc=$$?; \
		exp=$$(echo "$$result" | grep -o '"exported" : [0-9]*' | head -1 | awk '{print $$NF}'); \
		fl=$$(echo "$$result" | grep -o '"failed" : [0-9]*' | head -1 | awk '{print $$NF}'); \
		if [ "$$rc" = "0" ] && [ "$${fl:-0}" = "0" ]; then passed=$$((passed+1)); status="✓"; else failed=$$((failed+1)); status="✗"; fi; \
		printf "%-10s %-4s %-5s %-5s %s %s\n" "$$f" "$$rc" "$${exp:-?}" "$${fl:-?}" "$$status" "$$dir"; \
	done; \
	echo "-------------------------------------------------------------"; \
	echo "✓ $$passed passed, ✗ $$failed failed of $$(echo $(FORMATS) | wc -w | tr -d ' ') formats"; \
	if [ "$$failed" -gt 0 ]; then exit 1; fi

# Build and run
run: build
	@echo "🚀 Launching $(APP_NAME)..."
	@open "$(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME)"

# Clean build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	xcodebuild -project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		clean
	rm -rf "$(BUILD_DIR)"

# Clean and rebuild
rebuild: clean build

# Stream app logs (use in separate tmux pane/window)
logs:
	@echo "📋 Streaming logs for $(APP_NAME)..."
	@echo "Press Ctrl+C to stop"
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level debug

# Alternative: stream by process name
logs-process:
	@echo "📋 Streaming logs for process '$(SCHEME)'..."
	log stream --process "$(SCHEME)"

# Run unit tests
test:
	@echo "🧪 Running tests..."
	xcodebuild test \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-derivedDataPath "$(BUILD_DIR)"

# Build release version (used by `install`; not a distributable artifact).
release-build:
	@echo "🔨 Building Release configuration..."
	xcodebuild -project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Release \
		-derivedDataPath "$(BUILD_DIR)" \
		build

# Install to /Applications
install: release-build
	@echo "📦 Installing to /Applications..."
	@cp -R "$(BUILD_DIR)/Build/Products/Release/$(APP_NAME)" /Applications/
	@echo "✅ Installed to /Applications/$(APP_NAME)"

# ─────────────────────────────────────────────────────────────────────────
# Release pipeline: archive → export → notarize → staple → zip
# Final artifact: release/AppleNotesExporter_v<MARKETING>[-<BUILD>].zip
# ─────────────────────────────────────────────────────────────────────────

release: release-archive release-export release-notarize release-zip
	@echo ""
	@echo "✅ Release complete."
	@echo "    Artifact: $(RELEASE_DIR)/$(RELEASE_ZIP_NAME).zip"
	@echo "    Upload to GitHub Releases via:"
	@echo "      gh release create v$(RELEASE_VERSION)$(RELEASE_SUFFIX) \\"
	@echo "        $(RELEASE_DIR)/$(RELEASE_ZIP_NAME).zip"

release-archive:
	@echo "📦 Archiving Release configuration..."
	@mkdir -p "$(RELEASE_DIR)"
	@rm -rf "$(RELEASE_DIR)/Apple Notes Exporter.xcarchive"
	xcodebuild -project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Release \
		-archivePath "$(RELEASE_DIR)/Apple Notes Exporter.xcarchive" \
		archive
	@echo "✅ Archive created at $(RELEASE_DIR)/Apple Notes Exporter.xcarchive"

release-export:
	@echo "📤 Exporting .app from archive (Developer ID)..."
	@if [ ! -d "$(RELEASE_DIR)/Apple Notes Exporter.xcarchive" ]; then \
		echo "❌ Archive not found. Run 'make release-archive' first."; exit 1; \
	fi
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>method</key>' \
		'    <string>developer-id</string>' \
		'    <key>teamID</key>' \
		'    <string>$(RELEASE_TEAM_ID)</string>' \
		'    <key>signingStyle</key>' \
		'    <string>automatic</string>' \
		'</dict>' \
		'</plist>' \
		> "$(RELEASE_DIR)/ExportOptions.plist"
	@rm -rf "$(RELEASE_DIR)/Export"
	xcodebuild -exportArchive \
		-archivePath "$(RELEASE_DIR)/Apple Notes Exporter.xcarchive" \
		-exportPath "$(RELEASE_DIR)/Export" \
		-exportOptionsPlist "$(RELEASE_DIR)/ExportOptions.plist"
	@echo "✅ Exported to $(RELEASE_DIR)/Export/$(APP_NAME)"

release-notarize:
	@echo "🍎 Submitting to Apple notary service..."
	@if [ ! -d "$(RELEASE_DIR)/Export/$(APP_NAME)" ]; then \
		echo "❌ Exported app not found. Run 'make release-export' first."; exit 1; \
	fi
	@if ! xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1; then \
		echo ""; \
		echo "❌ Notary credential profile '$(NOTARY_PROFILE)' is not set up."; \
		echo "   First-time setup:"; \
		echo "     xcrun notarytool store-credentials \"$(NOTARY_PROFILE)\" \\"; \
		echo "       --apple-id <your-apple-id> \\"; \
		echo "       --team-id $(RELEASE_TEAM_ID) \\"; \
		echo "       --password <app-specific-password>"; \
		echo "   App-specific passwords: https://account.apple.com → Sign-In and Security → App-Specific Passwords"; \
		exit 1; \
	fi
	@rm -f "$(RELEASE_DIR)/notarize.zip"
	ditto -c -k --keepParent "$(RELEASE_DIR)/Export/$(APP_NAME)" "$(RELEASE_DIR)/notarize.zip"
	xcrun notarytool submit "$(RELEASE_DIR)/notarize.zip" \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait
	@rm -f "$(RELEASE_DIR)/notarize.zip"
	@echo "📎 Stapling notarization ticket to .app..."
	xcrun stapler staple "$(RELEASE_DIR)/Export/$(APP_NAME)"
	xcrun stapler validate "$(RELEASE_DIR)/Export/$(APP_NAME)"
	@echo "✅ Notarized and stapled."

release-zip:
	@echo "🗜  Creating distribution zip..."
	@if [ ! -d "$(RELEASE_DIR)/Export/$(APP_NAME)" ]; then \
		echo "❌ Stapled app not found. Run 'make release-notarize' first."; exit 1; \
	fi
	@rm -f "$(RELEASE_DIR)/$(RELEASE_ZIP_NAME).zip"
	ditto -c -k --keepParent "$(RELEASE_DIR)/Export/$(APP_NAME)" "$(RELEASE_DIR)/$(RELEASE_ZIP_NAME).zip"
	@SIZE=$$(du -h "$(RELEASE_DIR)/$(RELEASE_ZIP_NAME).zip" | cut -f1); \
		echo "✅ Created $(RELEASE_DIR)/$(RELEASE_ZIP_NAME).zip ($$SIZE)"

release-clean:
	@echo "🧹 Removing $(RELEASE_DIR)/..."
	@rm -rf "$(RELEASE_DIR)"
	@echo "✅ Release artifacts cleaned"

# Quick debug (build + run + logs)
# Run this in tmux with multiple panes:
#   Pane 1: make debug
#   Pane 2: make logs
debug: run

# Show build settings
settings:
	@xcodebuild -project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-showBuildSettings

# List available schemes
schemes:
	@xcodebuild -project "$(PROJECT)" -list

# Check for build errors
check:
	@echo "🔍 Running build check..."
	@xcodebuild -project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration $(CONFIG) \
		-derivedDataPath "$(BUILD_DIR)" \
		-dry-run \
		build 2>&1 | grep -i error || echo "✅ No build errors detected"

# Generate app icon from SVG
icon:
	@echo "🎨 Generating app icon from $(ICON_SVG)..."
	@if ! command -v rsvg-convert >/dev/null 2>&1 && ! command -v inkscape >/dev/null 2>&1; then \
		echo "❌ Error: Neither rsvg-convert nor inkscape found."; \
		echo "Install librsvg with: brew install librsvg"; \
		echo "Or install Inkscape with: brew install --cask inkscape"; \
		exit 1; \
	fi
	@if [ ! -f "$(ICON_SVG)" ]; then \
		echo "❌ Error: $(ICON_SVG) not found"; \
		exit 1; \
	fi
	@echo "Generating PNG files at various sizes..."
	@mkdir -p "$(ICON_DIR)"
	@for size in 16 32 64 128 256 512 1024; do \
		if command -v rsvg-convert >/dev/null 2>&1; then \
			rsvg-convert -w $$size -h $$size "$(ICON_SVG)" -o "$(ICON_DIR)/icon_$$size.png"; \
		else \
			inkscape "$(ICON_SVG)" -w $$size -h $$size -o "$(ICON_DIR)/icon_$$size.png" 2>/dev/null; \
		fi; \
		echo "  ✓ Generated icon_$$size.png"; \
	done
	@echo ""
	@echo "📦 Copying icons to Xcode asset catalog..."
	@cp "$(ICON_DIR)/icon_16.png" "$(ICONSET_DIR)/icon_16.png"
	@cp "$(ICON_DIR)/icon_32.png" "$(ICONSET_DIR)/icon_32.png"
	@cp "$(ICON_DIR)/icon_32.png" "$(ICONSET_DIR)/icon_32 1.png"
	@cp "$(ICON_DIR)/icon_64.png" "$(ICONSET_DIR)/icon_64.png"
	@cp "$(ICON_DIR)/icon_128.png" "$(ICONSET_DIR)/icon_128.png"
	@cp "$(ICON_DIR)/icon_256.png" "$(ICONSET_DIR)/icon_256.png"
	@cp "$(ICON_DIR)/icon_256.png" "$(ICONSET_DIR)/icon_256 1.png"
	@cp "$(ICON_DIR)/icon_512.png" "$(ICONSET_DIR)/icon_512.png"
	@cp "$(ICON_DIR)/icon_512.png" "$(ICONSET_DIR)/icon_512 1.png"
	@cp "$(ICON_DIR)/icon_1024.png" "$(ICONSET_DIR)/icon_1024.png"
	@echo "  ✓ Copied all icon sizes to $(ICONSET_DIR)"
	@echo ""
	@echo "✅ Icon generation complete!"
	@echo ""
	@echo "Generated files in $(ICON_DIR)/:"
	@ls -lh "$(ICON_DIR)"/icon_*.png 2>/dev/null | awk '{print "  " $$9 " (" $$5 ")"}'
