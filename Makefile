# Caelus — build, run and test.
#
# The app is Objective-C++ over a portable C++20 core; the tests link the core
# alone, so `make test` runs fully offline and without a window server.

CXX        := clang++
CXXFLAGS   := -std=c++20 -O2 -g -Wall -Wextra -Wno-unused-parameter
INCLUDES   := -I Caelus/Core -I Caelus/Render -I Caelus/Net -I Caelus/App
FRAMEWORKS := -framework Cocoa -framework Metal -framework MetalKit \
              -framework QuartzCore -framework UniformTypeIdentifiers

BUILD := build
APP   := $(BUILD)/Caelus.app
BIN   := $(APP)/Contents/MacOS/Caelus

CORE_SRC := $(shell find Caelus/Core -name '*.cpp')
APP_SRC  := Caelus/Net/URLSessionHttpClient.mm \
            Caelus/Render/GlobeView.mm \
            Caelus/App/AppController.mm \
            Caelus/App/main.mm
TEST_SRC := $(wildcard CaelusTests/Core/*.cpp)
HEADERS  := $(shell find Caelus/Core Caelus/Render Caelus/App Caelus/Net -name '*.h' -o -name '*.hpp') CaelusTests/Core/TestSupport.hpp CaelusTests/Core/TLEFixtures.hpp

CORE_OBJ := $(patsubst Caelus/Core/%.cpp,$(BUILD)/obj/Core/%.o,$(CORE_SRC))
APP_OBJ  := $(patsubst Caelus/%.mm,$(BUILD)/obj/%.o,$(APP_SRC))
TEST_OBJ := $(patsubst CaelusTests/Core/%.cpp,$(BUILD)/obj/Tests/%.o,$(TEST_SRC))

TEXTURES := EarthDay EarthNight EarthSpecular

.PHONY: all app build run launch test clean icon

all: app

app: $(BIN)

$(BUILD)/obj/Core/%.o: Caelus/Core/%.cpp $(HEADERS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

$(BUILD)/obj/%.o: Caelus/%.mm $(HEADERS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -fobjc-arc $(INCLUDES) -c $< -o $@

$(BUILD)/obj/Tests/%.o: CaelusTests/Core/%.cpp $(HEADERS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -I CaelusTests/Core -c $< -o $@

$(BIN): $(CORE_OBJ) $(APP_OBJ)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/Textures
	$(CXX) $(CORE_OBJ) $(APP_OBJ) $(FRAMEWORKS) -o $(BIN)
	@cp Caelus/Resources/Info.plist $(APP)/Contents/Info.plist
	@for texture in $(TEXTURES); do \
	    cp "Caelus/Resources/Textures/$$texture.jpg" \
	       "$(APP)/Contents/Resources/Textures/$$texture.jpg"; \
	done
	@$(MAKE) --no-print-directory icon
	@echo "Built $(APP)"

icon: $(BUILD)/AppIcon.icns
	@cp $(BUILD)/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns

$(BUILD)/AppIcon.icns: Caelus/Resources/Icon/AppIcon.png
	@rm -rf $(BUILD)/AppIcon.iconset
	@mkdir -p $(BUILD)/AppIcon.iconset
	@sips -z 16 16 $< --out $(BUILD)/AppIcon.iconset/icon_16x16.png >/dev/null
	@sips -z 32 32 $< --out $(BUILD)/AppIcon.iconset/icon_16x16@2x.png >/dev/null
	@sips -z 32 32 $< --out $(BUILD)/AppIcon.iconset/icon_32x32.png >/dev/null
	@sips -z 64 64 $< --out $(BUILD)/AppIcon.iconset/icon_32x32@2x.png >/dev/null
	@sips -z 128 128 $< --out $(BUILD)/AppIcon.iconset/icon_128x128.png >/dev/null
	@sips -z 256 256 $< --out $(BUILD)/AppIcon.iconset/icon_128x128@2x.png >/dev/null
	@sips -z 256 256 $< --out $(BUILD)/AppIcon.iconset/icon_256x256.png >/dev/null
	@sips -z 512 512 $< --out $(BUILD)/AppIcon.iconset/icon_256x256@2x.png >/dev/null
	@sips -z 512 512 $< --out $(BUILD)/AppIcon.iconset/icon_512x512.png >/dev/null
	@cp $< $(BUILD)/AppIcon.iconset/icon_512x512@2x.png
	@iconutil -c icns $(BUILD)/AppIcon.iconset -o $@

run: $(BIN)
	@open $(APP)

# Launches the binary directly so CAELUS_* environment variables reach it.
launch: $(BIN)
	@$(BIN)

$(BUILD)/caelus-tests: $(CORE_OBJ) $(TEST_OBJ)
	$(CXX) $(CORE_OBJ) $(TEST_OBJ) -o $@

test: $(BUILD)/caelus-tests
	@$(BUILD)/caelus-tests

clean:
	@rm -rf $(BUILD)
