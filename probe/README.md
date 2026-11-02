# ApexTune power probe (experimental, tightly bounded trial)

This is a narrow x86_64 Intel macOS kernel extension source prototype and CLI for inspecting package RAPL limits and running a short, temporary PL1/PL2 lowering trial. It rejects CPUs except GenuineIntel family 6 model 0x9e. Every operation requires administrator/root authorization, checked against the calling task.

The reported PL1/PL2 values are package-average CPU limits. They are not a meter for total Mac power, Radeon power, or wall-plug energy. The trial requires both limits enabled and unlocked; it only changes the PL1/PL2 power fields in MSR 0x610 and preserves every other bit. It only permits lowering from the current readback, with integer bounds 10 W ≤ PL1 ≤ PL2 ≤ 45 W and a duration of 1–10 seconds. It saves the original PL1/PL2 fields and restores those fields on explicit finish, client close/death, or a 30-second kernel watchdog. Restore merges the saved fields into the current register to preserve current control bits, then verifies the full merged readback. If the lock bit is set before restoration, it does not write and reports that restoration is blocked. A readback failure is reported and is not retried on an endless timer; explicit finish and client close/death can each make another attempt. Driver stop makes one final attempt, logs any failure, and tears down its event sources safely. One active trial is allowed per loaded v2 service. The kernel protocol version is 2, so an already loaded v1 reader will reject a trial rather than silently treating it as a v2 request.

## Build and offline checks

Run `make test` to compile the CLI, run deterministic policy/decoding fixtures, and verify malformed CLI arguments are rejected. All user-space and kernel objects are explicitly compiled for macOS 15. Run `make kext` to compile and link an unsigned x86_64 `.kext` bundle against the installed macOS kernel headers. The bundle uses Apple XNU `_start`/`_stop` glue compiled from the APSL-licensed sources noted in `APPLE_XNU_PROVENANCE.md`. The bundle is assembled locally but is not signed, installed, or loaded; package creation alone does not validate loadability. No driver is auto-loaded.

Build requires Xcode command-line tools. A live reading or trial requires a separately packaged, authorized, and loaded v2 kext. This code task does not install or load it and does not modify SIP. No hardware trial has run. Runtime hardware access, privilege transfer behavior, Sequoia compatibility, and actual restoration remain unverified.

There is no generic MSR interface. The only MSR write targets 0x610 after the trial policy accepts the request.

## Explicit short trial

`sudo build/apextune-power-probe trial <PL1-W> <PL2-W> <seconds>` requires explicit values. It has no implicit/default watt levels and starts no workload. The tool prints the prior limits, hardware readback after applying, and the restored PL1/PL2 readback. Other register bits can change during the trial and are preserved as read at restoration time. Ctrl-C or termination asks the kernel to restore immediately; the watchdog covers a disconnected CLI. If the register becomes locked before restoration, the CLI reports that it could not confirm restoration.
