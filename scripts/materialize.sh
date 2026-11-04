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

# copy only what comma_fajita.dts actually includes, plus the panel DTIs
for f in \
  dsi-panel-samsung_s6e3fc2x01.dtsi \
  sdm845-sde-display.dtsi \
  sdm845-mtp.dtsi sdm845-v2-mtp.dtsi sdm845-v2.1-mtp.dtsi \
  sdm845-pmic-overlay.dtsi sdm845-pinctrl-overlay.dtsi \
  sdm845-camera-sensor-mtp.dtsi \
  dsi-panel-nt35597-truly-dsc-cmd.dtsi ; do
  [ -f "$DTS_SRC/$f" ] && cp -f "$DTS_SRC/$f" "$DTS_DST/$f"
done
cp -f "$DTS_SRC"/sdm845*.dtsi "$DTS_DST"/ 2>/dev/null || true
cp -f "$DTS_SRC"/dsi-panel-*.dtsi "$DTS_DST"/ 2>/dev/null || true

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
  git apply --recount -v "$p"
done

cd "$WORK/agnos/agnos-kernel-sdm845"
for p in "$PATCHES"/kernel/*.patch; do
  echo "-- $(basename "$p")"
  git apply --recount -v "$p"
done

echo "== summary"
git -C "$WORK/agnos" --no-pager log --oneline -1
git -C "$WORK/agnos/agnos-kernel-sdm845" --no-pager log --oneline -1
ls -1 "$CFG_DST"/agnos_fajita.fragment "$DTS_DST"/comma_fajita.dts
