#include <mach/kmod.h>

kern_return_t _start(kmod_info_t *info, void *data);
kern_return_t _stop(kmod_info_t *info, void *data);
extern kmod_start_func_t *_realmain;
extern kmod_stop_func_t *_antimain;
kmod_start_func_t *_realmain = 0;
kmod_stop_func_t *_antimain = 0;

KMOD_EXPLICIT_DECL(com_apextune_PowerReader, "1.0.0", _start, _stop)
