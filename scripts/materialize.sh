#!/usr/bin/env bash
# Assemble the fajita AGNOS source tree:
#   agnos/              <- commaai/agnos-builder @ AGNOS_BUILDER_COMMIT
#   agnos/agnos-kernel-sdm845/ <- commaai/agnos-kernel-sdm845 @ AGNOS_KERNEL_COMMIT
#                               plus the fajita DT/config patches
#   agnos/.ccache       <- cache mount
# Everything is pinned; no floating branches.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/repos.lock"
PATCHES="$ROOT/patches"
WORK="${WORK:-$PWD}"

fetch_pinned() { # repo ref dest
  local repo="$1" ref="$2" dest="$3"
  rm -rf "$dest"
  git init -q "$dest"
  git -C "$dest" remote add origin "$repo"
  # full hash; fall back to a full fetch when the server refuses sha-refs
  git -C "$dest" fetch -q --depth 1 origin "$ref" 2>/dev/null || \
    git -C "$dest" fetch -q origin "$ref"
  git -C "$dest" checkout -q FETCH_HEAD
  test "$(git -C "$dest" rev-parse HEAD)" = "$ref" || {
    echo "::error::$dest is not at $ref"; exit 1; }
  echo "OK $dest @ $(git -C "$dest" rev-parse --short HEAD)"
}

echo "== agnos-builder"
fetch_pinned "$AGNOS_BUILDER_REPO" "$AGNOS_BUILDER_COMMIT" "$WORK/agnos"

echo "== agnos kernel"
fetch_pinned "$AGNOS_KERNEL_REPO" "$AGNOS_KERNEL_COMMIT" "$WORK/agnos/agnos-kernel-sdm845"

echo "== LineageOS kernel (DT sources only, shallow)"
fetch_pinned "$LINEAGE_KERNEL_REPO" "$LINEAGE_KERNEL_COMMIT" "$WORK/lineage-kernel"
git -C "$WORK/lineage-kernel" sparse-checkout init --cone
git -C "$WORK/lineage-kernel" sparse-checkout set arch/arm64/boot/dts arch/arm64/configs

echo "== vendor DT + configs into the AGNOS kernel tree"
DTS_SRC="$WORK/lineage-kernel/arch/arm64/boot/dts/qcom"
DTS_DST="$WORK/agnos/agnos-kernel-sdm845/arch/arm64/boot/dts/qcom"
CFG_DST="$WORK/agnos/agnos-kernel-sdm845/arch/arm64/configs"
mkdir -p "$DTS_DST" "$CFG_DST"

# The fajita machine DT is built from the LineageOS include closure, NOT from
# AGNOS' dtsi set: the two trees disagree on sdm845.dtsi / sdm845-pinctrl.dtsi /
# the PMIC overlays (AGNOS' copies are trimmed for the comma SoM and, among
# other things, never define &ext_5v_boost that sdm845-mtp.dtsi re-enables).
# Mixing them yields "Reference to non-existent node or label".  So keep the
# whole LineageOS qcom dir in its own subdirectory and build comma_fajita.dts
# from there -- dtc/cpp only search $(dir $<).
DJT_VENDOR="$DTS_DST/fajita-vendor"
rm -rf "$DJT_VENDOR"
mkdir -p "$DJT_VENDOR"
for ext in dtsi dts; do
  for f in "$DTS_SRC"/*."$ext"; do
    [ -f "$f" ] || continue
    cp -f "$f" "$DJT_VENDOR"/
  done
done
echo "vendored $(ls -1 "$DJT_VENDOR" | wc -l) LineageOS DT files into fajita-vendor"

# `git submodule status` reports the kernel dir as uninitialised because the
# tree we assembled is not a real submodule checkout, so build_kernel.sh's
# guard would try to re-clone upstream (and drop our patches).  Pin the
# submodule url to the local path: the clone then resolves instantly and the
# checked-out content is exactly what we already patched.
cd "$WORK/agnos"
git -C agnos-kernel-sdm845 rev-parse HEAD > /dev/null
git config -f .gitmodules submodule.agnos-kernel-sdm845.url "$WORK/agnos/agnos-kernel-sdm845"
git config -f .gitmodules submodule.agnos-kernel-sdm845.update none
git config submodule.agnos-kernel-sdm845.url "$WORK/agnos/agnos-kernel-sdm845"
git config submodule.agnos-kernel-sdm845.update none
git add .gitmodules
echo "submodule url -> local patched tree"
git config -f .gitmodules --get submodule.agnos-kernel-sdm845.url

echo "== AGNOS patches"
cd "$WORK/agnos"
for p in "$PATCHES"/agnos-builder/*.patch; do
  echo "-- $(basename "$p")"
  patch -p1 -i "$p"
done

cd "$WORK/agnos/agnos-kernel-sdm845"
for p in "$PATCHES"/kernel/*.patch; do
  echo "-- $(basename "$p")"
  patch -p1 --batch --forward -i "$p"
done

echo "== summary"
git -C "$WORK/agnos" --no-pager log --oneline -1
git -C "$WORK/agnos/agnos-kernel-sdm845" --no-pager log --oneline -1
ls -1 "$CFG_DST"/agnos_fajita.fragment "$DTS_DST"/fajita-vendor/comma_fajita.dts
