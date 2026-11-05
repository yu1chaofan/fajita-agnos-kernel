#!/bin/bash
# PHASE24 · materialize patches/branch-matrix/<key>/ from the port repo (phase23).
#
# WHY THIS SCRIPT EXISTS (single source of truth)
#   The branch-matrix patches must not be a second hand-copied edition of the
#   phase23 files: any divergence between "the patch CI applies" and "the patch
#   phase23 verified" is invisible until a build breaks. So the bytes are copied
#   from phase23/hwbase/patches/ by the two `cp` commands below, every run, and
#   the result is then checked against the checked-in sha256 manifest
#   (patches/branch-matrix/openpilot.sha256). Copy + pin is the whole contract:
#     * the copy makes phase23 the origin,
#     * the pin makes the copy verifiable.
#
# WHERE IT RUNS
#   * branch-matrix.yml, op leg, step "prepare": --src $PORT_PATCH_SRC --dst $PATCH_ROOT/openpilot
#     (in CI, $PORT_PATCH_SRC = port/phase23/hwbase/patches; the port repo is
#      the same checkout panda-presupport.yml already pulls for phase21)
#   * locally, to stage the deliverable:
#       bash phase24/ci/scripts/prepare-branch-matrix-patches.sh \
#            --src phase23/hwbase/patches \
#            --dst phase24/ci/patches/branch-matrix/openpilot
#
# GRACEFUL CASE
#   When --src does not exist (port repo not checked out in this job) the
#   already-committed copies under --dst are used as-is. That is NOT a skip: the
#   sha256 gate below still runs and still has to pass, so an absent source can
#   never silently downgrade the leg.
set -euo pipefail

SRC="port/phase23/hwbase/patches"
DST="patches/branch-matrix/openpilot"

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --dst) DST="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "::error::unknown argument: $1" >&2; exit 2 ;;
  esac
done

MANIFEST="$(dirname "$DST")/openpilot.sha256"

echo "prepare: src=$SRC dst=$DST manifest=$MANIFEST"

if [ -d "$SRC" ]; then
  # --- the two cp commands: phase23 -> CI repo -------------------------------
  cp -f "$SRC/0001-openpilot-fajita-hardware.patch" \
        "$DST/0001-openpilot-fajita-hardware.patch"
  cp -f "$SRC/0002-openpilot-fajita-skip-agnos-flash.patch" \
        "$DST/0002-openpilot-fajita-skip-agnos-flash.patch"
  echo "copied 2 patches from $SRC"
else
  echo "::notice title=patch source absent::$SRC not present in this job; using the committed copies under $DST (sha256 gate below still applies)"
fi

test -d "$DST" || { echo "::error::$DST does not exist and $SRC was not available"; exit 1; }

mapfile -t P < <(find "$DST" -maxdepth 1 -name '*.patch' | sort)
printf 'found: %s\n' "${P[@]}"
test "${#P[@]}" -eq 2 || {
  echo "::error::expected exactly 2 openpilot patches in $DST, found ${#P[@]}"
  exit 1
}

# --- the pin: what got copied is what phase23 verified ----------------------
test -f "$MANIFEST" || { echo "::error::$MANIFEST missing (sha256 pin)"; exit 1; }
echo "--- $(basename "$MANIFEST") ---"
cat "$MANIFEST"
(cd "$(dirname "$DST")" && sha256sum -c "$(basename "$MANIFEST")")
echo "prepare: OK (2 patches, sha256 pinned)"
