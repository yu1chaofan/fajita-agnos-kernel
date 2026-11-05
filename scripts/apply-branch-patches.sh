#!/bin/bash
# PHASE29 · generic strict apply gate for ANY branch-matrix leg with real patches.
#
# Differences vs apply-openpilot-patches.sh (which stays for the `op` leg):
#   * hardware package path is NOT hard-coded — it is discovered from the tree
#     (openpilot/common/hardware, openpilot/system/hardware, system/hardware are
#      all real layouts among the five branches);
#   * landed-state asserts are layout-agnostic;
#   * the ordering contract is the same: 0001 then 0002, dry-run before each.
#
# usage: apply-branch-patches.sh --app DIR --patches DIR --label FILE
set -euo pipefail

APP=""; PATCHES=""; LABEL=""; EXPECT_COMMIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP=$2; shift 2;;
    --patches) PATCHES=$2; shift 2;;
    --label) LABEL=$2; shift 2;;
    --expect-commit) EXPECT_COMMIT=$2; shift 2;;
    *) echo "::error::unknown arg $1"; exit 2;;
  esac
done
[ -n "$APP" ] && [ -d "$APP" ] || { echo "::error::--app missing/not a dir"; exit 2; }
[ -n "$PATCHES" ] && [ -d "$PATCHES" ] || { echo "::error::--patches missing/not a dir"; exit 2; }

die() { echo "::error::$*"; exit 1; }

# ---- commit pin check (only when the tree is a git checkout) ------------------
# PHASE31: 把专用脚本里唯一有价值而通用版没有的东西搬过来 —— 「打补丁前先确认
# 这棵树就是 matrix.commit」。CI 里 app/ 一定是 git clone；本地假树不是，所以
# 有 .git 才校验。
if [ -d "$APP/.git" ] && [ -n "${EXPECT_COMMIT:-}" ]; then
  head_sha=$(git -C "$APP" rev-parse HEAD 2>/dev/null || echo "")
  [ "$head_sha" = "$EXPECT_COMMIT" ] \
    || die "HEAD mismatch: got '${head_sha:0:12}', expected '${EXPECT_COMMIT:0:12}'"
  echo "HEAD pin OK: ${head_sha:0:12}"
fi

