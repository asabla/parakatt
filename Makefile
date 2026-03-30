.PHONY: all rust swift-package xcode build test clean run

# Build everything from scratch
all: rust swift-package xcode build

# Build the Rust core library
rust:
	cargo build --release -p parakatt-core

# Run Rust tests
test:
	cargo test

# Generate the UniFFI Swift Package from the Rust crate (arm64 only for Apple Silicon)
swift-package:
	rm -rf ParakattCore
	cd crates/parakatt-core && echo "y" | cargo swift package --platforms macos --name ParakattCore --target aarch64-apple-darwin
	mv crates/parakatt-core/ParakattCore .

# Generate the Xcode project from project.yml
xcode:
	xcodegen generate

# Build the macOS app via xcodebuild
build:
	xcodebuild -project Parakatt.xcodeproj -scheme Parakatt -configuration Debug build

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
