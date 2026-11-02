# ApexTune power probe (experimental, read-only)

This is a narrow x86_64 Intel macOS kernel extension source prototype and a CLI for inspecting the package RAPL power unit and package power limit registers. It does not change a limit. The driver only exposes a single fixed snapshot of MSR 0x606 and 0x610, and rejects CPUs except GenuineIntel family 6 model 0x9e. The IOKit client open and each snapshot operation require administrator/root authorization; snapshot calls check the current task so a connection shared with another process does not inherit open-time access.

The reported PL1/PL2 values are package-average power limits encoded by the CPU. They are not a meter for total Mac power, Radeon power, or wall-plug energy. This prototype does not verify whether firmware or other software later overwrites a limit.

## Build and offline checks

Run `make test` to compile the CLI, run deterministic decoding fixtures, and verify that a missing live driver returns an error rather than fake data. Run `make kext` to compile and link an unsigned x86_64 `.kext` bundle against the installed macOS kernel headers. The bundle is assembled locally but is not signed, installed, or loaded; package creation alone does not validate loadability. No driver is auto-loaded.

Build requires Xcode command-line tools. A live reading requires a separately packaged/authorized/loaded kext. This repository task does not install or load it and does not modify SIP. Runtime hardware access, privilege flow, Sequoia compatibility, and actual PL1/PL2 readback remain unverified.

There is no generic MSR interface and no MSR write instruction in this source.
