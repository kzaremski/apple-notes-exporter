# Apple Notes Exporter - Makefile
# For terminal-based development workflow

.PHONY: help build run clean logs test rebuild install

# Configuration
PROJECT = Apple Notes Exporter/Apple Notes Exporter.xcodeproj
SCHEME = Apple Notes Exporter
CONFIG = Debug
BUILD_DIR = Apple Notes Exporter/build
APP_NAME = Apple Notes Exporter.app
BUNDLE_ID = com.konstantinzaremski.Apple-Notes-Exporter

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
	@echo ""

# Build the project
build:
	@echo "🔨 Building $(SCHEME)..."
	xcodebuild -project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration $(CONFIG) \
		-derivedDataPath "$(BUILD_DIR)" \
		build

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
