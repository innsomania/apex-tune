#include <mach/kmod.h>

extern "C" {
kern_return_t _start(kmod_info_t *info, void *data);
kern_return_t _stop(kmod_info_t *info, void *data);
// The standard libkmod start/stop glue calls these optional driver hooks.
kmod_start_func_t *_realmain = nullptr;
kmod_stop_func_t *_antimain = nullptr;
}

KMOD_EXPLICIT_DECL(com_apextune_PowerReader, "1.0.0", _start, _stop)
