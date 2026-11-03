# ApexTune power controller prototype v3

This x86_64 macOS kernel extension prototype targets GenuineIntel family 6 model 0x9e. It reads package RAPL limits from MSRs 0x606 and 0x610 and changes only the PL1/PL2 power fields in 0x610. It has no generic MSR, voltage, fan, or Turbo-enable interface. Every user-client operation checks that the current calling task is an administrator/root task.

## Profiles and power-budget tiers

The 15 allowed PL1 targets are 10 through 80 W in 5 W steps. Five PL2 power-budget tiers add 0, 5, 10, 15, or 20 W to the selected PL1. Both targets are capped at 80 W and at the immutable session-start PL1/PL2 values. Near either ceiling, multiple tiers can resolve to the same PL2. For example, PL1 70 W with tier 5 resolves to PL2 80 W. A profile is rejected when PL1 is above the original PL1 or the resulting PL2 would be below PL1. These are package power limits, not GHz or a Turbo switch; they do not promise a particular frequency.

At session start the driver saves the original PL1/PL2 fields without writing the current TDP or any MSR. Later profile steps are checked against that immutable baseline, so stepping up from a previous low profile is allowed while still rejecting values above the original raw limits. The driver enforces the 80 W cap on every applied PL1 and PL2 value. PL1 and PL2 must be enabled and unlocked. The driver leaves every non-power bit as currently read and verifies the complete register after writing. On restore it reinstates the original PL1/PL2 fields, which may be above 80 W, while retaining current non-power bits.

One root-owned connection may hold a session. Beginning and updating a profile arm a 30-second watchdog; the controller sends a heartbeat every 10 seconds. Explicit finish, client close/death, timeout, and driver stop attempt to restore the original PL1/PL2 fields, merging them into current control bits. If the register becomes locked, the driver does not write and reports restoration failure. A failed readback does not create an endless retry loop.

## CLI

Build locally with `make test`. The bundle is unsigned and is not installed or loaded by these commands. The runtime v2 driver and v3 bundle are separate until an authorized external update; v2 clients are rejected by the v3 structure sizes and version checks. The v2 one-shot trial interface was migrated to v3 sessions; the CLI `trial` third argument is now a tier, not a PL2 watt value.

Read current state:

```sh
sudo build/apextune-power-probe
```

Start the interactive bounded controller:

```sh
sudo build/apextune-power-probe controller
```

Enter `status`, `set <PL1-W> <tier-1..5>`, or `finish`. The controller session begins without changing the current profile. It renews its lease while running and restores on exit or loss of connection.

Run a short fixed-duration profile trial (PL1 10..80 W by 5 W, tier 1..5):

```sh
sudo build/apextune-power-probe trial <PL1-W> <tier-1..5> <seconds-1..20>
```

This runs no workload. It prints the original, applied, and restored readbacks. A real performance/energy comparison is separate.

## Undervolt-lock status

The v3 snapshot reports undervolt-lock status as `unknown`. No voltage-control MSR is read or written. Intel's Coffee Lake family datasheet documents processor registers but does not specify a family-6/model-0x9e undervolt-lock status bit. Intel's support article describes its Undervolt Protection feature as available only on 12th-generation and newer processors; that does not identify a readable lock bit for this Coffee Lake processor. References: [Intel 8th/9th Generation Core family datasheet, Volume 2](https://cdrdv2-public.intel.com/337345/8th-gen-core-family-datasheet-vol-2.pdf), [Intel processor-family mapping for model 06_9E](https://www.intel.com/content/www/us/en/support/articles/000059422/processors.html), and [Intel Undervolt Protection overview](https://www.intel.com/content/www/us/en/support/articles/000094219/processors.html). This is not a finding that undervolting is enabled or disabled on the Mac.

## Verification limits

`make test` runs deterministic profile, bounds, malformed-header, and restore-policy tests, compiles the CLI and links an unsigned v3 kext bundle against installed Xcode kernel headers. It does not validate runtime loading or hardware behavior. No driver install/load, hardware trial, SIP change, or live undervolt check is part of this source build.
