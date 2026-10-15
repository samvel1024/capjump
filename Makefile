APP      := build/Capjump.app
APPDIR   ?= $(HOME)/Applications
BINDIR   ?= $(HOME)/.local/bin
LABEL    := io.github.samvel1024.capjump
AGENT    := $(HOME)/Library/LaunchAgents/$(LABEL).plist
CONFIG   := $(HOME)/.config/capjump/config.json
SOURCES  := $(wildcard Sources/*.swift)

.PHONY: build install uninstall restart clean icon

build: $(APP)

$(APP): $(SOURCES) Resources/Info.plist Resources/AppIcon.icns
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	swiftc -O -o $(APP)/Contents/MacOS/capjump $(SOURCES)
	@# Ad-hoc signatures default to a cdhash requirement, so every rebuild
	@# looks like a new app to macOS privacy settings and loses its
	@# Accessibility grant. Pin the requirement to the bundle id instead.
	codesign --force --sign - -r='designated => identifier "$(LABEL)"' $(APP)

install: build
	@mkdir -p $(APPDIR) $(BINDIR) $(dir $(AGENT)) $(dir $(CONFIG))
	rm -rf $(APPDIR)/Capjump.app
	cp -R $(APP) $(APPDIR)/Capjump.app
	ln -sf $(APPDIR)/Capjump.app/Contents/MacOS/capjump $(BINDIR)/capjump
	@test -e $(CONFIG) || cp config.example.json $(CONFIG)
	sed 's|@BIN@|$(APPDIR)/Capjump.app/Contents/MacOS/capjump|' Resources/launchd.plist > $(AGENT)
	@launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(AGENT)
	@echo "Capjump installed and running. Config: $(CONFIG)"

restart:
	launchctl kickstart -k gui/$$(id -u)/$(LABEL)

uninstall:
	@launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -f $(AGENT) $(BINDIR)/capjump
	rm -rf $(APPDIR)/Capjump.app
	@echo "Removed Capjump (config left at $(CONFIG))"

# Regenerate the app icon and README logo from docs/logo.svg.
icon:
	@mkdir -p build/AppIcon.iconset
	swiftc -O -o build/svg2png Scripts/svg2png.swift
	for s in 16 32 128 256 512; do \
		build/svg2png docs/logo.svg build/AppIcon.iconset/icon_$${s}x$${s}.png $$s; \
		build/svg2png docs/logo.svg build/AppIcon.iconset/icon_$${s}x$${s}@2x.png $$((s * 2)); \
	done
	iconutil -c icns -o Resources/AppIcon.icns build/AppIcon.iconset
	build/svg2png docs/logo.svg docs/logo.png 256

clean:
	rm -rf build
