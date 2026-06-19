# johnvideo — macOS .app bundle build
#
# Pure-C engine + Objective-C++ AppKit UI shell, linked against Homebrew FFmpeg.
#   make        build the .app bundle
#   make run    build and launch
#   make clean  remove build output

APP_NAME  := johnvideo
BUILD_DIR := build
APP_DIR   := $(BUILD_DIR)/$(APP_NAME).app
MACOS_DIR := $(APP_DIR)/Contents/MacOS
BIN       := $(MACOS_DIR)/$(APP_NAME)

# FFmpeg from Homebrew (Apple Silicon keg-only path).
FFMPEG_PREFIX := $(shell brew --prefix ffmpeg)
export PKG_CONFIG_PATH := $(FFMPEG_PREFIX)/lib/pkgconfig:$(PKG_CONFIG_PATH)
FFMPEG_LIBS := libavformat libavcodec libavutil libswscale libswresample
FFMPEG_CFLAGS := $(shell pkg-config --cflags $(FFMPEG_LIBS))
FFMPEG_LDFLAGS := $(shell pkg-config --libs $(FFMPEG_LIBS))

CC        := clang
OBJCXX    := clang++

INCLUDES  := -Isrc/engine -Isrc/ui
WARN      := -Wall -Wextra
CFLAGS    := $(WARN) -O2 -g $(INCLUDES) $(FFMPEG_CFLAGS)
OBJCXXFLAGS := $(WARN) -O2 -g -std=c++17 -fobjc-arc $(INCLUDES) $(FFMPEG_CFLAGS)
LDFLAGS   := $(FFMPEG_LDFLAGS) \
             -framework Cocoa -framework AVFoundation -framework CoreMedia \
             -framework CoreText -framework CoreGraphics -framework ImageIO \
             -framework UniformTypeIdentifiers

C_SRCS    := src/engine/timeline.c src/engine/decoder.c src/engine/export.c
MM_SRCS   := src/ui/main.mm src/ui/AppDelegate.mm src/ui/PreviewView.mm \
             src/ui/TimelineView.mm src/ui/Media.mm src/ui/AudioController.mm \
             src/ui/Project.mm

C_OBJS    := $(patsubst src/%.c,$(BUILD_DIR)/obj/%.o,$(C_SRCS))
MM_OBJS   := $(patsubst src/%.mm,$(BUILD_DIR)/obj/%.o,$(MM_SRCS))
OBJS      := $(C_OBJS) $(MM_OBJS)

.PHONY: all run clean
all: $(APP_DIR)

$(APP_DIR): $(BIN) Info.plist
	@mkdir -p $(APP_DIR)/Contents
	@cp Info.plist $(APP_DIR)/Contents/Info.plist
	@echo "APPL????" > $(APP_DIR)/Contents/PkgInfo
	@echo "Built $(APP_DIR)"

$(BIN): $(OBJS)
	@mkdir -p $(MACOS_DIR)
	$(OBJCXX) $(OBJS) $(LDFLAGS) -o $@

$(BUILD_DIR)/obj/%.o: src/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/obj/%.o: src/%.mm
	@mkdir -p $(dir $@)
	$(OBJCXX) $(OBJCXXFLAGS) -c $< -o $@

# Launch as a bundle (via open) so macOS associates Info.plist and can grant
# microphone access. Use `make run-direct` to run the raw binary for stderr logs.
run: all
	open $(APP_DIR)

run-direct: all
	$(BIN)

clean:
	rm -rf $(BUILD_DIR)
