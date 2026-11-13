// bun-LFS preinit: fallback PID 1 for kernels/configs where bun cannot start before /proc exists.
// Freestanding (no libc): mounts the API filesystems with raw x86_64 syscalls, then execs
// bun on /usr/lib/bunlfs/init.ts. Build: clang -static -nostdlib -ffreestanding -O2 -fuse-ld=lld.
typedef __INTPTR_TYPE__ sptr; // pointer-sized on every ABI (long is 32-bit on LLP64 hosts)
typedef __SIZE_TYPE__ usize;

static sptr sys6(sptr n, sptr a, sptr b, sptr c, sptr d, sptr e) {
  sptr r;
  register sptr r10 __asm__("r10") = d;
  register sptr r8 __asm__("r8") = e;
  __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
  return r;
}

enum { SYS_write = 1, SYS_pause = 34, SYS_execve = 59, SYS_mkdir = 83, SYS_mount = 165 };

static void say(const char *s) {
  usize n = 0;
  while (s[n]) n++;
  sys6(SYS_write, 2, (sptr)s, (sptr)n, 0, 0);
}

static void mnt(const char *src, const char *dst, const char *fs) {
  sys6(SYS_mkdir, (sptr)dst, 0755, 0, 0, 0);
  sys6(SYS_mount, (sptr)src, (sptr)dst, (sptr)fs, 0, 0);
}

__attribute__((force_align_arg_pointer, noreturn)) void _start(void) {
  mnt("proc", "/proc", "proc");
  mnt("sysfs", "/sys", "sysfs");
  mnt("devtmpfs", "/dev", "devtmpfs");
  mnt("tmpfs", "/run", "tmpfs");
  mnt("tmpfs", "/tmp", "tmpfs");
  say("bunlfs-preinit: api filesystems mounted, exec bun\n");
  const char *argv[] = {"/usr/bin/bun", "/usr/lib/bunlfs/init.ts", 0};
  const char *envp[] = {"HOME=/root", "PATH=/usr/bin:/usr/sbin", "TERM=linux", "BUNLFS_PREINIT=1", 0};
  sys6(SYS_execve, (sptr)argv[0], (sptr)argv, (sptr)envp, 0, 0);
  say("bunlfs-preinit: execve(/usr/bin/bun) failed\n");
  for (;;) sys6(SYS_pause, 0, 0, 0, 0, 0); // PID 1 must not exit
}
