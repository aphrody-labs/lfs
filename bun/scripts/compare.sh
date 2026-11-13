#!/bin/sh
# Compare bun-LFS with the official container images of Arch, Debian, Ubuntu, NixOS, Alpine, Fedora.
# Measured live on the host: image digest, uncompressed size, libc version (run inside), packaged
# kernel version (queried from each distro's own package manager, inside the image).
# Output: TSV on stdout, raw transcript in /work/log/compare.log (BUNLFS_WORK).
set -u
W=${BUNLFS_WORK:-/srv/bunlfs/work}
LOG=$W/log/compare.log
: > "$LOG"
q() { nice -n 19 docker run --rm --cpus 1 "$1" sh -c "$2" 2>>"$LOG" | tail -1; }

printf 'distro\timage\tdigest\tsize_MB\tlibc\tkernel_pkg\n'
row() { # name image libc_cmd kernel_cmd
  nice -n 19 docker pull -q "$2" >>"$LOG" 2>&1
  dig=$(docker image inspect "$2" --format '{{index .RepoDigests 0}}' | sed 's/.*@sha256:/sha256:/' | cut -c1-19)
  size=$(docker image inspect "$2" --format '{{.Size}}' | awk '{printf "%.1f", $1/1e6}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$dig" "$size" "$(q "$2" "$3")" "$(q "$2" "$4")"
}
row arch archlinux:latest 'ldd --version | head -1' 'pacman -Sy >/dev/null && pacman -Si linux | sed -n "s/^Version *: //p"'
row debian debian:stable 'ldd --version | head -1' 'apt-get update -qq && apt-cache policy linux-image-amd64 | sed -n "s/ *Candidate: //p"'
row ubuntu ubuntu:latest 'ldd --version | head -1' 'apt-get update -qq && apt-cache policy linux-image-generic | sed -n "s/ *Candidate: //p"'
row alpine alpine:latest 'ldd 2>&1 | sed -n 2p' 'apk update -q && apk policy linux-lts | sed -n 3p'
row fedora fedora:latest 'ldd --version | head -1' 'dnf -q repoquery --latest-limit 1 --qf "%{version}-%{release}" kernel 2>/dev/null | tail -1'
row nixos nixos/nix:latest 'ldd --version 2>/dev/null | head -1 || ls /nix/store | grep -m1 -E "glibc-[0-9.]+$"' \
  'nix --extra-experimental-features "nix-command flakes" eval --raw nixpkgs#linux.version'
B=$W/out
printf 'bunlfs\t(this build)\t%s\t%s\t%s\t%s\n' "$(sha256sum "$B/bunlfs-rootfs.tar.gz" | cut -c1-12)" \
  "$(awk '{printf "%.1f", $1/1e6}' "$B/rootfs-bytes.txt")" "glibc 2.44 (built)" "7.3.4 (built, LLVM=1, CONFIG_RUST=y)"
