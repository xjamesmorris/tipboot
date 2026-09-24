#ifndef TIPBOOT_KERNEL_RELEASE
#error "TIPBOOT_KERNEL_RELEASE must be supplied by scripts/build-initramfs"
#endif

typedef unsigned long usize;

enum {
    SYS_WRITE = 64,
    SYS_SYNC = 81,
    SYS_REBOOT = 142,
};

enum {
    STDOUT_FILENO = 1,
    LINUX_REBOOT_MAGIC1 = 0xfee1dead,
    LINUX_REBOOT_MAGIC2 = 0x28121969,
    LINUX_REBOOT_CMD_POWER_OFF = 0x4321fedc,
};

static inline __attribute__((always_inline)) long syscall0(long number)
{
    register long x0 __asm__("x0");
    register long x8 __asm__("x8") = number;

    __asm__ volatile("svc #0"
                     : "=r"(x0)
                     : "r"(x8)
                     : "cc", "memory");
    return x0;
}

static inline __attribute__((always_inline)) long syscall3(
    long number, long arg0, long arg1, long arg2)
{
    register long x0 __asm__("x0") = arg0;
    register long x1 __asm__("x1") = arg1;
    register long x2 __asm__("x2") = arg2;
    register long x8 __asm__("x8") = number;

    __asm__ volatile("svc #0"
                     : "+r"(x0)
                     : "r"(x1), "r"(x2), "r"(x8)
                     : "cc", "memory");
    return x0;
}

static inline __attribute__((always_inline)) long syscall4(
    long number, long arg0, long arg1, long arg2, long arg3)
{
    register long x0 __asm__("x0") = arg0;
    register long x1 __asm__("x1") = arg1;
    register long x2 __asm__("x2") = arg2;
    register long x3 __asm__("x3") = arg3;
    register long x8 __asm__("x8") = number;

    __asm__ volatile("svc #0"
                     : "+r"(x0)
                     : "r"(x1), "r"(x2), "r"(x3), "r"(x8)
                     : "cc", "memory");
    return x0;
}

static inline __attribute__((always_inline)) void write_all(
    const char *buffer, usize length)
{
    while (length != 0) {
        long written = syscall3(
            SYS_WRITE,
            STDOUT_FILENO,
            (long)(usize)buffer,
            (long)length);

        if (written <= 0) {
            return;
        }

        buffer += (usize)written;
        length -= (usize)written;
    }
}

__attribute__((noreturn, section(".text.start"))) void _start(void)
{
    static const char marker[] =
        "TIPBOOT_OK kernel_release=" TIPBOOT_KERNEL_RELEASE "\n";

    write_all(marker, sizeof(marker) - 1);
    (void)syscall0(SYS_SYNC);
    (void)syscall4(
        SYS_REBOOT,
        LINUX_REBOOT_MAGIC1,
        LINUX_REBOOT_MAGIC2,
        LINUX_REBOOT_CMD_POWER_OFF,
        0);

    for (;;) {
        __asm__ volatile("wfe" ::: "memory");
    }
}
