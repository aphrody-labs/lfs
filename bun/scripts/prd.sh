#!/bin/sh
# Host side (prd): build the Arch image, run build.sh/boot.sh in a CPU-capped container,
# and pause it while the rest of the host is busy (prd serves production backends).
# Usage: prd.sh <build.sh args | boot [mode] | compare>
# Pause rule: load1 minus our own running CPUs > nproc/2 -> docker pause; resume when load1 < nproc/2.
set -eu
BUNDIR=$(cd "$(dirname "$0")/.." && pwd)
W=${BUNLFS_WORK:-/srv/bunlfs/work}
JOBS=${JOBS:-4}
IMG=bunlfs-host:arch
NAME=bunlfs-$$
mkdir -p "$W/log"
nice -n 19 docker build -q -t "$IMG" -f "$BUNDIR/Containerfile" "$BUNDIR" > /dev/null
docker image inspect "$IMG" --format '{{.Id}}' > "$W/log/host-image.txt"
docker run --rm "$IMG" sh -c 'pacman -Q clang lld llvm rust rust-bindgen gcc glibc qemu-system-x86' >> "$W/log/host-image.txt"

case "${1:-all}" in
  boot) CMD="sh /lfs/bun/scripts/boot.sh ${2:-bun}" ;;
  *) CMD="sh /lfs/bun/scripts/build.sh $*" ;;
esac

docker run -d --name "$NAME" --cpus "$JOBS" -e JOBS="$JOBS" \
  -v "$W:/work" -v "$BUNDIR/..:/lfs:ro" "$IMG" sh -c "$CMD" > /dev/null

half=$(( $(nproc) / 2 ))
paused=0
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
while [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ]; do
  sleep 20
  load=$(cut -d' ' -f1 /proc/loadavg)
  if [ $paused = 0 ]; then
    ours=$(docker stats --no-stream --format '{{.CPUPerc}}' "$NAME" | tr -d '%')
    other=$(awk -v l="$load" -v o="${ours:-0}" 'BEGIN { print l - o / 100 }')
    if gt "$other" "$half"; then
      docker pause "$NAME" > /dev/null; paused=1
      echo "$(date -u +%FT%TZ) pause load=$load ours=$ours%" | tee -a "$W/log/watchdog.log"
    fi
  elif gt "$half" "$load"; then
    docker unpause "$NAME" > /dev/null; paused=0
    echo "$(date -u +%FT%TZ) resume load=$load" | tee -a "$W/log/watchdog.log"
  fi
done
docker logs "$NAME" 2>&1 | tail -60
code=$(docker inspect -f '{{.State.ExitCode}}' "$NAME")
docker rm "$NAME" > /dev/null
exit "$code"
