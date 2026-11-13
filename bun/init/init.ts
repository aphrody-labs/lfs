#!/usr/bin/bun
// bun-LFS PID 1. Replaces LFS sysvinit/systemd: mounts the API filesystems through libc
// (bun:ffi -> mount(2)), names the host, runs the proof, then powers off (or opens bunsh
// when the kernel command line contains `bunlfs.shell`).
import { dlopen, FFIType } from "bun:ffi";
import { mkdirSync, readFileSync } from "node:fs";
import { proof } from "/usr/lib/bunlfs/proof.ts";

const t0 = performance.now();
const libc = dlopen("libc.so.6", {
  mount: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.u64, FFIType.ptr], returns: FFIType.i32 },
  sethostname: { args: [FFIType.ptr, FFIType.u64], returns: FFIType.i32 },
  reboot: { args: [FFIType.i32], returns: FFIType.i32 },
  sync: { args: [], returns: FFIType.void },
});
const c = (s: string) => Buffer.from(`${s}\0`);

for (const [src, dst, fs] of [
  ["proc", "/proc", "proc"],
  ["sysfs", "/sys", "sysfs"],
  ["devtmpfs", "/dev", "devtmpfs"],
  ["tmpfs", "/run", "tmpfs"],
  ["tmpfs", "/tmp", "tmpfs"],
]) {
  mkdirSync(dst, { recursive: true });
  // EBUSY when the kernel (DEVTMPFS_MOUNT) or preinit already mounted it: fine.
  libc.symbols.mount(c(src), c(dst), c(fs), 0n, null);
}
const host = "bunlfs";
libc.symbols.sethostname(c(host), BigInt(host.length));

console.log(`BUNLFS-INIT pid=${process.pid} preinit=${process.env.BUNLFS_PREINIT ?? "0"} init_ms=${(performance.now() - t0).toFixed(1)}`);
for (const [k, v] of Object.entries(await proof())) console.log(`${k}=${v}`);
console.log("BUNLFS-PROOF-OK");

const cmdline = readFileSync("/proc/cmdline", "utf8");
if (cmdline.includes("bunlfs.shell")) {
  const sh = Bun.spawn(["/usr/bin/bun", "/usr/bin/bunsh"], { stdio: ["inherit", "inherit", "inherit"] });
  await sh.exited;
}
console.log("BUNLFS-POWEROFF");
libc.symbols.sync();
libc.symbols.reboot(0x4321fedc); // LINUX_REBOOT_CMD_POWER_OFF
