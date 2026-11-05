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

# comma_fajita.dts is built out of $DTS_DST itself (dtc/cpp only search
# $(dir $<)), so the LineageOS include chain has to be present there.
#
# Do NOT overwrite what the AGNOS tree already ships: its sdm845.dtsi,
# sdm845-pinctrl.dtsi and pmi8998.dtsi are a trimmed comma-SoM fork, and
# comma_tizi/mici/ultimate are built from them -- replacing
# sdm845-pinctrl.dtsi with the LineageOS copy drops som_id_default and every
# comma DTB fails with "Reference to non-existent node or label".
copied=0
for ext in dtsi dts; do
  for f in "$DTS_SRC"/*."$ext"; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    [ -e "$DTS_DST/$base" ] && continue
    cp -f "$f" "$DTS_DST/$base"
    copied=$((copied + 1))
  done
done
echo "added $copied LineageOS DT files that AGNOS did not ship"


# One deliberate exception: sdm845-mtp.dtsi re-enables &ext_5v_boost, and the
# AGNOS copy of sdm845-pmic-overlay.dtsi does not declare that label.  Add the
# regulator to the AGNOS file; it stays status="disabled" exactly like
# upstream, so comma_tizi/mici/ultimate keep building unchanged.
PMIC="$DTS_DST/sdm845-pmic-overlay.dtsi"
if [ -f "$PMIC" ] && ! grep -q "ext_5v_boost" "$PMIC"; then
  python3 - "$PMIC" <<'PYEOF'
import sys
p = sys.argv[1]
src = open(p).read()
anchor = "&pmi8998_charger {"
block = """/* AGNOS: the pmi8998 VBUS boost that sdm845-mtp.dtsi re-enables as
 * &ext_5v_boost.  LineageOS declares it in this file; the AGNOS copy does
 * not, so a machine based on sdm845-mtp.dtsi would reference an undefined
 * label.  Left disabled, exactly as upstream, so the comma DTBs are
 * unaffected. */
&vendor {
\text_5v_boost: ext_5v_boost {
\t\tstatus = "disabled";
\t\tcompatible = "regulator-fixed";
\t\tregulator-name = "ext_5v_boost";
\t\tgpio = <&pmi8998_gpios 10 GPIO_ACTIVE_HIGH>;
\t\tenable-active-high;
\t\tregulator-enable-ramp-delay = <1600>;
\t};
};

