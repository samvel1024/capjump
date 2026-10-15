APP      := build/Capjump.app
APPDIR   ?= $(HOME)/Applications
BINDIR   ?= $(HOME)/.local/bin
LABEL    := io.github.samvel1024.capjump
AGENT    := $(HOME)/Library/LaunchAgents/$(LABEL).plist
CONFIG   := $(HOME)/.config/capjump/config.json
SOURCES  := $(wildcard Sources/*.swift)

.PHONY: build install uninstall restart clean

build: $(APP)

$(APP): $(SOURCES) Resources/Info.plist
	@mkdir -p $(APP)/Contents/MacOS
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	swiftc -O -o $(APP)/Contents/MacOS/capjump $(SOURCES)
	codesign --force --sign - $(APP)

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

clean:
	rm -rf build
