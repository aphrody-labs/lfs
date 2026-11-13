#!/bin/sh
# Boot the bun-LFS disk image in QEMU (TCG: prd has no /dev/kvm) on a serial console.
# Usage: boot.sh [bun|preinit] ; writes /work/log/qemu-<mode>.log with host timestamps per line.
set -eu
MODE=${1:-bun}
OUT=/work/out LOG=/work/log
case "$MODE" in
  bun) INIT=/usr/lib/bunlfs/init.ts ;;
  preinit) INIT=/usr/lib/bunlfs/preinit ;;
  *) echo "mode: bun|preinit"; exit 2 ;;
esac
: "${ACCEL:=tcg}" "${SMP:=2}" "${MEM:=2048}"
cp "$OUT/bunlfs.raw" /tmp/boot.raw # keep the published image pristine
t0=$(date +%s.%N)
timeout 600 nice -n 19 qemu-system-x86_64 -machine q35 -accel "$ACCEL" -cpu max -smp "$SMP" -m "$MEM" \
  -kernel "$OUT/bzImage" -append "console=ttyS0 root=/dev/vda rw init=$INIT panic=-1" \
  -drive file=/tmp/boot.raw,format=raw,if=virtio -nographic -no-reboot -serial mon:stdio </dev/null 2>&1 |
  while IFS= read -r l; do printf '%8.3f %s\n' "$(awk -v a="$(date +%s.%N)" -v b="$t0" "BEGIN { print a - b }")" "$l"; done > "$LOG/qemu-$MODE.log"
grep -q BUNLFS-PROOF-OK "$LOG/qemu-$MODE.log" && grep -q BUNLFS-POWEROFF "$LOG/qemu-$MODE.log"
grep -E "Linux version|rust_minimal|rust_print|BUNLFS|^ *[0-9.]+ (kernel|libc|bun|uutils|uname|uptime_s|loop_)" "$LOG/qemu-$MODE.log" | head -40
