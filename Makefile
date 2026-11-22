.PHONY: all rust cli swift-package swift-package-force media-tools xcode build release package test clean run launcher prepare-run run-detached verify-version quality fuzz-check mutation-check coverage-check swift-analysis

# Keep the generated FFI package separate from older global Xcode artifacts.
export PARAKATT_DERIVED_DATA ?= $(CURDIR)/target/xcode
# Prefer repository-local pinned tools; retain PATH as a fallback for CI.
export PATH := $(CURDIR)/target/tools/bin:$(PATH)
export MACOSX_DEPLOYMENT_TARGET := 14.0
export PARAKATT_SPEECH_FEATURES ?= webgpu
# Use the selected Xcode SDK, including when Command Line Tools has a newer SDK.
export SDKROOT ?= $(shell xcodebuild -version -sdk macosx Path 2>/dev/null)

VERSION := $(shell cat VERSION)
APP_NAME := Parakatt
DMG_NAME := $(APP_NAME)-$(VERSION)-arm64.dmg
ZIP_NAME := $(APP_NAME)-$(VERSION)-arm64.zip

# Build everything from scratch
all: rust swift-package xcode build

# Build the Rust core library
rust:
	sh scripts/build-native-core.sh

# Build the output-only file transcription CLI for the current platform.
cli:
	cargo build --locked --release -p parakatt-cli

# Linux desktop: native bindings first, then install into a user-owned venv.
.PHONY: linux-native linux-desktop linux-test
linux-native:
	python3 scripts/build-linux.py

linux-desktop: linux-native
	python3 -m venv --clear target/linux-venv
	target/linux-venv/bin/python -m pip install --require-hashes -r linux/requirements.lock
	target/linux-venv/bin/python -m pip install --no-deps ./linux
	target/linux-venv/bin/python -m pip check
	@echo "Run target/linux-venv/bin/parakatt-desktop"

linux-test:
	PYTHONPATH=linux target/linux-venv/bin/python -m unittest discover -s linux/tests -v

# Run Rust tests
test:
	cargo test --locked

# Run the source checks used by CI. Install pinned tools before running this target.
quality:
	cargo fmt --check
	cargo clippy --locked --workspace --all-targets --all-features -- -D warnings
	env swiftlint lint --strict --no-cache
	env ruff check scripts
	env ruff format --check scripts
	env actionlint
	cargo deny --locked check licenses bans sources
	cargo deny --manifest-path fuzz/Cargo.toml --locked check licenses bans sources

# Run bounded input fuzzing with the pinned nightly and cargo-fuzz from CI.
fuzz-check:
	cargo fmt --manifest-path fuzz/Cargo.toml --check
	cargo metadata --manifest-path fuzz/Cargo.toml --format-version 1 --locked > /dev/null
	mkdir -p target/fuzz-corpus/input_contracts
	cargo +nightly-2026-11-04 fuzz run input_contracts target/fuzz-corpus/input_contracts fuzz/seeds -- -runs=2000 -max_len=4096
	git diff --exit-code -- fuzz/Cargo.lock

# Check that contract tests reject deliberate changes to critical decisions.
mutation-check:
	mkdir -p target
	cargo mutants --timeout 60 --build-timeout 300 --output target/mutation-contracts $(MUTATION_FLAGS)

# Compare critical Rust modules with the base commit on the same toolchain.
coverage-check:
	python3 scripts/run_rust_coverage.py

# Requires a complete, non-incremental compiler log (the normal Swift CI job supplies it).
swift-analysis:
	test -n "$(COMPILER_LOG)"
	swiftlint analyze --strict --config .swiftlint.yml --config .swiftlint-analyze.yml --compiler-log-path "$(COMPILER_LOG)"

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
release: verify-version media-tools
	xcodebuild -project Parakatt.xcodeproj -scheme Parakatt -derivedDataPath "$(PARAKATT_DERIVED_DATA)" -configuration Release ARCHS=arm64 build

# Get the Release build products directory
RELEASE_BUILD_DIR = $(shell python3 scripts/build-products.py Release)

# Sign the final bundle after Xcode has embedded the frameworks and media helpers.
package: release
	python3 scripts/macos_signing.py app "$(RELEASE_BUILD_DIR)/$(APP_NAME).app"
	python3 scripts/verify-app.py "$(RELEASE_BUILD_DIR)/$(APP_NAME).app"
	python3 scripts/smoke-app.py "$(RELEASE_BUILD_DIR)/$(APP_NAME).app"
	python3 scripts/smoke-app.py "$(RELEASE_BUILD_DIR)/$(APP_NAME).app" --normal-startup
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
		python3 scripts/macos_signing.py dmg "dist/$(DMG_NAME)" || exit $$?; \
		echo "Created dist/$(DMG_NAME)"; \
	else \
		echo "Skipping DMG (install create-dmg: brew install create-dmg)"; \
	fi

# Launch the Debug bundle through Launch Services for normal permission attribution.
run run-detached:
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

verify-version:
	./scripts/sync-version.sh --check

benchmark:
	cargo build --locked --release --example model_bench --features "$(PARAKATT_SPEECH_FEATURES)"
	python3 scripts/benchmark.py $(ARGS)

# Automatic selection requires a validation entry; explicit WebGPU tries the runtime.
swift-package-webgpu:
	PARAKATT_SPEECH_FEATURES=webgpu python3 scripts/swift-package.py

benchmark-streaming:
	cargo build --locked --release --example streaming_bench
	python3 scripts/benchmark.py --streaming --model-id nemotron-3.5-asr-streaming-0.6b --binary "$(CURDIR)/target/release/examples/streaming_bench" $(ARGS)
