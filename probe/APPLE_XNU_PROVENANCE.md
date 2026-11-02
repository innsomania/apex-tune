# Apple XNU kmod glue provenance

`c_start.c` and `c_stop.c` are copied from Apple’s open source XNU kmod glue, with their original Apple copyright and Apple Public Source License 2.0 notices preserved.

Source revision: `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea` (2026-11-02)

- https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/libkern/kmod/c_start.c
- https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/libkern/kmod/c_stop.c
- https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/libkern/kmod/cplus_start.c

The start/stop glue invokes optional `_realmain` and `_antimain` hooks if present. They are null in ApexTune. C++ metaclass construction/finalization belongs to the kernel’s C++ kext runtime lifecycle; these glue routines only implement the module’s optional start/stop callbacks. The installed SDK’s static `libkmod.a` objects target macOS 26.2, so the build compiles Apple’s small C glue sources locally with the project’s macOS 15 target instead of linking that SDK archive. The kernel SDK’s `libkmodc++.a` archive has no symbols in its shipped x86_64 members; runtime kext loading is not tested here.
