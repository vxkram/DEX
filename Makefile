PACKAGE := Packages/DexCore

# With only the Command Line Tools installed, SwiftPM does not find the
# Swift Testing macro plugin on its own. Full Xcode does not need this.
CLT_TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
ifneq ($(wildcard $(CLT_TESTING_PLUGINS)),)
ifeq ($(findstring CommandLineTools,$(shell xcode-select -p)),CommandLineTools)
TEST_FLAGS := -Xswiftc -plugin-path -Xswiftc $(CLT_TESTING_PLUGINS)
endif
endif

.PHONY: build test test-hdr test-models release cli formats clean project app run xcode package

build:
	swift build --package-path $(PACKAGE)

test:
	swift test --package-path $(PACKAGE) $(TEST_FLAGS)

# Extra checks against a real iPhone HDR photo (never committed).
# Usage: make test-hdr HDR_SAMPLE=~/Downloads/IMG_1234.HEIC
test-hdr:
	@test -n "$(HDR_SAMPLE)" || (echo "set HDR_SAMPLE=<path to an iPhone HEIC>" && exit 64)
	DEX_HDR_SAMPLE="$(HDR_SAMPLE)" swift test --package-path $(PACKAGE) $(TEST_FLAGS) --filter HDRTests

# Enhance models, end to end (downloads the models-1 release, about 100 MB,
# into build/models once).
MODELS := build/models
test-models: build
	@mkdir -p $(MODELS)/zips
	@for m in dex-fast-low dex-fast-medium dex-fast-high dex-best dex-anime dex-faces; do \
		test -f $(MODELS)/zips/$$m.mlpackage.zip || curl -sSL -o $(MODELS)/zips/$$m.mlpackage.zip \
			https://github.com/vxkram/DEX/releases/download/models-1/$$m.mlpackage.zip; done
	cp $(MODELS)/zips/*.zip $(MODELS)/ && DEX_MODELS_DIR=$(abspath $(MODELS)/installed) $(PACKAGE)/.build/debug/dex install-model $(MODELS)/*.mlpackage.zip
	DEX_MODELS_DIR="$(abspath $(MODELS)/installed)" swift test --package-path $(PACKAGE) $(TEST_FLAGS) --filter EnhancerTests

release:
	swift build --package-path $(PACKAGE) -c release

# Usage: make cli ARGS="inspect ~/Pictures/photo.heic"
cli: build
	$(PACKAGE)/.build/debug/dex $(ARGS)

formats: build
	$(PACKAGE)/.build/debug/dex formats

clean:
	swift package --package-path $(PACKAGE) clean

# --- macOS app -------------------------------------------------------------

APP_BUILD := build/app
APP := $(APP_BUILD)/Build/Products/Debug/DEX.app

# Regenerate DEX.xcodeproj from project.yml (needs `brew install xcodegen`).
project:
	xcodegen generate --quiet

app: project
	xcodebuild -project DEX.xcodeproj -scheme DEX -configuration Debug \
		-derivedDataPath $(APP_BUILD) -quiet build

# Build and launch the app.
run: app
	open "$(APP)"

xcode: project
	open DEX.xcodeproj

# Release build zipped for sharing: build/DEX.zip (ad-hoc signed, not
# notarised; recipients allow it once in System Settings → Privacy & Security).
package: project
	xcodebuild -project DEX.xcodeproj -scheme DEX -configuration Release \
		-derivedDataPath build/release -quiet build
	rm -f build/DEX.zip
	ditto -c -k --keepParent build/release/Build/Products/Release/DEX.app build/DEX.zip
	@echo "Created build/DEX.zip ($$(du -h build/DEX.zip | cut -f1))"

