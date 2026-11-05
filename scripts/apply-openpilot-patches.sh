#!/bin/bash
# PHASE31 DEPRECATED — 本脚本已退役，五支统一走 apply-branch-patches.sh。
# 保留原因：历史归档与差异对照（它的 landed-state 断言写得比通用版更细，
# 尤其 selector/updated.py 的逐行 grep）。如需复活，请在 branch-matrix.yml
# 里显式改回调用它，并补上 op 之外的布局分支。
# PHASE24 · strict apply gate for the openpilot leg (commaai/openpilot@4b20c34e5178).
#
# This leg is the ONLY branch-matrix leg that carries real patches as of PHASE24,
# so it must NOT be allowed to degrade into "graceful skip": every failure here is
# a red leg. That is the whole point — a skip that hides a broken patch is worse
# than a red build.
#
# ORDERING IS NOT NEGOTIABLE
#   0002 edits openpilot/common/hardware/fajita/hardware.py, a file that 0001
#   CREATES, and imports FAJITA, a symbol 0001 adds to
#   openpilot/common/hardware/__init__.py. Therefore a dry-run of 0002 on the
#   pristine tree cannot pass, and "dry-run both, then apply both" is not a
#   meaningful sequence. The only valid interleave is per patch, in order:
#
#     1) dry-run 0001 on pristine   (proves the patch matches the pinned commit)
#     2) apply   0001
#     3) dry-run 0002               (only meaningful now)
#     4) apply   0002
#     5) landed-state asserts       (grep the tree, not "patch exited 0")
#     6) check_coverage.py --root <tree>   (HardwareBase contract vs hardwared.py)
#     7) test_selection.py on a 2-file slice of the APPLIED tree
#
# Step 1 also asserts that 0002 does NOT dry-run on the pristine tree, so the
# dependency is enforced by behaviour instead of by a comment.
#
# Usage:
#   apply-openpilot-patches.sh --app DIR --patches DIR --checker-dir DIR [--label FILE]
# Exit: 0 = applied (all of 1..7 green), non-zero = red leg.
set -euo pipefail

APP="app"
PATCHES="patches/branch-matrix/openpilot"
CHECKER="port/phase23/hwbase"
LABEL="leg-status.txt"

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --patches) PATCHES="$2"; shift 2 ;;
    --checker-dir) CHECKER="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    *) echo "::error::unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "::error title=openpilot leg red::$*" >&2; echo "status=red" >> "$LABEL" 2>/dev/null || true; echo "reason=$*" >> "$LABEL" 2>/dev/null || true; exit 1; }

P1="$PATCHES/0001-openpilot-fajita-hardware.patch"
P2="$PATCHES/0002-openpilot-fajita-skip-agnos-flash.patch"
A1="$(cd "$(dirname "$P1")" && pwd)/$(basename "$P1")"
A2="$(cd "$(dirname "$P2")" && pwd)/$(basename "$P2")"

echo "== openpilot leg: app=$APP patches=$PATCHES checker=$CHECKER"
test -d "$APP" || die "app dir '$APP' missing (checkout step did not produce it)"
test -f "$A1" || die "missing patch file: $A1 (run scripts/prepare-branch-matrix-patches.sh)"
test -f "$A2" || die "missing patch file: $A2 (run scripts/prepare-branch-matrix-patches.sh)"

# Record the tree state we start from; the asserts below are meaningless without it.
echo "--- pristine tree ---"
git -C "$APP" rev-parse HEAD
test ! -e "$APP/openpilot/common/hardware/fajita/hardware.py" \
  || die "0001 target already present before patching: the checkout is not pristine"
! grep -q "FAJITA" "$APP/openpilot/common/hardware/__init__.py" \
  || die "0001 target already patched: openpilot/common/hardware/__init__.py mentions FAJITA"

# ---------------------------------------------------------------- 0. dependency
echo
echo "== 0. dependency check: 0002 must NOT be applicable to the pristine tree"
BLOCKED="$(mktemp)"; trap 'rm -rf "${SEL:-}" "$BLOCKED"' EXIT
if patch -p1 -d "$APP" --dry-run -f --no-backup-if-mismatch -i "$A2" >"$BLOCKED" 2>&1; then
  cat "$BLOCKED"
  die "0002 dry-runs clean on the PRISTINE tree; the documented 0001->0002 dependency would then be false"
fi
sed -n '/^can.t find file\|^Hunk #.*FAILED\|No file to patch/p' "$BLOCKED"
echo "OK: 0002 is blocked before 0001 ($(grep -cE "can.t find file|FAILED" "$BLOCKED") blocking hunk(s); full log kept at \$BLOCKED)"

# ------------------------------------------------------- 1. dry-run / 2. apply 0001
echo
echo "== 1. dry-run 0001 on pristine tree"
patch -p1 -d "$APP" --dry-run --no-backup-if-mismatch -i "$A1" \
  || die "0001 no longer applies to this tree (upstream drift at the pinned commit, or wrong commit)"

