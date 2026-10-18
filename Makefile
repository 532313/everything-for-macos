# Everything for macOS — convenience targets.
# `make` alone builds the app bundle and the CLI.

SHELL := /bin/bash
ROOT  := $(shell pwd)
TMPDIR_OVERRIDE := TMPDIR="$(ROOT)/.buildtmp"
INDEX_DIR ?= $(HOME)/Library/Application Support/Everything
# Where the CLI goes: the first PATH directory the current user can actually
# write to (no sudo needed).
BIN_DIR ?= $(shell for d in /usr/local/bin /opt/homebrew/bin $(HOME)/.local/bin; do \
	if [ -w "$$d" ] || [ ! -e "$$d" ]; then echo "$$d"; break; fi; done)

.PHONY: all build run test verify tools cli clean install help

SWIFT_TOOL_FLAGS = -O -swift-version 5 -module-cache-path "$(ROOT)/.modulecache"

define compile_tool
	@mkdir -p "$(ROOT)/build" "$(ROOT)/.buildtmp" "$(ROOT)/.modulecache"
	$(TMPDIR_OVERRIDE) swiftc $(SWIFT_TOOL_FLAGS) $(2) -o "$(ROOT)/build/$(1)"
endef

all: build

build:
	./build.sh

## Launch the app (builds first).
run: build
	open "$(ROOT)/build/Everything.app"

## 68 assertion self test over a synthetic tree (queries, increments, cache).
test: build
	"$(ROOT)/build/everything-cli" --selftest

## Build every developer tool (binaries are disposable: build/ is gitignored).
tools:
	$(call compile_tool,everything-verify,Sources/Core/*.swift Tools/verify/main.swift)
	$(call compile_tool,everything-thumb,Sources/Core/FSEntry.swift Sources/Core/FileIndex.swift Sources/Core/Walker.swift Tools/thumb/main.swift -framework AVFoundation -framework QuickLookThumbnailing)
	$(call compile_tool,everything-winlist,-framework CoreGraphics Tools/winlist/main.swift)
	@echo "built: build/everything-verify build/everything-thumb build/everything-winlist"

## Structural check of the live on-disk index cache.
verify: tools
	@"$(ROOT)/build/everything-verify" "$(INDEX_DIR)"

## Rebuild the index from scratch with the CLI (progress on stderr).
cli: build
	"$(ROOT)/build/everything-cli" --rebuild -n 10 "$(Q)"

## Install as a standalone app: /Applications/Everything.app + CLI on PATH.
## After this the app is fully independent of this source tree.
install: build
	@echo "==> /Applications/Everything.app"
	rm -rf "/Applications/Everything.app"
	cp -R "$(ROOT)/build/Everything.app" /Applications/
	-xattr -dr com.apple.quarantine "/Applications/Everything.app" 2>/dev/null || true
	@echo "==> $(BIN_DIR)/everything"
	@mkdir -p "$(BIN_DIR)"
	install -m 0755 "$(ROOT)/build/everything-cli" "$(BIN_DIR)/everything"
	@echo ""
	@echo "Installed:"
	@echo "  /Applications/Everything.app      (double-click, Spotlight, Launchpad)"
	@echo "  $(BIN_DIR)/everything$(shell printf '%*s' $$((28 - $${#BIN_DIR} - 11)) '') (CLI: everything 'ext:swift')"
	@echo "  index cache: ~/Library/Application Support/Everything/"
	@echo ""
	@echo "The source tree is no longer needed to run it."

clean:
	rm -rf "$(ROOT)/build" "$(ROOT)/.modulecache" "$(ROOT)/.buildtmp"

help:
	@echo "make build    build Everything.app + everything-cli"
	@echo "make run      build and launch the app"
	@echo "make test     68-assertion self test"
	@echo "make verify   structural check of the index cache"
	@echo "make tools    rebuild the developer tools (verify/thumb/winlist)"
	@echo "make cli Q=query   search from the command line"
	@echo "make install  copy the app to /Applications"
	@echo "make clean    remove build products"
