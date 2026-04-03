.PHONY: all rust swift-package swift-package-force xcode build release package test clean run launcher

VERSION := 0.1.0
APP_NAME := Parakatt
DMG_NAME := $(APP_NAME)-$(VERSION)-arm64.dmg
ZIP_NAME := $(APP_NAME)-$(VERSION)-arm64.zip
LAUNCHER_BIN := bin/parakatt-launcher

# Build everything from scratch
all: rust swift-package xcode build

# Build the Rust core library
rust:
	cargo build --release -p parakatt-core

# Run Rust tests
test:
	cargo test

# Generate the UniFFI Swift Package from the Rust crate (arm64 only for Apple Silicon).
# Skips regeneration if Rust sources haven't changed since last build.
swift-package:
	@if [ -d ParakattCore ] && [ -f .swift-package-stamp ] && \
		[ -z "$$(find crates/parakatt-core/src -newer .swift-package-stamp -name '*.rs' 2>/dev/null)" ] && \
		[ crates/parakatt-core/Cargo.toml -ot .swift-package-stamp ]; then \
		echo "ParakattCore is up to date (no Rust changes since last build)"; \
	else \
		rm -rf ParakattCore .swift-package-stamp; \
		(cd crates/parakatt-core && echo "y" | cargo swift package --platforms macos --name ParakattCore --target aarch64-apple-darwin) && \
		mv crates/parakatt-core/ParakattCore . && \
		touch .swift-package-stamp; \
	fi

# Force regenerate Swift bindings (bypasses incremental check)
swift-package-force:
	rm -rf ParakattCore .swift-package-stamp
	(cd crates/parakatt-core && echo "y" | cargo swift package --platforms macos --name ParakattCore --target aarch64-apple-darwin)
	mv crates/parakatt-core/ParakattCore .
	touch .swift-package-stamp

# Generate the Xcode project from project.yml
xcode:
	xcodegen generate

# Build the macOS app via xcodebuild (Debug)
build:
	xcodebuild -project Parakatt.xcodeproj -scheme Parakatt -configuration Debug build

# Build the macOS app in Release configuration
release:
	xcodebuild -project Parakatt.xcodeproj -scheme Parakatt -configuration Release build

# Get the Release build products directory
RELEASE_BUILD_DIR = $(shell xcodebuild -project Parakatt.xcodeproj -scheme Parakatt -configuration Release -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $$NF}')

# Build the stable launcher binary once and store it in bin/.
# This binary should be committed or stored as a release artifact.
# It must NOT be rebuilt on every release — only when Launcher/main.swift
# or entitlements change.
launcher:
	@mkdir -p bin
	swiftc -O -target arm64-apple-macos14.0 \
		-o "$(LAUNCHER_BIN)" \
		Launcher/main.swift
	codesign --force --sign - \
		--entitlements Parakatt/Parakatt.entitlements \
		--options runtime \
		"$(LAUNCHER_BIN)"
	@echo "Launcher built at $(LAUNCHER_BIN)"
	@echo "CDHash:"
	@codesign -dvvv "$(LAUNCHER_BIN)" 2>&1 | grep CDHash

# Package the Release .app, swapping in the stable launcher for distribution.
# For dev builds, the Xcode-compiled launcher is fine (TCC resets only matter
# for distributed releases).
package: release
	@if [ ! -f "$(LAUNCHER_BIN)" ]; then \
		echo "Error: pre-built launcher not found at $(LAUNCHER_BIN)"; \
		echo "Run 'make launcher' first to build the stable launcher binary."; \
		exit 1; \
	fi
	@echo "Swapping in stable launcher binary..."
	cp "$(LAUNCHER_BIN)" "$(RELEASE_BUILD_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)"
	codesign --force --sign - \
		--entitlements Parakatt/Parakatt.entitlements \
		--options runtime \
		"$(RELEASE_BUILD_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)"
	@echo "Stable launcher CDHash:"
	@codesign -dvvv "$(RELEASE_BUILD_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>&1 | grep CDHash
	@mkdir -p dist
	ditto -c -k --keepParent "$(RELEASE_BUILD_DIR)/$(APP_NAME).app" "dist/$(ZIP_NAME)"
	@echo "Created dist/$(ZIP_NAME)"
	@if command -v create-dmg >/dev/null 2>&1; then \
		rm -f "dist/$(DMG_NAME)"; \
		create-dmg \
			--volname "$(APP_NAME)" \
			--window-pos 200 120 \
			--window-size 600 400 \
			--icon-size 100 \
			--icon "$(APP_NAME).app" 175 190 \
			--hide-extension "$(APP_NAME).app" \
			--app-drop-link 425 190 \
			"dist/$(DMG_NAME)" \
			"$(RELEASE_BUILD_DIR)/$(APP_NAME).app"; \
		echo "Created dist/$(DMG_NAME)"; \
	else \
		echo "Skipping DMG (install create-dmg: brew install create-dmg)"; \
	fi

# Run the built app (with log output)
run:
	@pkill -f Parakatt 2>/dev/null; sleep 1; \
	"$$(xcodebuild -project Parakatt.xcodeproj -scheme Parakatt -configuration Debug -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $$NF}')/Parakatt.app/Contents/MacOS/Parakatt"

# Run the built app detached (no logs)
run-detached:
	@open "$$(xcodebuild -project Parakatt.xcodeproj -scheme Parakatt -configuration Debug -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $$NF}')/Parakatt.app"

# Download the Parakeet TDT 0.6B v2 ONNX model (~2.5GB)
download-model:
	@mkdir -p "$(HOME)/Library/Application Support/Parakatt/models/parakeet-tdt-0.6b-v2"
	@echo "Downloading Parakeet TDT 0.6B v2 ONNX model..."
	@cd "$(HOME)/Library/Application Support/Parakatt/models/parakeet-tdt-0.6b-v2" && \
		curl -L -O "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v2-onnx/resolve/main/vocab.txt" && \
		curl -L -O "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v2-onnx/resolve/main/decoder_joint-model.onnx" && \
		curl -L -O "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v2-onnx/resolve/main/encoder-model.onnx" && \
		curl -L -O "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v2-onnx/resolve/main/encoder-model.onnx.data"
	@echo "Model downloaded to ~/Library/Application Support/Parakatt/models/parakeet-tdt-0.6b-v2/"

# Run the Parakeet integration test (requires model)
test-integration:
	cargo build --example test_parakeet -p parakatt-core
	./target/debug/examples/test_parakeet

# Clean all build artifacts
clean:
	cargo clean
	rm -rf Parakatt.xcodeproj
	rm -rf ~/Library/Developer/Xcode/DerivedData/Parakatt-*

# Quick rebuild after Rust changes only
rebuild: rust swift-package xcode build
