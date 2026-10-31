LABEL  := io.github.effekt3r.brightness-sync
BINARY := $(HOME)/.local/bin/brightness-sync
PLIST  := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG    := $(HOME)/Library/Logs/brightness-sync.log
DOMAIN := gui/$(shell id -u)
MIN    := 0
MAX    := 100
DIM_BELOW := 0.15

.PHONY: build test install uninstall logs

build:
	swift build -c release

test:
	swift test

# The first line validates the options before the running agent is touched.
install: build
	.build/release/brightness-sync --min $(MIN) --max $(MAX) --dim-below $(DIM_BELOW) --help > /dev/null
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	mkdir -p $(dir $(BINARY)) $(dir $(PLIST)) $(dir $(LOG))
	install -m 755 .build/release/brightness-sync $(BINARY)
	sed -e 's|@LABEL@|$(LABEL)|' -e 's|@BINARY@|$(BINARY)|' -e 's|@LOG@|$(LOG)|' \
		-e 's|@MIN@|$(MIN)|' -e 's|@MAX@|$(MAX)|' -e 's|@DIM_BELOW@|$(DIM_BELOW)|' launchd/agent.plist.in > $(PLIST)
	plutil -lint $(PLIST)
	launchctl bootstrap $(DOMAIN) $(PLIST) || { sleep 1; launchctl bootstrap $(DOMAIN) $(PLIST); }
	@echo "brightness-sync is running and starts at login. Follow it with: make logs"

uninstall:
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	rm -f $(PLIST) $(BINARY)

logs:
	tail -F $(LOG)
