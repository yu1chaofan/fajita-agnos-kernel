#!/bin/bash
# PHASE24 · base job: apply the PHASE23 userspace perf patch as 0003.
#
# WHY 0003 AND WHY THIS ORDER
#   The five 底座 patches are applied by build-repo/scripts/materialize.sh:
#     patches/agnos-builder/0001-build_kernel-fajita.patch
#     patches/agnos-builder/0002-userspace-fajita-services.patch   <- also edits
#                                                                     userspace/services.sh
#                                                                     and usr/comma/comma.sh
#     patches/kernel/000{1,2,3}-*.patch
#   The phase23 userspace patch edits the SAME two files (plus base_setup.sh),
#   so it is a composition step, not a standalone one: it must run after
#   materialize.sh. Measured in PHASE23: on top of agnos-builder/0002 the
#   services.sh hunk lands at "31 (offset 3 lines)" — patch(1) absorbs the +3
#   line shift, nothing is lost.
#
# WHY RENAMED TO 0003-*
#   The phase23 file is `0001-userspace-fajita-perf.patch`, i.e. numbered inside
#   its own series. In the base job it is the sixth patch of one composed series,
#   so it is staged as `0003-userspace-fajita-perf.patch` — one series, one
#   monotonic order, no ambiguity about "which 0001".
#
# WHY THE STAGING DIR IS OUTSIDE build-repo/patches
#   base-fajita.yml asserts `find patches -name '*.patch' | wc -l == 5`. Staging
#   0003 inside build-repo/patches would silently change that number and break the
#   provenance check that proves materialize.sh consumed exactly the 5 底座
#   patches. So it is staged into $STAGE (default: fajita-patches), outside the
#   build repo.
#
# WHY --no-backup-if-mismatch
#   Without it, every fuzzy hunk leaves a `*.orig` next to the source file. Those
#   files then travel into the rootfs overlay tar (the overlay copy is a plain
#   `cp -a`) and land in /usr/comma/perf_mode.sh.orig on the device. The flag
#   makes a mismatch loud (the hunk still applies, offset is reported) without
#   leaving debris.
#
# Usage: apply-base-extra-patch.sh [--tree DIR] [--src FILE] [--stage DIR] [--checker FILE]
set -euo pipefail

TREE="build-repo/agnos"                                   # agnos-builder checkout
SRC="port/phase23/unit/patches/0001-userspace-fajita-perf.patch"
STAGE="fajita-patches"
CHECKER="port/phase23/unit/check_unit.py"

while [ $# -gt 0 ]; do
  case "$1" in
    --tree) TREE="$2"; shift 2 ;;
    --src) SRC="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    --checker) CHECKER="$2"; shift 2 ;;
    *) echo "::error::unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "::error title=0003 red::$*" >&2; exit 1; }

P3="$STAGE/0003-userspace-fajita-perf.patch"

echo "== 0003 userspace fajita perf: tree=$TREE src=$SRC stage=$P3"
test -d "$TREE" || die "agnos-builder tree '$TREE' missing (materialize.sh did not run?)"
test -f "$SRC" || die "patch source missing: $SRC (port repo not checked out?)"
test -f "$TREE/userspace/base_setup.sh" || die "$TREE/userspace/base_setup.sh missing: wrong -d root, the patch is -p1 against the agnos-builder root"

# --- stage under the composed-series name -----------------------------------
mkdir -p "$STAGE"
cp -f "$SRC" "$P3"
echo "staged: $(sha256sum "$P3")"

# --- pre-state: the 5 底座 patches must already be in (composition, not isolation)
echo "--- pre-state (0003 expects the materialize.sh state) ---"
grep -q 'chmod 755 /usr/comma/perf_mode.sh' "$TREE/userspace/services.sh" \
  && die "0003 already applied to $TREE (perf_mode chmod present)"
grep -q 'boot_cdsp' "$TREE/userspace/services.sh" \
  || echo "::warning::agnos-builder/0002 marker (boot_cdsp guard) absent from services.sh; 0003 may still apply but the composition was not measured in this state"
test -e "$TREE/userspace/root/usr/comma/perf_mode.sh" \
  && die "$TREE/userspace/root/usr/comma/perf_mode.sh already exists"

# --- dry-run then apply, both with --no-backup-if-mismatch -------------------
echo
echo "== dry-run 0003"
patch -p1 -d "$TREE" --dry-run --no-backup-if-mismatch -i "$(cd "$(dirname "$P3")" && pwd)/$(basename "$P3")" \
  || die "0003 does not apply to $TREE after the 5 底座 patches (context drift: re-check agnos-builder/0002 composition)"

echo
echo "== apply 0003"
patch -p1 -d "$TREE" --no-backup-if-mismatch -i "$(cd "$(dirname "$P3")" && pwd)/$(basename "$P3")" \
  || die "0003 dry-run passed but the real apply failed"

# --- landed state -----------------------------------------------------------
echo
echo "== landed-state asserts"
fail=0
chk() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then echo "  PASS $desc"; else echo "  FAIL $desc"; fail=1; fi; }
chk "perf_mode.sh staged"            test -f "$TREE/userspace/root/usr/comma/perf_mode.sh"
chk "thermal_log.sh staged"          test -f "$TREE/userspace/root/usr/comma/thermal_log.sh"
chk "fajita-perf.service staged"     test -f "$TREE/userspace/root/usr/lib/systemd/system/fajita-perf.service"
chk "fajita-thermal-log.service staged" test -f "$TREE/userspace/root/usr/lib/systemd/system/fajita-thermal-log.service"
chk "/etc/fajita/perf_mode staged"   test -f "$TREE/userspace/root/etc/fajita/perf_mode"
chk "services.sh enables the units behind /FAJITA" grep -q 'systemctl enable fajita-perf.service' "$TREE/userspace/services.sh"
chk "comma.sh applies the perf mode"  grep -q 'perf_mode.sh --from-config' "$TREE/userspace/root/usr/comma/comma.sh"
# the marker itself: everything downstream (services.sh gating, openpilot's
# Fajita() selection, the units' ConditionPathExists) keys on this single line.
chk "base_setup.sh contains 'touch /FAJITA'" grep -qE '^touch /FAJITA$' "$TREE/userspace/base_setup.sh"
chk "no .orig/.rej left behind"      bash -c "! find '$TREE/userspace' -name '*.orig' -o -name '*.rej' | grep -q ."
test "$fail" -eq 0 || die "landed state does not match what 0003 claims (see PASS/FAIL above)"
echo
echo "--- touch /FAJITA in base_setup.sh (verbatim) ---"
grep -n -B1 -A1 '^touch /FAJITA$' "$TREE/userspace/base_setup.sh"

# --- structural check on the staged units -----------------------------------
echo
echo "== check_unit.py $TREE/userspace/root"
test -f "$CHECKER" || die "checker missing: $CHECKER (port repo not checked out?)"
python3 "$CHECKER" "$TREE/userspace/root" || die "check_unit.py FAILED: systemd units / staged rootfs inconsistent"

echo
echo "== 0003 applied + check_unit green"
