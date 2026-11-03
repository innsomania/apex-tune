# ApexTune automatic startup

The root LaunchDaemon runs `ApexTune --daemon` without `NSApplication`, `NSStatusBar`, or a WindowServer session. It owns the only control connection and writes a sanitized, atomically replaced JSON status file under `/Library/Application Support/ApexTune`. That directory is root-owned and not user-writable; the Aqua LaunchAgent only reads status and has no command channel.

Build and validate with `make -C app test`. After review, install from this checkout with `sudo deployment/install.sh`. The installer refuses to proceed while the legacy interactive root `--control` process is running; quit that session first. The script copies the app to `/Applications/ApexTune.app`, creates root-owned status/log directories, and bootstraps the daemon and the active console user's Aqua menu agent. Future Aqua logins load the installed agent automatically.

Check the service with `sudo launchctl print system/com.apextune.controller`. Read its bounded diagnostic log at `/Library/Logs/ApexTune/controller.log`. Remove autostart jobs with `sudo deployment/uninstall.sh`; this retains the app bundle and logs.

The daemon receives launchd `SIGTERM`, asks the probe to restore its saved PL1/PL2 limits, waits for the acknowledgement, then exits. The driver's existing lease watchdog remains the fallback if that acknowledgement fails. launchd restarts the daemon with a 30-second throttle. No driver, voltage, undervolt, or GPU behavior is installed by these scripts.

The status menu reports the CPU die sensor explicitly. A missing or older-than-four-seconds sensor sample is shown as unavailable; status heartbeat freshness is tracked separately from sensor freshness.

Apple references: [Creating launch daemons and agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html) and [Service Management](https://developer.apple.com/documentation/servicemanagement).
