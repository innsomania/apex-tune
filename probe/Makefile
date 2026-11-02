CXX ?= xcrun clang++
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
BUILD := build
BUNDLE := $(BUILD)/ApexTunePowerReader.kext
KERNEL_HEADERS := $(SDK)/System/Library/Frameworks/Kernel.framework/Headers
CXXFLAGS := -std=c++17 -Wall -Wextra -Werror -O2 -isysroot $(SDK)
KEXTFLAGS := -arch x86_64 -mkernel -fapple-kext -fno-exceptions -fno-rtti \
	-fno-stack-protector -fno-builtin -nostdlib -isysroot $(SDK) -I$(KERNEL_HEADERS)

.PHONY: all test clean kext
all: $(BUILD)/apextune-power-probe kext

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/apextune-power-probe: cli.cpp power_snapshot.h | $(BUILD)
	$(CXX) $(CXXFLAGS) -framework IOKit cli.cpp -o $@

$(BUILD)/decode-test: tests/decode_test.cpp power_snapshot.h | $(BUILD)
	$(CXX) $(CXXFLAGS) tests/decode_test.cpp -o $@

test: kext $(BUILD)/decode-test $(BUILD)/apextune-power-probe
	$(BUILD)/decode-test
	plutil -lint $(BUNDLE)/Contents/Info.plist
	@set +e; $(BUILD)/apextune-power-probe >/dev/null 2>$(BUILD)/missing-service.txt; status=$$?; set -e; \
	  test $$status -eq 69; grep -q 'No readings available' $(BUILD)/missing-service.txt

kext: $(BUNDLE)/Contents/MacOS/ApexTunePowerReader

$(BUILD)/ApexTunePowerReader.o: ApexTunePowerReader.cpp power_snapshot.h | $(BUILD)
	xcrun clang++ $(KEXTFLAGS) -c $< -o $@

$(BUILD)/kmod.o: kmod.cpp | $(BUILD)
	xcrun clang++ $(KEXTFLAGS) -c $< -o $@

$(BUNDLE)/Contents/MacOS/ApexTunePowerReader: $(BUILD)/ApexTunePowerReader.o $(BUILD)/kmod.o Info.plist
	mkdir -p $(BUNDLE)/Contents/MacOS
	xcrun clang++ $(KEXTFLAGS) -Wl,-kext -Wl,-undefined,dynamic_lookup \
	  $(BUILD)/ApexTunePowerReader.o $(BUILD)/kmod.o -L$(SDK)/usr/lib -lkmod -o $@
	cp Info.plist $(BUNDLE)/Contents/Info.plist

clean:
	rm -rf $(BUILD)