"""
assert anchor in src, "pmi8998_charger anchor missing"
open(p, "w").write(src.replace(anchor, block + anchor, 1))
print("patched ext_5v_boost into sdm845-pmic-overlay.dtsi")
PYEOF
fi

# PHASE17: the 6T's real 5V VBUS generator is the PMI8998 SMB2 OTG engine,
# exposed as the `qcom,smb2-vbus` regulator child of &pmi8998_charger.  The
# AGNOS copy of sdm845-pmic-overlay.dtsi declares the node (it shows up in the
# PHASE15 DTB) but may not carry the `smb2_vbus:` label, and comma_fajita.dts
# needs the label to point vbus_dwc3-supply at it.  Add the label if missing --
# never add a second one, dtc rejects duplicate labels.
if [ -f "$PMIC" ]; then
  python3 - "$PMIC" <<'PYEOF'
import sys
p = sys.argv[1]
src = open(p).read()
if "smb2_vbus:" in src:
    print("smb2_vbus label already present")
elif "qcom,smb2-vbus" in src:
    open(p, "w").write(src.replace("qcom,smb2-vbus",
                                   "smb2_vbus: qcom,smb2-vbus", 1))
    print("labelled qcom,smb2-vbus as smb2_vbus")
else:
    sys.exit("qcom,smb2-vbus node not found in %s" % p)
PYEOF
fi

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


# Preprocess comma_fajita.dts on the host into a self-contained file.  The
# in-container cpp is $(CC) -E with a ccache symlink in front, and the generic
# dtc rule chains cpp and dtc with ';' so a preprocessor failure silently hands
# the raw .dts to dtc -- which then reports a bogus syntax error at the first
# #include.  Flattening here removes that whole failure mode.
FAJ_DTS="$DTS_DST/comma_fajita.dts"
if [ -f "$FAJ_DTS" ]; then
  grep -v -e '^$' "$FAJ_DTS" > /dev/null

  # ---- PHASE17: USB host VBUS 5V ----------------------------------------
  # One image per variant, selected at cpp time.  See
  # docs/PHASE17-VBUS-VARIANTS.md for what each variant changes and why.
  VBUS_VARIANT="${VBUS_VARIANT:-1}"
  case "$VBUS_VARIANT" in
    1|2|3|4) ;;
    *) echo "::error::VBUS_VARIANT must be 1..4 (got '$VBUS_VARIANT')"; exit 1 ;;
  esac
  {
    echo ''
    echo '/* ======== PHASE17: USB host VBUS 5V (selected variant) ======== */'
    echo '#if VBUS_VARIANT == 1 || VBUS_VARIANT == 2'
    echo '/* B-1: the 6T VBUS generator is PMI8998 SMB2 OTG boost (smb2_vbus),'
    echo ' * not the MTP external boost.  ext_5v_boost sits on pmi8998 gpio10,'
    echo ' * which is the 6T usb_sw line -- leave it disabled so its probe does'
    echo ' * not drive that pin. */'
    echo '&ext_5v_boost { status = "disabled"; };'
    echo '&pmi8998_pdphy { vbus-supply = <&smb2_vbus>; };'
    echo '&usb0 {'
    echo '	vbus_dwc3-supply = <&smb2_vbus>;'
    echo '	/* mdwc->type_c defaults true and then dwc3-msm refuses to even'
    echo '	 * look up the vbus regulator; this clears that gate. */'
    echo '	qcom,no-vbus-vote-with-type-C;'
    echo '};'
    echo '#endif'
    echo ''
    echo '#if VBUS_VARIANT == 2'
    echo '/* B-1 + force: keep the OTG boost on from regulator_init_complete,'
    echo ' * independent of the dwc3 host state machine. */'
    echo '&smb2_vbus {'
    echo '	regulator-always-on;'
    echo '	regulator-boot-on;'
    echo '};'
    echo '#endif'
    echo ''
    echo '#if VBUS_VARIANT == 3'
    echo '/* B-2: drive pmi8998 gpio2 high (the reference design USB VBUS boost'
    echo ' * enable, cf. sdm845-cdp.dtsi usb1_vbus_vreg).  Unused on fajita. */'
    echo '&ext_5v_boost { status = "disabled"; };'
    echo '&vendor {'
    echo '	vbus_boost_gpio2: usb-vbus-boost-gpio2 {'
    echo '		compatible = "regulator-fixed";'
    echo '		regulator-name = "usb-vbus-boost-gpio2";'
    echo '		gpio = <&pmi8998_gpios 2 GPIO_ACTIVE_HIGH>;'
    echo '		enable-active-high;'
    echo '		regulator-always-on;'
    echo '		regulator-boot-on;'
    echo '	};'
    echo '};'
    echo '#endif'
    echo ''
    echo '#if VBUS_VARIANT == 4'
    echo '/* B-3: assert pmi8998 gpio3.  fajita.dtsi declares it as'
    echo ' * op,vbus-ctrl-gpio = <&pmi8998_gpios 3 GPIO_ACTIVE_LOW> and only ever'
    echo ' * gpio_request()s it, so the level is whatever the bootloader left. */'
    echo '&ext_5v_boost { status = "disabled"; };'
    echo '&vendor {'
    echo '	vbus_ctrl_gpio3: usb-vbus-ctrl-gpio3 {'
    echo '		compatible = "regulator-fixed";'
    echo '		regulator-name = "usb-vbus-ctrl-gpio3";'
    echo '		gpio = <&pmi8998_gpios 3 GPIO_ACTIVE_LOW>;'
    echo '		regulator-always-on;'
    echo '		regulator-boot-on;'
    echo '	};'
    echo '};'
    echo '#endif'
  } >> "$FAJ_DTS"
  echo "PHASE17: appended VBUS variant $VBUS_VARIANT block"

  cpp -nostdinc -I"$DTS_DST" \
      -I"$WORK/agnos/agnos-kernel-sdm845/arch/arm64/boot/dts/include" \
      -undef -D__DTS__ -DVBUS_VARIANT="$VBUS_VARIANT" -P -x assembler-with-cpp \
      -o "$FAJ_DTS.flat" "$FAJ_DTS"
  # keep exactly one /dts-v1/; at the top
  awk 'BEGIN{seen=0} /^[[:space:]]*\/dts-v1\/;/{ if(seen) next; seen=1 } {print}' \
    "$FAJ_DTS.flat" > "$FAJ_DTS.tmp" && mv "$FAJ_DTS.tmp" "$FAJ_DTS.flat"
  mv "$FAJ_DTS.flat" "$FAJ_DTS"
  echo "flattened comma_fajita.dts -> $(wc -l < "$FAJ_DTS") lines"
fi


echo "== summary"
git -C "$WORK/agnos" --no-pager log --oneline -1
git -C "$WORK/agnos/agnos-kernel-sdm845" --no-pager log --oneline -1
ls -1 "$CFG_DST"/agnos_fajita.fragment "$DTS_DST"/comma_fajita.dts
