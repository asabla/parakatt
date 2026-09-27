.PHONY: all rust swift-package swift-package-force media-tools xcode build release package test clean run launcher prepare-run run-detached

# Keep the generated FFI package separate from older global Xcode artifacts.
export PARAKATT_DERIVED_DATA ?= $(CURDIR)/target/xcode
# Prefer repository-local pinned tools; retain PATH as a fallback for CI.
export PATH := $(CURDIR)/target/tools/bin:$(PATH)
export MACOSX_DEPLOYMENT_TARGET := 14.0
export PARAKATT_SPEECH_FEATURES ?= webgpu
# Use the selected Xcode SDK, including when Command Line Tools has a newer SDK.
export SDKROOT ?= $(shell xcodebuild -version -sdk macosx Path 2>/dev/null)

VERSION := 0.1.0
APP_NAME := Parakatt
DMG_NAME := $(APP_NAME)-$(VERSION)-arm64.dmg
ZIP_NAME := $(APP_NAME)-$(VERSION)-arm64.zip
LAUNCHER_BIN := bin/parakatt-launcher

# Build everything from scratch
all: rust swift-package xcode build

# Build the Rust core library
rust:
	cargo build --locked --release --target aarch64-apple-darwin -p parakatt-core --features "$(PARAKATT_SPEECH_FEATURES)"

# Run Rust tests
test:
	cargo test --locked

# Build Rust before fingerprinting and generating the matching Swift bindings.
swift-package: rust
	python3 scripts/swift-package.py

swift-package-force: rust
	python3 scripts/swift-package.py --force

# Generate the Xcode project from project.yml
media-tools:
	python3 scripts/prepare-media-tools.py
	python3 scripts/prepare-playback-engine.py

xcode: media-tools
	@test "$$(xcodegen --version)" = "Version: 2.46.0" || (echo "Install XcodeGen 2.46.0 with scripts/install-xcodegen.sh"; exit 1)
	xcodegen generate

# Build the macOS app via xcodebuild (Debug)
build: media-tools
	xcodebuild -project Parakatt.xcodeproj -scheme Parakatt -derivedDataPath "$(PARAKATT_DERIVED_DATA)" -configuration Debug ARCHS=arm64 build

# Build the macOS app in Release configuration
release: media-tools
	xcodebuild -project Parakatt.xcodeproj -scheme Parakatt -derivedDataPath "$(PARAKATT_DERIVED_DATA)" -configuration Release ARCHS=arm64 build

# Get the Release build products directory
RELEASE_BUILD_DIR = $(shell python3 scripts/build-products.py Release)

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
# Local run targets also reuse this launcher to keep the executable identity stable.
package: verify-launcher release
	@if [ ! -f "$(LAUNCHER_BIN)" ]; then \
		echo "Error: pre-built launcher not found at $(LAUNCHER_BIN)"; \
		echo "Run 'make launcher' first to build the stable launcher binary."; \
		exit 1; \
	fi
	@echo "Swapping in stable launcher binary..."
	cp "$(LAUNCHER_BIN)" "$(RELEASE_BUILD_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)"
	python3 scripts/verify-app.py "$(RELEASE_BUILD_DIR)/$(APP_NAME).app"
	python3 scripts/smoke-app.py "$(RELEASE_BUILD_DIR)/$(APP_NAME).app"
	@mkdir -p dist
	ditto -c -k --keepParent target/media-tools/sources "dist/$(APP_NAME)-$(VERSION)-media-sources.zip"
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
			"$(RELEASE_BUILD_DIR)/$(APP_NAME).app" || exit $$?; \
		echo "Created dist/$(DMG_NAME)"; \
	else \
		echo "Skipping DMG (install create-dmg: brew install create-dmg)"; \
	fi

# Reuse the release launcher identity for local microphone and Accessibility grants.
prepare-run: verify-launcher
	cp "$(LAUNCHER_BIN)" "$$(python3 scripts/build-products.py Debug)/Parakatt.app/Contents/MacOS/Parakatt"
	python3 scripts/verify-launcher.py "$$(python3 scripts/build-products.py Debug)/Parakatt.app/Contents/MacOS/Parakatt"

# Run the built app (with log output)
run: prepare-run
	@pkill -f Parakatt 2>/dev/null; sleep 1; \
	"$$(python3 scripts/build-products.py Debug)/Parakatt.app/Contents/MacOS/Parakatt"

# Run the built app detached (no logs)
run-detached: prepare-run
	@open "$$(python3 scripts/build-products.py Debug)/Parakatt.app"

# Download the Parakeet TDT 0.6B v3 multilingual ONNX model (~2.55GB)
download-model:
	cargo run --locked --release --example install_model -- "$(HOME)/Library/Application Support/Parakatt/models" parakeet-tdt-0.6b-v3

# Run the Parakeet integration test (requires model)
test-integration:
	cargo test --locked --release --test integration_test test_parakeet_transcription -- --ignored --exact

# Clean all build artifacts
clean:
	cargo clean
	rm -rf Parakatt.xcodeproj
	rm -rf ~/Library/Developer/Xcode/DerivedData/Parakatt-*

# Quick rebuild after Rust changes only
rebuild: rust swift-package xcode build

verify-launcher:
	python3 scripts/verify-launcher.py

benchmark:
	cargo build --locked --release --example model_bench --features "$(PARAKATT_SPEECH_FEATURES)"
	python3 scripts/benchmark.py $(ARGS)

# Candidate package only. Production selection still requires a validation matrix entry.
swift-package-webgpu:
	PARAKATT_SPEECH_FEATURES=webgpu python3 scripts/swift-package.py

benchmark-streaming:
	cargo build --locked --release --example streaming_bench
	python3 scripts/benchmark.py --streaming --model-id nemotron-3.5-asr-streaming-0.6b --binary "$(CURDIR)/target/release/examples/streaming_bench" $(ARGS)
