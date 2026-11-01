// Temporary diagnostic for the unresolved GTNH font conversion failure.
#include <dlfcn.h>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "external/fishhook/fishhook.h"

static void (*originalMetalThrow)(void *, void *, void (*)(void *));
static atomic_uint metalThrowCount;

__attribute__((noreturn))
static void traceMetalThrow(void *exception, void *type, void (*destroy)(void *)) {
    if (atomic_fetch_add(&metalThrowCount, 1) < 4) {
        void *frames[32];
        int count = backtrace(frames, 32);
        fprintf(stderr, "[Amethyst Metal exception] frames=%d\n", count);
        for (int i = 0; i < count; ++i) {
            Dl_info info = {0};
            if (dladdr(frames[i], &info) && info.dli_fname && info.dli_fbase) {
                const char *name = strrchr(info.dli_fname, '/');
                fprintf(stderr, "[Amethyst Metal frame] %d %s +0x%lx\n", i,
                        name ? name + 1 : info.dli_fname,
                        (unsigned long)((uintptr_t)frames[i] - (uintptr_t)info.dli_fbase));
            }
        }
    }
    originalMetalThrow(exception, type, destroy);
    __builtin_unreachable();
}

static void traceMetalImage(const struct mach_header *header, intptr_t slide) {
    Dl_info info = {0};
    if (!dladdr(header, &info) || !info.dli_fname) return;
    const char *name = strrchr(info.dli_fname, '/');
    if (strcmp(name ? name + 1 : info.dli_fname, "libMoltenVK.dylib") != 0) return;
    struct rebinding binding = {"__cxa_throw", (void *)traceMetalThrow, NULL};
    int result = rebind_symbols_image((void *)header, slide, &binding, 1);
    fprintf(stderr, "[Amethyst Metal trace] installed for MoltenVK; result=%d\n", result);
}

__attribute__((constructor))
static void installMetalConversionTrace(void) {
    originalMetalThrow = dlsym(RTLD_DEFAULT, "__cxa_throw");
    if (originalMetalThrow) _dyld_register_func_for_add_image(traceMetalImage);
}
