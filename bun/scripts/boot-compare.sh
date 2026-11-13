#!/bin/sh
# Boot-time comparison in the bun-LFS build container (same QEMU, TCG, -smp 2, -m 2048 for every
# system): seconds from QEMU start to the first `login:` on the serial console (bun-LFS: to
# BUNLFS-PROOF-OK, which comes after its whole proof). Official cloud images, checksums verified,
# a NoCloud seed (vfat CIDATA) so cloud-init does not wait for a datasource.
# Usage: boot-compare.sh [distro...]   -> /work/log/boot-<distro>.log, TSV on stdout
set -u
D=/work/cmp LOG=/work/log
mkdir -p "$D"
cd "$D"
A=https://geo.mirror.pkgbuild.com/images/latest
DEB=https://cloud.debian.org/images/cloud/trixie/latest
UBU=https://cloud-images.ubuntu.com/minimal/releases/stonking/release
FED=https://download.fedoraproject.org/pub/fedora/linux/releases/45/Cloud/x86_64/images
ALP=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud
img() { # distro -> "url sumsurl algo"
  case $1 in
    arch) echo "$A/Arch-Linux-x86_64-cloudimg.qcow2 $A/Arch-Linux-x86_64-cloudimg.qcow2.SHA256 sha256" ;;
    debian) echo "$DEB/debian-13-genericcloud-amd64.qcow2 $DEB/SHA512SUMS sha512" ;;
    ubuntu) echo "$UBU/ubuntu-26.10-minimal-cloudimg-amd64.img $UBU/SHA256SUMS sha256" ;;
    fedora) echo "$FED/Fedora-Cloud-Base-Generic-45-1.4.x86_64.qcow2 $FED/Fedora-Cloud-45-1.4-x86_64-CHECKSUM sha256" ;;
    alpine) echo "$ALP/generic_alpine-3.24.1-x86_64-bios-tiny-r0.qcow2 $ALP/generic_alpine-3.24.1-x86_64-bios-tiny-r0.qcow2.sha512 sha512" ;;
  esac
}
if [ ! -f seed.img ]; then
  printf 'instance-id: bunlfs-cmp\nlocal-hostname: cmp\n' > meta-data
  printf '#cloud-config\npassword: cmp\nchpasswd: { expire: false }\n' > user-data
  truncate -s 2M seed.img && mkfs.vfat -n CIDATA seed.img > /dev/null && mcopy -i seed.img meta-data user-data ::
fi
printf 'system\tseconds_to_marker\tmarker\timage\n'
for d in ${*:-arch debian ubuntu fedora alpine}; do
  set -- $(img "$d"); url=$1 sums=$2 algo=$3 f=$(basename "$url")
  [ -f "$f" ] || curl -fsSL -o "$f" "$url"
  sum=$(curl -fsSL "$sums" | grep -E "[ (*]$f\)?( |\$)|^[0-9a-f]+\$" | grep -oE '[0-9a-f]{64,128}' | head -1)
  echo "$sum  $f" | "${algo}sum" -c - > /dev/null 2>&1 || { printf '%s\tchecksum-failed\t-\t%s\n' "$d" "$f"; continue; }
  qemu-img create -q -f qcow2 -F qcow2 -b "$D/$f" "/tmp/$d.qcow2"
  t0=$(date +%s.%N)
  timeout 900 nice -n 19 qemu-system-x86_64 -machine q35 -accel tcg -cpu max -smp 2 -m 2048 \
    -drive file="/tmp/$d.qcow2",if=virtio -drive file="$D/seed.img",if=virtio,format=raw \
    -nographic -serial mon:stdio -no-reboot </dev/null 2>&1 |
    while IFS= read -r l; do
      t=$(awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN { printf "%.3f", a - b }')
      printf '%s %s\n' "$t" "$l"
      case $l in *"login:"*) pkill -f "file=/tmp/$d.qcow2" ;; esac
    done > "$LOG/boot-$d.log"
  s=$(grep -m1 "login:" "$LOG/boot-$d.log" | cut -d' ' -f1)
  printf '%s\t%s\tlogin:\t%s\n' "$d" "${s:-timeout}" "$f"
  rm -f "/tmp/$d.qcow2"
done
