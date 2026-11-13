// bun-LFS proof script: identical on QEMU (called by init.ts) and WSL (`wsl -d bunlfs -e bun ...`).
// Prints one `key=value` line per fact so logs can be diffed and grepped.
import { dlopen, FFIType } from "bun:ffi";
import { readFileSync, readdirSync } from "node:fs";

const read = (p: string) => {
  try {
    return readFileSync(p, "utf8").trim();
  } catch {
    return "n/a";
  }
};

export async function proof(): Promise<Record<string, string>> {
  const libc = dlopen("libc.so.6", { gnu_get_libc_version: { args: [], returns: FFIType.cstring } });
  const osRelease = Object.fromEntries(
    read("/etc/os-release")
      .split("\n")
      .filter((l) => l.includes("="))
      .map((l) => {
        const [k, ...v] = l.split("=");
        return [k, v.join("=").replace(/^"|"$/g, "")];
      }),
  );
  const facts: Record<string, string> = {
    os: `${osRelease.PRETTY_NAME ?? "?"}`,
    kernel: read("/proc/sys/kernel/osrelease"),
    kernel_version: read("/proc/version"),
    libc: `glibc ${libc.symbols.gnu_get_libc_version()}`,
    bun: `${Bun.version} (${Bun.revision})`,
    pid: String(process.pid),
    cpus: String(navigator.hardwareConcurrency),
    uptime_s: read("/proc/uptime").split(" ")[0],
    usr_bin_entries: String(readdirSync("/usr/bin").length),
  };
  libc.close();
  // uutils coreutils through Bun's built-in shell (no /bin/sh in this system).
  facts.uutils = (await Bun.$`ls --version`.nothrow().text()).split("\n")[0];
  facts.uname = (await Bun.$`uname -srm`.nothrow().text()).trim();
  facts.sha256_of_hello = new Bun.CryptoHasher("sha256").update("hello from bun-LFS").digest("hex");
  const t = performance.now();
  let x = 0;
  for (let i = 0; i < 5e7; i++) x = (x + i * 31) | 0;
  facts.loop_5e7_ms = (performance.now() - t).toFixed(1);
  facts.loop_checksum = String(x);
  return facts;
}

if (import.meta.main) {
  for (const [k, v] of Object.entries(await proof())) console.log(`${k}=${v}`);
  console.log("BUNLFS-PROOF-OK");
}
