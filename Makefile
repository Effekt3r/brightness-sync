LABEL  := io.github.effekt3r.brightness-sync
BINARY := $(HOME)/.local/bin/brightness-sync
PLIST  := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG    := $(HOME)/Library/Logs/brightness-sync.log
DOMAIN := gui/$(shell id -u)
MIN    ?= 0
MAX    ?= 100

.PHONY: build test install uninstall logs

build:
	swift build -c release

test:
	swift test

install: build
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	mkdir -p $(dir $(BINARY)) $(dir $(PLIST)) $(dir $(LOG))
	install -m 755 .build/release/brightness-sync $(BINARY)
	$(BINARY) --min $(MIN) --max $(MAX) --help > /dev/null
	sed -e 's|@LABEL@|$(LABEL)|' -e 's|@BINARY@|$(BINARY)|' -e 's|@LOG@|$(LOG)|' \
		-e 's|@MIN@|$(MIN)|' -e 's|@MAX@|$(MAX)|' launchd/agent.plist.in > $(PLIST)
	plutil -lint $(PLIST)
	launchctl bootstrap $(DOMAIN) $(PLIST) || { sleep 1; launchctl bootstrap $(DOMAIN) $(PLIST); }
	@echo "brightness-sync is running and starts at login. Follow it with: make logs"

uninstall:
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	rm -f $(PLIST) $(BINARY)

logs:
	tail -f $(LOG)
