SWIFTC := xcrun swiftc
BUILD := build
APP := $(BUILD)/ApexTune.app
CONTENTS := $(APP)/Contents
RESOURCES := $(CONTENTS)/Resources
MACOS := $(CONTENTS)/MacOS
PROBE := ../probe/build/apextune-power-probe
SWIFTFLAGS := -swift-version 6 -target x86_64-apple-macosx15.0 -O

.PHONY: all app test clean
all: app

app: $(MACOS)/ApexTune

$(MACOS)/ApexTune: ApexTuneApp.swift Policy.swift Simulation.swift Info.plist $(PROBE)
	mkdir -p $(MACOS) $(RESOURCES)
	$(SWIFTC) $(SWIFTFLAGS) ApexTuneApp.swift Policy.swift Simulation.swift -framework AppKit -o $@
	cp Info.plist $(CONTENTS)/Info.plist
	cp $(PROBE) $(RESOURCES)/apextune-power-probe

$(PROBE):
	$(MAKE) -C ../probe all

$(BUILD)/policy-tests: Tests.swift Policy.swift Simulation.swift | $(BUILD)
	$(SWIFTC) $(SWIFTFLAGS) Tests.swift Policy.swift Simulation.swift -o $@

$(BUILD):
	mkdir -p $(BUILD)

test: app $(BUILD)/policy-tests
	plutil -lint $(CONTENTS)/Info.plist
	test -x $(MACOS)/ApexTune -a -x $(RESOURCES)/apextune-power-probe
	$(BUILD)/policy-tests
	$(MACOS)/ApexTune --simulate | grep -q 'SIMULATION ONLY'

clean:
	rm -rf $(BUILD)
