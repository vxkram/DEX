PACKAGE := Packages/DexCore

# With only the Command Line Tools installed, SwiftPM does not find the
# Swift Testing macro plugin on its own. Full Xcode does not need this.
CLT_TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
ifneq ($(wildcard $(CLT_TESTING_PLUGINS)),)
ifeq ($(findstring CommandLineTools,$(shell xcode-select -p)),CommandLineTools)
TEST_FLAGS := -Xswiftc -plugin-path -Xswiftc $(CLT_TESTING_PLUGINS)
endif
endif

.PHONY: build test release cli formats clean

build:
	swift build --package-path $(PACKAGE)

test:
	swift test --package-path $(PACKAGE) $(TEST_FLAGS)

release:
	swift build --package-path $(PACKAGE) -c release

# Usage: make cli ARGS="inspect ~/Pictures/photo.heic"
cli: build
	$(PACKAGE)/.build/debug/dex $(ARGS)

formats: build
	$(PACKAGE)/.build/debug/dex formats

clean:
	swift package --package-path $(PACKAGE) clean
