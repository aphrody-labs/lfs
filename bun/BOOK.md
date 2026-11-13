# bun-LFS: Linux From Scratch, bun variant

Fork of the LFS book (`aphrody-labs/lfs`, from `git.linuxfromscratch.org/lfs.git` trunk `3ddb06703`,
2026-11-13; GitHub mirror `lfs-book/lfs` lagged 23 commits behind). This directory adds a variant whose
userspace is bun. It follows the LFS method (everything from verified upstream tarballs, book entities as
the version source of truth) but replaces the GNU userland with bun + uutils and the LFS init systems with
a bun PID 1. Measured results and comparison: `docs/lfs/BUN-LFS.md` in the src monorepo.

## 0. Versions (verified 2026-11-13)

| Component | Version | Source |
|---|---|---|
| LFS book | trunk 13.1-systemd-rc2 / sysv 12.4-rc1; last stable 13.1-systemd, 12.4 sysv | linuxfromscratch.org/lfs, `git ls-remote` (tags r13.1) |
| Linux | 7.3.4 stable (mainline 7.4-rc2; LFS trunk pins 7.3.1) | kernel.org/releases.json, sha256sums.asc |
| glibc | 2.44 | `packages.ent` glibc-version + glibc-md5 |
| bun | 1.4.4, asset `bun-linux-x64` (glibc) | github.com/oven-sh/bun releases, SHASUMS256.txt |
| uutils coreutils | aphrody-labs fork `b7df0ba` (after release 0.12.0) | src.lock.json, github.com/uutils/coreutils |
| Host toolchain | Arch: clang/lld/llvm 23.1.4, rust 1.99.1, bindgen 0.73.2, gcc 16.2.1 | `pacman -Q` in the build image |

The LFS sysvinit book is no longer maintained ("The prior System V version of LFS is no longer
maintained", lfs homepage, 2026-11-13); this variant uses neither init system.

## 1. Mapping to LFS chapters

| LFS | bun-LFS | Why |
|---|---|---|
| Ch. 2-4 host, partitions, user | Arch container (`Containerfile`) on a GitHub-hosted runner, raw ext4 image made with `mkfs.ext4 -d` | src rule: Arch/Alpine containers only; no loop mounts or root on the host |
| Ch. 5-7 cross toolchain, chroot | skipped: the container's clang/lld/rustc is the toolchain | LLVM is a native cross compiler (one binary, `--target`); the shared src LLVM toolchain (docs/llvm/UNIFIED-TOOLCHAIN.md) replaces it later |
| 8.5 Glibc | same configure as LFS (`--disable-nscd libc_cv_slibdir=/usr/lib`), GCC | glibc 2.44 INSTALL requires "GCC 12.1 or newer" and documents no clang build; bun's official glibc build needs only libc/libm/libdl/libpthread/ld-linux (`readelf -d`) |
| 8.x GNU coreutils, bash, grep, ... | uutils coreutils (static musl multicall) + Bun's built-in shell (`Bun.$`) | Rust, LLVM backend; no shell binary needed |
| 8.x GCC, binutils | not installed in the target | the target runs bun; compilers are optional packages |
| 9 sysvinit / systemd | `init/init.ts` (bun PID 1), `init/preinit.c` fallback | bun:ffi calls mount(2), sethostname(2), reboot(2) through libc |
| 10.3 Linux | 7.3.4, `make LLVM=1`, `CONFIG_RUST=y`, rust_minimal + rust_print samples built in | Documentation/kbuild/llvm.rst, Documentation/rust/quick-start.rst |
| 10.4 GRUB | none: QEMU `-kernel` direct boot; WSL uses its own kernel | minimal proof; a UKI/EFI stub is a later step |

## 2. Build

```sh
just lfs-build              # GitHub-hosted runner (.github/workflows/bunlfs.yml): Arch container, -j$(nproc)
just lfs-logs               # QEMU serial logs, boot-time and image comparisons -> docs/lfs/logs
just lfs-wsl                # Windows: wsl --import bunlfs + bun --version + proof.ts
```

`scripts/prd.sh` is a fallback for prd only: fleet heavy-job lock (`flock /var/lock/aphrody-heavy.lock`),
refuses to start above half the cores, nice 19, ionice 3, `-j2`, pauses the container when prd gets busy.

Stages (`scripts/build.sh`): `fetch` (checksums: kernel.org sha256sums, LFS md5, bun SHASUMS256),
`kernel`, `glibc`, `uutils`, `preinit`, `rootfs`, `image`. Outputs in `/work/out`: `bzImage`,
`bunlfs.raw`, `bunlfs-rootfs.tar.gz`, `SHA256SUMS`, toolchain provenance files.

## 3. Target layout

```
/usr/bin/bun            official bun 1.4.4 (to be replaced by the native AOT/LTO bun build)
/usr/bin/bunsh          login shell: each line through Bun.$ (pipes, redirections, globs, builtins)
/usr/bin/coreutils      uutils multicall + one symlink per utility
/usr/lib/               glibc 2.44 runtime only (ld-linux, libc, libm, libpthread, libdl, librt, nss)
/usr/lib/bunlfs/        init.ts (PID 1), preinit (freestanding C), proof.ts, toolchain provenance
/bin /lib /lib64 /sbin  symlinks into /usr (LFS 12+ merged-usr layout)
```

## 4. Optional packages (not in the base image)

Install into `/opt/<name>` from verified upstream archives; each one is a separate stage to add.

| Package | Version (2026-11-13) | Source | Note |
|---|---|---|---|
| Rust | 1.99.1 (Arch), nightly pinned by src | rust-lang | rustup is not used in the target |
| Zig | 0.17.1 | ziglang.org/download/index.json | GitHub releases stop at 0.15.1 (project moved off GitHub) |
| uv + CPython | uv 0.13.8, Python 3.14.10 | astral-sh/uv, python.org API | `uv python install` fetches python-build-standalone |
| .NET | 11.0 SDK 11.0.100 (active) | dotnetcli release-metadata | needs libstdc++/ICU or `InvariantGlobalization`; NativeAOT apps avoid the runtime |
| tree-sitter | 0.27.2 | tree-sitter/tree-sitter | CLI is a static Rust binary |
| LSP | clangd 23.1.0, rust-analyzer 2026-11-09, typescript-language-server via bun | upstream releases | |
| LLVM | 23.1.x | Arch / shared src toolchain | needs libstdc++ or libc++ in the target |

## 5. Later steps (documented, not built here)

- Native bun (AOT, LTO, all features) from the bun-native agent replaces `/usr/bin/bun`; bun-LFS is its boot test bed.
- Kernel and userspace with the shared src LLVM toolchain (same LLVM for clang and rustc, cross-language LTO), glibc replaced by LLVM libc or musl once bun runs on it without libstdc++.
- Chromium (fr1 only, docs/chromium), agentic stack (MCP, ACP, A2A in packages/ai-os), Rust for Linux drivers beyond the samples.
- Bootloader (UKI + EFI stub), real hardware.
