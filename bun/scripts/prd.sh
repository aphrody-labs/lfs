#!/bin/sh
# Fallback host path (prd), not the default: the build runs on GitHub-hosted runners
# (.github/workflows/bunlfs.yml). On prd: CPU-capped container, paused while prd is busy.
# Usage: prd.sh <build.sh args | boot [mode] | compare>
# Pause rule: load1 minus our own running CPUs > nproc/2 -> docker pause; resume when load1 < nproc/2.
set -eu
BUNDIR=$(cd "$(dirname "$0")/.." && pwd)
W=${BUNLFS_WORK:-/srv/bunlfs/work}
JOBS=${JOBS:-2}
# Fleet rule (2026-11-13): one heavy job at a time on prd, under flock, only below half the cores.
exec 9>/var/lock/aphrody-heavy.lock
flock -n 9 || { echo "another heavy job holds /var/lock/aphrody-heavy.lock"; exit 75; }
awk -v l="$(cut -d" " -f1 /proc/loadavg)" -v h="$(( $(nproc) / 2 ))" "BEGIN { exit !(l < h) }" || { echo "prd load above half the cores, not starting"; exit 75; }
IMG=bunlfs-host:arch
NAME=bunlfs-$$
mkdir -p "$W/log"
nice -n 19 docker build -q -t "$IMG" -f "$BUNDIR/Containerfile" "$BUNDIR" > /dev/null
docker image inspect "$IMG" --format '{{.Id}}' > "$W/log/host-image.txt"
docker run --rm "$IMG" sh -c 'pacman -Q clang lld llvm rust rust-bindgen gcc glibc qemu-system-x86' >> "$W/log/host-image.txt"

case "${1:-all}" in
  boot) CMD="sh /lfs/bun/scripts/boot.sh ${2:-bun}" ;;
  boot-compare) shift; CMD="sh /lfs/bun/scripts/boot-compare.sh $* > /work/log/boot-compare.tsv" ;;
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
