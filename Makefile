# Caelus — build, run and test helpers.
#
# The SwiftPM cache in ~/Library/Caches is not writable from the build sandbox,
# so every xcodebuild invocation carries workspace-local package paths.

PROJECT      := Caelus.xcodeproj
SCHEME       := Caelus
CONFIG       ?= Debug
ROOT         := $(CURDIR)
BUILD_DIR    := .build
DERIVED      := $(ROOT)/$(BUILD_DIR)
PKG_CHECKOUT := $(DERIVED)/SourcePackages
PKG_CACHE    := $(DERIVED)/swiftpm-cache
APP          := $(DERIVED)/Build/Products/$(CONFIG)/Caelus.app

# Absolute paths matter here: xcodebuild silently resolves nothing when the
# package directories are given relative to the project.
XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
       -derivedDataPath $(DERIVED) \
       -clonedSourcePackagesDirPath $(PKG_CHECKOUT) \
       -packageCachePath $(PKG_CACHE)

.PHONY: all generate resolve build run test test-unit clean distclean icon open logs

all: build

generate:
	@xcodegen generate --quiet

resolve: generate
	@test -d $(PKG_CHECKOUT)/checkouts/SatelliteKit || \
	  $(XCB) -resolvePackageDependencies >/dev/null
	@echo "SatelliteKit resolved at $(PKG_CHECKOUT)/checkouts/SatelliteKit"

build: resolve
	@$(XCB) build

run: build
	@open $(APP)

# Unit tests. The suite runs fully offline.
test: resolve
	@$(XCB) test -destination 'platform=macOS,arch=arm64'

test-unit: resolve
	@$(XCB) test -destination 'platform=macOS,arch=arm64' -only-testing:CaelusTests

clean:
	@rm -rf $(BUILD_DIR)/Build

distclean:
	@rm -rf $(BUILD_DIR) $(PROJECT)

icon:
	@swift Tools/make_icon.swift Caelus/Resources/Assets.xcassets/AppIcon.appiconset

open:
	@open $(PROJECT)
