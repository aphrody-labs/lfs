#!/bin/sh
# bun-LFS build, run inside the Arch container (bun/Containerfile) with /work mounted.
# Usage: build.sh [fetch|kernel|glibc|uutils|preinit|rootfs|image|all]
# Every stage is idempotent and logs to /work/log/<stage>.log.
set -eu

: "${JOBS:=4}"
: "${LINUX_VERSION:=7.3.4}"
: "${GLIBC_VERSION:=2.44}"
: "${GLIBC_MD5:=7677da43ef759c68e005f5d4c37986a6}" # packages.ent glibc-md5
: "${BUN_VERSION:=1.4.4}"
: "${BUN_ASSET:=bun-linux-x64}"                   # glibc build; bun-linux-x64-musl needs libstdc++
: "${UUTILS_REPO:=https://github.com/aphrody-labs/uutils-coreutils.git}"
: "${UUTILS_REV:=b7df0ba}"

W=/work
BUNDIR=$(cd "$(dirname "$0")/.." && pwd)
SRC=$W/src OUT=$W/out LOG=$W/log ROOT=$W/rootfs
mkdir -p "$SRC" "$OUT" "$LOG"
N="nice -n 19"

stage_fetch() {
  cd "$SRC"
  [ -f "linux-$LINUX_VERSION.tar.xz" ] || curl -fsSLO "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$LINUX_VERSION.tar.xz"
  curl -fsSL https://cdn.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc | grep " linux-$LINUX_VERSION.tar.xz\$" | sha256sum -c -
  [ -f "glibc-$GLIBC_VERSION.tar.xz" ] || curl -fsSLO "https://ftp.gnu.org/gnu/glibc/glibc-$GLIBC_VERSION.tar.xz"
  echo "$GLIBC_MD5  glibc-$GLIBC_VERSION.tar.xz" | md5sum -c -
  [ -f "$BUN_ASSET.zip" ] || curl -fsSLO "https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/$BUN_ASSET.zip"
  curl -fsSL "https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/SHASUMS256.txt" | grep " $BUN_ASSET.zip\$" | sha256sum -c -
  [ -d uutils ] || git clone -q "$UUTILS_REPO" uutils
  git -C uutils checkout -q "$UUTILS_REV"
}

stage_kernel() {
  cd "$SRC"
  [ -d "linux-$LINUX_VERSION" ] || tar xf "linux-$LINUX_VERSION.tar.xz"
  cd "linux-$LINUX_VERSION"
  K="make LLVM=1 -j$JOBS"
  $N $K rustavailable
  $N $K x86_64_defconfig kvm_guest.config
  scripts/kconfig/merge_config.sh -m .config "$BUNDIR/kernel.fragment"
  $N $K olddefconfig
  grep -q '^CONFIG_RUST=y' .config || { echo "CONFIG_RUST not enabled"; exit 1; }
  $N $K bzImage
  cp arch/x86/boot/bzImage "$OUT/bzImage"
  cp .config "$OUT/kernel.config"
  # Toolchain provenance recorded into the image (clang, ld.lld, rustc of this build).
  { clang --version | head -1; ld.lld --version; rustc -vV; bindgen --version; } > "$OUT/kernel-toolchain.txt"
}

stage_glibc() {
  # LFS 8.5 glibc, built with GCC: glibc is the one component that is not built by clang here.
  cd "$SRC"
  rm -rf "glibc-$GLIBC_VERSION" glibc-build glibc-dest
  tar xf "glibc-$GLIBC_VERSION.tar.xz"
  mkdir glibc-build && cd glibc-build
  echo "rootsbindir=/usr/sbin" > configparms
  $N "../glibc-$GLIBC_VERSION/configure" --prefix=/usr --disable-werror --disable-nscd \
    --enable-kernel=5.4 --enable-stack-protector=strong libc_cv_slibdir=/usr/lib
  $N make -j"$JOBS"
  make DESTDIR="$SRC/glibc-dest" install
  gcc --version | head -1 > "$OUT/glibc-toolchain.txt"
}

stage_uutils() {
  # uutils coreutils (Rust, LLVM backend), static musl multicall binary: no runtime dependency.
  cd "$SRC/uutils"
  $N cargo build --release --locked -j "$JOBS" --target x86_64-unknown-linux-musl --features unix
  cp target/x86_64-unknown-linux-musl/release/coreutils "$OUT/coreutils"
  rustc -vV > "$OUT/uutils-toolchain.txt"
}

stage_preinit() {
  clang --target=x86_64-unknown-linux-gnu -std=c23 -static -nostdlib -ffreestanding -fno-stack-protector -O2 -fuse-ld=lld \
    -o "$OUT/preinit" "$BUNDIR/init/preinit.c"
}

