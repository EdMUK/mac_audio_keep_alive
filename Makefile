DERIVED := build/DerivedData
PRODUCTS := $(DERIVED)/Build/Products

.PHONY: project build release install test run clean

project:
	xcodegen generate

build: project
	xcodebuild -scheme SpeakerKeepAlive -configuration Debug -derivedDataPath $(DERIVED) build

release: project
	xcodebuild -scheme SpeakerKeepAlive -configuration Release -derivedDataPath $(DERIVED) build
	@echo "Built $(PRODUCTS)/Release/SpeakerKeepAlive.app"

# Install into /Applications and relaunch. Run it from there, not from the
# build folder: if the build folder is on an external drive that disconnects
# (e.g. during sleep), the running app crashes.
install: release
	-pkill -x SpeakerKeepAlive
	rm -rf /Applications/SpeakerKeepAlive.app
	ditto $(PRODUCTS)/Release/SpeakerKeepAlive.app /Applications/SpeakerKeepAlive.app
	open /Applications/SpeakerKeepAlive.app

# Runs the test bundle with xctest directly; it's quicker than `xcodebuild test`
# and avoids its test-runner start-up timeouts.
test: project
	xcodebuild -scheme SpeakerKeepAlive -configuration Debug -derivedDataPath $(DERIVED) build-for-testing
	xcrun xctest $(PRODUCTS)/Debug/KeepAliveCoreTests.xctest

run: build
	open $(PRODUCTS)/Debug/SpeakerKeepAlive.app

clean:
	rm -rf build SpeakerKeepAlive.xcodeproj