# ---- discover the hardware package in the checked-out tree --------------------
# 注意：sunnypilot 两者都存在（runtime 在 common，installer 在 system），必须
# 优先取 runtime 那一份。判据：runtime 的 __init__.py 里会出现 "HardwareComma"
# 或 "HardwareFajita"，installer 版只有 Tici/Pc。
pick_hw() {
  local d
  for d in $(cd "$APP" && find . -maxdepth 4 -type d \
               \( -path "*/openpilot/common/hardware" -o -path "*/openpilot/system/hardware" \
                  -o -path "*/system/hardware" \)); do
    case "$d" in
      */common/hardware) echo "$d"; return ;;
    esac
  done
  for d in $(cd "$APP" && find . -maxdepth 4 -type d \
               \( -path "*/openpilot/common/hardware" -o -path "*/openpilot/system/hardware" \
                  -o -path "*/system/hardware" \)); do
    echo "$d"; return
  done
}
HW=$(pick_hw)
[ -n "$HW" ] || die "no hardware package found under $APP"
HW=${HW#./}
echo "hardware package: $HW"
# PHASE32: checker 现在提交在 CI 仓 ci/checkers/ 下（不再指望 app/ 树里带着），
# 所以 --root 恒等于 app/，覆盖率这层在 CI 里是真的会跑，而不是永远 skip。
CHECKERS=${CHECKERS_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../checkers" 2>/dev/null && pwd || true)"}
COVDIR=""
[ -n "$CHECKERS" ] && [ -f "$CHECKERS/check_coverage.py" ] && COVDIR="$CHECKERS/check_coverage.py"

# ---- immutable ordering: 0001 (create) then 0002 (edit what 0001 created) ----
P1=$(ls "$PATCHES"/0001-*.patch 2>/dev/null | head -1) || true
P2=$(ls "$PATCHES"/0002-*.patch 2>/dev/null | head -1) || true
P3=$(ls "$PATCHES"/0003-*.patch 2>/dev/null | head -1) || true
[ -n "$P1" ] || die "no 0001-*.patch in $PATCHES"

apply_one() {
  local patch_file
  patch_file=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")   # 绝对化：下面要 cd 进 $APP
  echo "--- dry-run $(basename "$patch_file")"
  ( cd "$APP" && patch -p1 --dry-run -f < "$patch_file" ) || die "dry-run failed: $(basename "$patch_file")"
  echo "--- apply   $(basename "$patch_file")"
  ( cd "$APP" && patch -p1 -f --no-backup-if-mismatch < "$patch_file" ) || die "apply failed: $(basename "$patch_file")"
}

# 0001 必须是「干净树」上的第一次应用
if grep -q "FAJITA" "$APP/$HW/__init__.py" 2>/dev/null; then
  die "0001 target already patched: $HW/__init__.py mentions FAJITA"
fi
apply_one "$P1"

if [ -n "$P2" ]; then
  # 0002 只有在 0001 之后才有意义（它改 0001 建的文件）
  [ -f "$APP/$HW/fajita/hardware.py" ] || die "0002 present but $HW/fajita/hardware.py missing after 0001"
  apply_one "$P2"
fi

if [ -n "$P3" ]; then
  # 0003 = 分支专有加固（当前只有 frogpilot：runner 设备感知），必须在 0001 之后
  apply_one "$P3"
fi

# ---- landed-state asserts (layout agnostic) ---------------------------------
grep -q "^FAJITA = os.path.isfile('/FAJITA')" "$APP/$HW/__init__.py" || die "selector missing FAJITA probe"
grep -q "HardwareFajita" "$APP/$HW/__init__.py"                     || die "selector missing HardwareFajita"
[ -f "$APP/$HW/fajita/hardware.py" ]                                || die "fajita/hardware.py not created"

if [ -n "$P2" ]; then
  UPD=$(find "$APP" -name updated.py -path "*updated*" | head -1)
  [ -n "$UPD" ] || die "updated.py not found"
  grep -q "AGNOS, FAJITA" "$UPD"          || die "updated.py import not patched ($UPD)"
  grep -q "if AGNOS and not FAJITA:" "$UPD" || die "updated.py AGNOS gate not patched ($UPD)"
  python3 -c "import ast;ast.parse(open('$UPD').read())" || die "updated.py syntax broken"
fi

python3 -c "import ast,sys;ast.parse(open('$APP/$HW/__init__.py').read())"     || die "selector syntax broken"
python3 -c "import ast,sys;ast.parse(open('$APP/$HW/fajita/hardware.py').read())" || die "fajita/hardware.py syntax broken"

# ---- per-branch contract checks (only if the branch ships the checker) ------
if [ -n "$COVDIR" ]; then
  echo "--- coverage (checker: $COVDIR)"
  python3 "$COVDIR" --root "$APP" || die "check_coverage failed (interface coverage)"
  echo "--- selection (which device class gets chosen)"
  python3 "$COVDIR" --root "$APP" --selection || die "selection test failed"
else
  die "checker missing: expected <ci>/checkers/check_coverage.py (set CHECKERS_DIR to override)"
fi

# PHASE37: 语义层 checker —— 只有 dp/frog 的 0003 需要它；其它支返回 2（不适用）不算错。
# 这条是「有测试但从不执行」的补丁：不加这里，两个 0003 的行为就只能靠手工跑过一次。
if [ -n "$CHECKERS" ] && [ -f "$CHECKERS/check_runner_semantics.py" ]; then
  echo "--- runner semantics (checker: $CHECKERS/check_runner_semantics.py)"
  # set -e 下「命令失败」会立刻退出，拿不到 rc。用 `|| rs=$?` 显式接住。
  rs=0
  python3 "$CHECKERS/check_runner_semantics.py" --root "$APP" > /tmp/rs.out 2>&1 || rs=$?
  cat /tmp/rs.out
  case "$rs" in
    0) : ;;                        # PASS
    2) echo "  (no runner-semantics checker applies to this branch)" ;;
    *) die "runner semantics check failed (rc=$rs)" ;;
  esac
else
  die "checker missing: expected <ci>/checkers/check_runner_semantics.py"
fi

echo "status=applied"
[ -n "$LABEL" ] && { echo "status=applied" >> "$LABEL"; }
exit 0
