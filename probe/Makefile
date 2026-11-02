CXX ?= xcrun clang++
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
BUILD := build
BUNDLE := $(BUILD)/ApexTunePowerReader.kext
KERNEL_HEADERS := $(SDK)/System/Library/Frameworks/Kernel.framework/Headers
CXXFLAGS := -std=c++17 -Wall -Wextra -Werror -O2 -mmacosx-version-min=15.0 -isysroot $(SDK)
KEXTFLAGS := -arch x86_64 -mkernel -fapple-kext -fno-exceptions -fno-rtti \
	-fno-stack-protector -fno-builtin -nostdlib -mmacosx-version-min=15.0 -isysroot $(SDK) -I$(KERNEL_HEADERS)
KEXT_CFLAGS := -arch x86_64 -mkernel -fno-stack-protector -fno-builtin \
	-nostdlib -mmacosx-version-min=15.0 -isysroot $(SDK) -I$(KERNEL_HEADERS)

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
	@set +e; $(BUILD)/apextune-power-probe trial 1 2 >/dev/null 2>$(BUILD)/bad-args.txt; status=$$?; set -e; \
	  test $$status -eq 64; grep -q 'Usage:' $(BUILD)/bad-args.txt

kext: $(BUNDLE)/Contents/MacOS/ApexTunePowerReader

$(BUILD)/ApexTunePowerReader.o: ApexTunePowerReader.cpp power_snapshot.h | $(BUILD)
	xcrun clang++ $(KEXTFLAGS) -c $< -o $@

$(BUILD)/kmod_info.o: kmod_info.c | $(BUILD)
	xcrun clang $(KEXT_CFLAGS) -c $< -o $@

$(BUILD)/c_start.o: c_start.c | $(BUILD)
	xcrun clang $(KEXT_CFLAGS) -c $< -o $@

$(BUILD)/c_stop.o: c_stop.c | $(BUILD)
	xcrun clang $(KEXT_CFLAGS) -c $< -o $@

$(BUNDLE)/Contents/MacOS/ApexTunePowerReader: $(BUILD)/ApexTunePowerReader.o $(BUILD)/kmod_info.o $(BUILD)/c_start.o $(BUILD)/c_stop.o Info.plist
	mkdir -p $(BUNDLE)/Contents/MacOS
	xcrun clang++ $(KEXTFLAGS) -Wl,-kext -Wl,-undefined,dynamic_lookup \
	  $(BUILD)/ApexTunePowerReader.o $(BUILD)/kmod_info.o $(BUILD)/c_start.o $(BUILD)/c_stop.o -o $@
	cp Info.plist $(BUNDLE)/Contents/Info.plist

clean:
	rm -rf $(BUILD)
