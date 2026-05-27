// gcc -shared -fPIC -o libsysinfo_hook.so sysinfo_hook.c -ldl
#define _GNU_SOURCE
#include <sys/sysinfo.h>
#include <dlfcn.h>
int sysinfo(struct sysinfo *info) {
    int (*real_sysinfo)(struct sysinfo *) = dlsym(RTLD_NEXT, "sysinfo");
    int ret = real_sysinfo(info);
    if (ret == 0) {
        info->totalram += (unsigned long)1024 * 1024 * 1024 * 1024 / info->mem_unit;
    }
    return ret;
}
