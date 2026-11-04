#!/usr/bin/env bash
# Reproduce build_kernel.sh's boot.img packaging on the runner (no docker,
# no nested container).  The signing step is what the bootloader checks.
#
# usage: mkbootimg.sh <kernel-image-dtb> <out/boot.img> <cmdline-file>
set -euo pipefail

KIMG="$1"; OUT="$2"; CMDLINE_FILE="$3"
AGNOS_DIR="${AGNOS_DIR:-$PWD/agnos}"
TOOLS="$AGNOS_DIR/tools"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CMDLINE="$(cat "$CMDLINE_FILE")"
test -n "$CMDLINE" || { echo "::error::empty cmdline"; exit 1; }

"$TOOLS/mkbootimg" \
  --kernel "$KIMG" \
  --ramdisk /dev/null \
  --cmdline "$CMDLINE" \
  --pagesize 4096 \
  --base 0x80000000 \
  --kernel_offset 0x8000 \
  --ramdisk_offset 0x8000 \
  --tags_offset 0x100 \
  --output "$TMP/boot.img.nonsecure"

# AVB-less Qualcomm "le" signature: sha256 over the image, RSA-PKCS1 signed
# with comma's vble key, padded to 2048 bytes and appended.
openssl dgst -sha256 -binary "$TMP/boot.img.nonsecure" > "$TMP/boot.img.sha256"
openssl pkeyutl -sign -in "$TMP/boot.img.sha256" \
  -inkey "$AGNOS_DIR/vble-qti.key" -out "$TMP/boot.img.sig" \
  -pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pkcs1
dd if=/dev/zero of="$TMP/boot.img.sig.padded" bs=2048 count=1 status=none
dd if="$TMP/boot.img.sig" of="$TMP/boot.img.sig.padded" conv=notrunc status=none

mkdir -p "$(dirname "$OUT")"
cat "$TMP/boot.img.nonsecure" "$TMP/boot.img.sig.padded" > "$OUT"
echo "boot.img: $(stat -c%s "$OUT") bytes"
echo "cmdline : $CMDLINE"