echo
echo "== 2. apply 0001"
patch -p1 -d "$APP" --no-backup-if-mismatch -i "$A1" || die "0001 dry-run passed but the real apply failed"

# ------------------------------------------------------- 3. dry-run / 4. apply 0002
echo
echo "== 3. dry-run 0002 (0001 is now on disk)"
patch -p1 -d "$APP" --dry-run --no-backup-if-mismatch -i "$A2" \
  || die "0002 does not apply on top of 0001 (dependency or context drift)"

echo
echo "== 4. apply 0002"
patch -p1 -d "$APP" --no-backup-if-mismatch -i "$A2" || die "0002 dry-run passed but the real apply failed"

# ------------------------------------------------------------- 5. landed state
echo
echo "== 5. landed-state asserts (what the tree contains, not what patch printed)"
fail=0
chk() { # description, command...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  PASS $desc"; else echo "  FAIL $desc"; fail=1; fi
}
chk "selector exports FAJITA"        grep -q "^FAJITA = os.path.isfile('/FAJITA')$" "$APP/openpilot/common/hardware/__init__.py"
chk "selector prefers FAJITA"        grep -q "^if FAJITA:$"                          "$APP/openpilot/common/hardware/__init__.py"
chk "fajita class file created"      test -f "$APP/openpilot/common/hardware/fajita/hardware.py"
chk "fajita package __init__ created" test -f "$APP/openpilot/common/hardware/fajita/__init__.py"
chk "HardwareFajita defined"         grep -q "^class HardwareFajita(HardwareBase):"  "$APP/openpilot/common/hardware/fajita/hardware.py"
chk "updated.py imports FAJITA"      grep -q "from openpilot.common.hardware import AGNOS, FAJITA, HARDWARE" "$APP/openpilot/system/updated/updated.py"
chk "AGNOS flash gated on FAJITA"    grep -q "^    if AGNOS and not FAJITA:$"        "$APP/openpilot/system/updated/updated.py"
chk "no .orig/.rej left in tree"     bash -c "! find '$APP' -name '*.orig' -o -name '*.rej' | grep -q ."
test "$fail" -eq 0 || die "landed state does not match what the two patches claim (see PASS/FAIL above)"

# --------------------------------------------------- 6. HardwareBase contract
echo
echo "== 6. check_coverage.py --root $APP"
test -f "$CHECKER/check_coverage.py" || die "checker missing: $CHECKER/check_coverage.py (port repo not checked out?)"
python3 "$CHECKER/check_coverage.py" --root "$APP" || die "check_coverage.py FAILED: HardwareFajita does not cover the HardwareBase/hardwared call surface"

# ------------------------------------------------- 7. selection behaviour test
echo
echo "== 7. test_selection.py against a 2-file slice of the APPLIED tree"
# test_selection.py resolves its tree as <its own dir>/<--tree>, so it must be
# copied next to the slice. It reads exactly two files from the tree
# (common/hardware/__init__.py and common/hardware/fajita/hardware.py); the slice
# carries those two from the app tree, so this tests the patched bytes, not
# phase23's staged copy.
SEL="$(mktemp -d)"
trap 'rm -rf "$SEL" "$BLOCKED"' EXIT
# PHASE38: ci/checkers/ 里那份 test_selection.py 已删除（死文件，无引用、也无
# 它要的 new/ 树）。功能完全由 check_coverage.py --selection 覆盖。这里改为
# 从 phase23 原位取；取不到就明确 SKIP 而不是让 cp 报一个看不懂的错。
if [ -f "$CHECKER/test_selection.py" ]; then
  cp "$CHECKER/test_selection.py" "$SEL/test_selection.py"
else
  echo "SKIP test_selection.py (not staged at $CHECKER; superseded by check_coverage --selection)"
  SEL_HAS_TS=0
fi
mkdir -p "$SEL/apptree/openpilot/common/hardware/fajita"
cp "$APP/openpilot/common/hardware/__init__.py"          "$SEL/apptree/openpilot/common/hardware/__init__.py"
cp "$APP/openpilot/common/hardware/fajita/hardware.py"   "$SEL/apptree/openpilot/common/hardware/fajita/hardware.py"
echo "slice: $(sha256sum "$SEL/apptree/openpilot/common/hardware/__init__.py" "$SEL/apptree/openpilot/common/hardware/fajita/hardware.py" | cut -c1-16 | tr '\n' ' ')"
if [ "${SEL_HAS_TS:-1}" = 1 ]; then
  python3 "$SEL/test_selection.py" --tree apptree || die "test_selection.py FAILED: /FAJITA selection branch is wrong on the applied tree"
fi

echo
echo "== applied: 0001 + 0002 dry-run/apply in order, landed asserts, coverage, selection all green"