stage_rootfs() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT"/usr/bin "$ROOT"/usr/sbin "$ROOT"/usr/lib/bunlfs "$ROOT"/etc \
    "$ROOT"/proc "$ROOT"/sys "$ROOT"/dev "$ROOT"/run "$ROOT"/tmp "$ROOT"/root "$ROOT"/var/log
  ln -s usr/bin "$ROOT/bin"; ln -s usr/lib "$ROOT/lib"; ln -s usr/sbin "$ROOT/sbin"; ln -s usr/lib "$ROOT/lib64"
  chmod 1777 "$ROOT/tmp"
  # glibc runtime only (no headers, static archives, locales, gconv, tools).
  for f in ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 \
           libresolv.so.2 libnss_files.so.2 libnss_dns.so.2 libutil.so.1; do
    cp -L "$SRC/glibc-dest/usr/lib/$f" "$ROOT/usr/lib/$f"
  done
  strip --strip-unneeded "$ROOT"/usr/lib/*.so* 2>/dev/null || true
  # bun, the userspace.
  rm -rf "$SRC/$BUN_ASSET"; (cd "$SRC" && unzip -oq "$BUN_ASSET.zip")
  install -m755 "$SRC/$BUN_ASSET/bun" "$ROOT/usr/bin/bun"
  ln -s bun "$ROOT/usr/bin/bunx"
  install -m755 "$BUNDIR/init/bunsh.ts" "$ROOT/usr/bin/bunsh"
  install -m755 "$BUNDIR/init/init.ts" "$ROOT/usr/lib/bunlfs/init.ts"
  install -m644 "$BUNDIR/proof/proof.ts" "$ROOT/usr/lib/bunlfs/proof.ts"
  install -m755 "$OUT/preinit" "$ROOT/usr/lib/bunlfs/preinit"
  ln -s ../lib/bunlfs/init.ts "$ROOT/usr/sbin/init"
  # uutils multicall + one symlink per utility.
  install -m755 "$OUT/coreutils" "$ROOT/usr/bin/coreutils"
  for u in $("$OUT/coreutils" --list); do
    [ "$u" = coreutils ] || [ "$u" = "[" ] || ln -sf coreutils "$ROOT/usr/bin/$u"
  done
  cp "$OUT"/*-toolchain.txt "$ROOT/usr/lib/bunlfs/"
  cat > "$ROOT/etc/os-release" <<EOF
NAME="bun-LFS"
ID=bunlfs
ID_LIKE=lfs
VERSION_ID=0.1
PRETTY_NAME="bun-LFS 0.1 (LFS $(sed -n 's/.*ENTITY version *"\(.*\)".*/\1/p' "$BUNDIR/../general.ent" | head -1) fork, Linux $LINUX_VERSION, glibc $GLIBC_VERSION, bun $BUN_VERSION)"
HOME_URL="https://github.com/aphrody-labs/lfs"
EOF
  printf 'root:x:0:0:root:/root:/usr/bin/bunsh\n' > "$ROOT/etc/passwd"
  printf 'root:x:0:\n' > "$ROOT/etc/group"
  printf 'bunlfs\n' > "$ROOT/etc/hostname"
  printf '127.0.0.1 localhost bunlfs\n::1 localhost\n' > "$ROOT/etc/hosts"
  printf 'passwd: files\ngroup: files\nhosts: files dns\n' > "$ROOT/etc/nsswitch.conf"
  printf '/usr/bin/bunsh\n' > "$ROOT/etc/shells"
  printf '[boot]\nsystemd=false\n[user]\ndefault=root\n[interop]\nappendWindowsPath=false\n' > "$ROOT/etc/wsl.conf"
  tar --numeric-owner --owner=0 --group=0 -C "$ROOT" -czf "$OUT/bunlfs-rootfs.tar.gz" .
  du -sb "$ROOT" | cut -f1 > "$OUT/rootfs-bytes.txt"
  (cd "$ROOT" && find . -type f -o -type l | sort) > "$OUT/rootfs-files.txt"
}

stage_image() {
  rm -f "$OUT/bunlfs.raw"
  truncate -s 512M "$OUT/bunlfs.raw"
  mkfs.ext4 -q -L bunlfs -E root_owner=0:0 -d "$ROOT" "$OUT/bunlfs.raw"
  (cd "$OUT" && sha256sum bzImage bunlfs.raw bunlfs-rootfs.tar.gz > SHA256SUMS)
}

run() { s=$1; echo "== $s $(date -u +%FT%TZ)"; "stage_$s" > "$LOG/$s.log" 2>&1 || { tail -40 "$LOG/$s.log"; exit 1; }; echo "== $s ok $(date -u +%FT%TZ)"; }

case "${1:-all}" in
  all) for s in fetch kernel glibc uutils preinit rootfs image; do run $s; done ;;
  *) for s in "$@"; do run "$s"; done ;;
esac
