DERIVED := build/DerivedData
PRODUCTS := $(DERIVED)/Build/Products

.PHONY: project build release test run clean

project:
	xcodegen generate

build: project
	xcodebuild -scheme SpeakerKeepAlive -configuration Debug -derivedDataPath $(DERIVED) build

release: project
	xcodebuild -scheme SpeakerKeepAlive -configuration Release -derivedDataPath $(DERIVED) build
	@echo "Built $(PRODUCTS)/Release/SpeakerKeepAlive.app"

# Runs the test bundle with xctest directly; it's quicker than `xcodebuild test`
# and avoids its test-runner start-up timeouts.
test: project
	xcodebuild -scheme SpeakerKeepAlive -configuration Debug -derivedDataPath $(DERIVED) build-for-testing
	xcrun xctest $(PRODUCTS)/Debug/KeepAliveCoreTests.xctest

run: build
	open $(PRODUCTS)/Debug/SpeakerKeepAlive.app

clean:
	rm -rf build SpeakerKeepAlive.xcodeproj
