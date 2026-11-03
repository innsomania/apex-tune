# ApexTune macOS controller

A native Swift 6.2.4 / AppKit menu bar app for macOS 15 and Intel x86_64. Build the unsigned local bundle and offline checks with:

```sh
make -C app test
```

The app bundle is `app/build/ApexTune.app`. It includes the version 3 power-probe CLI as a resource. Building does not install or load the kext, invoke administrator access, or write hardware settings.

## Observe mode

Launch `app/build/ApexTune.app` normally, or run its executable directly. It reads CPU utilization from Mach host statistics and thermal state from `ProcessInfo`. It shows a **proposed** profile derived from those measurements. It does not connect to the power driver or read/change PL1/PL2. Actual limits are shown as unavailable in observe mode. Temperature and package watts are unavailable until explicit control mode because those readings come from `powermetrics`.

## Explicit automatic control mode

Control requires the user to launch the app executable explicitly as root:

```sh
sudo app/build/ApexTune.app/Contents/MacOS/ApexTune --control
```

This starts `/usr/bin/powermetrics` and a bundled CLI child. It requires a working `ApexTunePowerReader` v3 service already available; the app never installs or loads a driver and never asks for privilege escalation. The probe takes a read-only baseline at session start. After valid, recent CPU load, Intel package power, CPU temperature, and thermal state are available, the controller sends allowed PL1/tier commands over one persistent CLI connection. It verifies each returned readback before labeling it applied. The menu keeps proposed and actual readback fields separate.

The automatic policy uses 15 integer PL1 values from 10 to 80 W in 5 W steps and five PL2 tiers adding 0/5/10/15/20 W. Both targets stay at or below 80 W and the saved session-start limits. When demand rises, the controller can start after one sample and steps by at most 10 W on each of PL1 and PL2 per acknowledged update, at most once per second. Routine reductions require five consistent samples across at least five seconds; a serious thermal state, CPU temperature of at least 85 °C, or package power of at least 75 W shortens that to two samples. Critical thermal state releases the session. Provisional load bands and reductions beginning at 80/85/90 °C and 65/75 W package power are starting points for measurement, not tuned performance recommendations. Aggregate CPU load cannot identify which app is sensitive to latency or determine whether the whole interface feels fluent. The controller makes no frequency or fluency guarantee.

If a required sample becomes stale or missing, powermetrics exits, the CLI disconnects, a profile/heartbeat acknowledgement times out, or thermal state becomes critical, the app sends `finish` and closes the child connection on timeout. The kernel session watchdog remains the final cleanup path if the app or child disappears. Driver restoration failures are reported to standard error. A failed restore cannot be represented as success by the app.

The app controls package PL1/PL2 only. It does not control the Radeon GPU separately, fans, voltage, or undervolting. Undervolt-lock status remains unknown and unsupported; no voltage register is read or written. A fractional watt/temperature value in the menu is a sensor measurement. Every requested power target is an integer number of watts.

## Offline simulation

```sh
app/build/ApexTune.app/Contents/MacOS/ApexTune --simulate
```

This prints labeled synthetic idle, burst, cooling, stale-sensor, baseline-refusal, and critical-thermal scenarios. It does not access IOKit, powermetrics, the driver, or an MSR. `make -C app test` checks the 15-by-5 profile map, bounds, policy, sensor parsing, hysteresis, stale/critical cleanup, proposal/readback separation with an injected mock probe, and the simulation entry point. It cannot validate the GUI, installed driver, runtime sensor permissions, hardware response, or performance/energy benefit.
