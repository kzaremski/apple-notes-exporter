# Apple Notes Exporter - Makefile
# For terminal-based development workflow

.PHONY: help build run clean logs test rebuild install icon

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

# Default target
help:
	@echo "Apple Notes Exporter - Make targets:"
	@echo ""
	@echo "  make build     - Build the app (Debug configuration)"
	@echo "  make run       - Build and run the app"
	@echo "  make clean     - Clean build artifacts"
	@echo "  make rebuild   - Clean and build"
	@echo "  make logs      - Stream app logs (run in separate terminal)"
	@echo "  make test      - Run unit tests"
	@echo "  make release   - Build Release configuration"
	@echo "  make install   - Build and install to /Applications"
	@echo "  make icon      - Generate app icon from icon/icon.svg"
	@echo ""

# Build the project
build:
	@echo "🔨 Building $(SCHEME)..."
	@set -o pipefail && xcodebuild -project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration $(CONFIG) \
		-derivedDataPath "$(BUILD_DIR)" \
		build 2>&1 | tee build.log | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED|^/" || true
	@if grep -q "BUILD FAILED" build.log 2>/dev/null; then \
		echo ""; \
		echo "❌ Build failed! Errors:"; \
		grep "error:" build.log | head -20; \
		exit 1; \
	elif grep -q "BUILD SUCCEEDED" build.log 2>/dev/null; then \
		echo "✅ Build succeeded"; \
	fi

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

# Build release version
release:
	@echo "🔨 Building Release configuration..."
	xcodebuild -project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Release \
		-derivedDataPath "$(BUILD_DIR)" \
		build

# Install to /Applications
install: release
	@echo "📦 Installing to /Applications..."
	@cp -R "$(BUILD_DIR)/Build/Products/Release/$(APP_NAME)" /Applications/
	@echo "✅ Installed to /Applications/$(APP_NAME)"

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
