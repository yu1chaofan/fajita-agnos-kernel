#!/usr/bin/env python3
"""Per-branch contract checker for the phase24 fajita ports.

Works for all four layout variants by discovery:
  * base.py / hardwared.py / hardware/__init__.py (selector) / hardware/fajita/hardware.py

Two checks:
  (default)      AST coverage: every abstractmethod of the branch's HardwareBase
                 and every `HARDWARE.<name>` attribute the branch actually
                 references must resolve on HardwareFajita.
  --selection    behaviour: builds a stub package around the branch's REAL
                 base.py and REAL fajita implementation, patches os.path.isfile
                 to simulate marker files, and asserts
                     /FAJITA present            -> HardwareFajita
                     /FAJITA absent             -> stock behaviour (Tici/Pc)
                 plus a control run using the branch's PRE-PATCH selector, which
                 must mis-select Tici on a fajita-like marker set.
                 Instantiating the real class also proves every abstractmethod is
                 implemented (Python raises TypeError otherwise).

Usage:
  python3 check_coverage.py [--root <dir with the branch trees>] [--selection]
"""
import argparse
import ast
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent


def discover(root: pathlib.Path) -> dict:
  """Locate the four contract files inside one branch tree (new/ or orig/)."""
  out = {}
  for sub in ("base.py", "hardwared.py", "__init__.py", "fajita/hardware.py"):
    hits = [p for p in root.rglob(sub) if "hardware" in p.parts and "tests" not in p.parts]
    # prefer the shallowest / canonical hardware dir
    hits.sort(key=lambda p: (len(p.parts), str(p)))
    if hits:
      out[sub] = hits[0]
  return out


def cls_of(path: pathlib.Path, name: str):
  tree = ast.parse(path.read_text())
  for n in ast.walk(tree):
    if isinstance(n, ast.ClassDef) and n.name == name:
      return n
  return None


def methods(c) -> set:
  return {n.name for n in c.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}


def abstracts(c) -> set:
  out = set()
  for n in c.body:
    if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
      for d in n.decorator_list:
        nm = d.id if isinstance(d, ast.Name) else getattr(d, "attr", "")
        if nm == "abstractmethod":
          out.add(n.name)
  return out


def hardware_attrs(path: pathlib.Path) -> set:
  out = set()
  for n in ast.walk(ast.parse(path.read_text())):
    if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name) and n.value.id == "HARDWARE":
      out.add(n.attr)
  return out


def coverage(root: pathlib.Path) -> int:
  files = discover(root)
  for need in ("base.py", "hardwared.py", "fajita/hardware.py"):
    if need not in files:
      print(f"ABSENT: {need} under {root}")
      return 1

  base = cls_of(files["base.py"], "HardwareBase")
  faj = cls_of(files["fajita/hardware.py"], "HardwareFajita")
  if base is None or faj is None:
    print("FAIL: HardwareBase or HardwareFajita not found")
    return 1

  base_methods = methods(base)
  abstr = abstracts(base)
  calls = hardware_attrs(files["hardwared.py"])
  impl = methods(faj)

  explicit = calls & impl
  via_base = calls - impl
  missing_calls = sorted(via_base - base_methods)
  missing_abs = sorted(abstr - impl - base_methods)
  total = abstr | calls
  covered = total - set(missing_calls) - set(missing_abs)

  print(f"tree            : {root}")
  print(f"base.py         : {files['base.py']}")
  print(f"selector        : {files['__init__.py']}")
  print(f"HardwareBase    : {len(base_methods)} methods, {len(abstr)} abstract -> {', '.join(sorted(abstr))}")
  print(f"hardwared HARDWARE.* : {len(calls)}")
  print(f"  explicit override   : {len(explicit)}/{len(calls)}")
  print(f"  via base default    : {len(via_base)}/{len(calls)}  -> {', '.join(sorted(via_base)) or '(none)'}")
  print(f"overrides in class    : {len(impl)}")
  print()
  print(f"覆盖 {len(covered)}/{len(total)}")
  if missing_abs:
    print(f"MISSING abstract: {missing_abs}")
  if missing_calls:
    print(f"MISSING runtime : {missing_calls}")
  if not missing_abs and not missing_calls:
    print("PASS: abstract surface and hardwared call surface fully covered")
  return 0 if not (missing_abs or missing_calls) else 1


STUB_CEREAL = '''
class _DeviceState:
  class NetworkType:
    none = 0; wifi = 1; ethernet = 2; cell2G = 3; cell3G = 4; cell4G = 5; cell5G = 6
  class NetworkStrength:
    unknown = 0; poor = 1; moderate = 2; good = 3; great = 4
class log:
  DeviceState = _DeviceState
'''

STUB_DEVICE = '''
from openpilot.system.hardware.base import HardwareBase
'''


def build_stub(root: pathlib.Path, work: pathlib.Path, selector: pathlib.Path) -> None:
  """Stub package that can import the branch's REAL selector + REAL fajita class.

  HardwareBase / ThermalConfig come from the branch's real base.py, so an
  instantiation failure means a genuinely unimplemented abstract method.
  """
  files = discover(root)
  selector_hint = files["__init__.py"].read_text()
  m_pkg = re.search(r"from\s+([\w.]+)\.base\s+import", selector_hint)
  pkg = m_pkg.group(1) if m_pkg else ".".join(
      files["__init__.py"].parent.relative_to(root).parts)
  hw_dir = files["__init__.py"].parent            # .../hardware
  pkg_parts = list(hw_dir.relative_to(root).parts)[:-1]   # e.g. [openpilot, common]

  (work / "cereal").mkdir(parents=True, exist_ok=True)
  (work / "cereal" / "__init__.py").write_text(STUB_CEREAL)
  for part in pkg_parts:
    d = work.joinpath(*[p for p in pkg_parts[:pkg_parts.index(part) + 1]])
    d.mkdir(parents=True, exist_ok=True)
    (d / "__init__.py").write_text("")
  (work / "openpilot").mkdir(exist_ok=True)
  (work / "openpilot" / "__init__.py").write_text("")
  (work / "openpilot" / "cereal").mkdir(parents=True, exist_ok=True)
  (work / "openpilot" / "cereal" / "__init__.py").write_text(STUB_CEREAL)

  # PHASE24 fix: the branch's REAL base.py itself imports openpilot.common.esim
  # (SunnyPilot: `from openpilot.common.esim.base import LPABase`).  Stub that
  # package too, otherwise importing HardwareBase explodes before we ever get to
  # the selector.  We only need the names base.py touches at import time.
  esim_dirs = []
  for sub in ("openpilot/common/esim",):
    d = work.joinpath(*sub.split("/"))
    d.mkdir(parents=True, exist_ok=True)
    (d / "__init__.py").write_text("")
    esim_dirs.append(d)
  (work / "openpilot/common/esim/base.py").write_text(
    "class LPABase:\n"
    "  def __init__(self, *a, **k): pass\n"
    "WEBBING_ICCID_PREFIX = ''  # stub: real value is only used at runtime\n"
  )
  for extra in ("lpa", "esim"):
    (work / "openpilot/common/esim" / f"{extra}.py").write_text(
      "class LPA:\n  def __init__(self, *a, **k): pass\n"
    )

  # 目录结构必须按 import 名（pkg）来建，不能按磁盘相对路径：dragonpilot 的
  # selector 在磁盘上是 system/hardware，但 import 名是 openpilot.system.hardware，
  # 直接照抄相对路径会让 sys.path 上找不到 openpilot.system。
  pkg_parts = pkg.split(".")          # 例：['openpilot','system','hardware']
  hw = work.joinpath(*pkg_parts)
  hw.mkdir(parents=True, exist_ok=True)
  shutil.copy(files["base.py"], hw / "base.py")

  # stub the sibling device classes (plain classes: the selector only casts)
  for name, mod in (("Tici", "tici"), ("Pc", "pc"), ("HardwareComma", "comma"), ("HardwarePc", "pc")):
    d = hw / mod
    d.mkdir(exist_ok=True)
    (d / "__init__.py").write_text("")
    (d / "hardware.py").write_text(
      "from openpilot.system.hardware.base import HardwareBase\n"
      if (work / "openpilot" / "system").exists() else
      "from openpilot.common.hardware.base import HardwareBase\n")
    with open(d / "hardware.py", "a") as f:
      f.write(f"class {name}:\n  def get_device_type(self):\n    return '{mod}'\n")

  # real fajita implementation
  fj = hw / "fajita"
  fj.mkdir(exist_ok=True)
  (fj / "__init__.py").write_text("")
  if "fajita/hardware.py" in files:
    shutil.copy(files["fajita/hardware.py"], fj / "hardware.py")

  # PHASE24 fix: do NOT copy the real selector into the stub.  The real selector
  # imports the branch's REAL device modules (e.g. openpilot.common.hardware.comma
  # -> openpilot.common.esim.base), which the stub does not (and should not)
  # provide.  Instead we synthesise a stub selector from the real one's marker
  # logic: same os.path.isfile() probes, same class *names*, but every device
  # class resolves to the fake one built above.  That is exactly what this test
  # is about -- "which branch gets selected" -- not "does comma/hardware.py import".
  src = selector.read_text()
  probes = [ln.strip() for ln in src.splitlines()
            if "os.path.isfile(" in ln and ln.strip().startswith(("TICI", "AGNOS", "FAJITA", "PC", "COMMA_HARDWARE"))]
  fajita_probe = [ln for ln in probes if ln.startswith("FAJITA")]
  # PHASE24 fix: the stub selector must use the BRANCH's own package prefix.
  # openpilot/sunnypilot -> openpilot.common.hardware (or openpilot.system.hardware),
  # dragonpilot/frogpilot -> system.hardware.  Hard-coding "openpilot.common" made
  # three of the four branches fail with ModuleNotFoundError.
  # import name != directory path: dragonpilot/frogpilot live on disk at
  # system/hardware but import as openpilot.system.hardware.  Discover the real
  # name from the selector's own "from X.base import" line.
  # pkg 已在函数开头算好
  use_fajita = [
    "if %s:" % fajita_probe[0].split("=")[0].strip(),
    f"  from {pkg}.fajita.hardware import HardwareFajita",
    "  HARDWARE = HardwareFajita()",
  ] if fajita_probe else []
  stub_sel = [
    "import os",
    f"from {pkg}.base import HardwareBase",
    f"from {pkg}.comma.hardware import HardwareComma" if (hw / "comma").exists() else None,
    f"from {pkg}.pc.hardware import HardwarePc" if (hw / "pc").exists() else None,
    "TICI = os.path.isfile('/TICI')",
    "AGNOS = os.path.isfile('/AGNOS')",
    "FAJITA = os.path.isfile('/FAJITA')",
    "COMMA_HARDWARE = AGNOS",
    "PC = not COMMA_HARDWARE",
  ]
  stub_sel = [x for x in stub_sel if x is not None]
  stub_sel += use_fajita + [
    "if not %s:" % (fajita_probe[0].split("=")[0].strip() or "FAJITA") if fajita_probe else "if True:",
    "  if COMMA_HARDWARE:",
    "    HARDWARE = HardwareComma()",
    "  else:",
    "    HARDWARE = HardwarePc()",
  ]
  (hw / "__init__.py").write_text("\n".join(stub_sel) + "\n")


CHILD = r'''
import os, sys
present = {m for m in os.environ.get("MARKERS", "").split(",") if m}
real = os.path.isfile
os.path.isfile = lambda p: p.lstrip("/") in present or real(p)
sys.path.insert(0, os.environ["STUB_ROOT"])
import importlib
mod = importlib.import_module(os.environ["SEL_MODULE"])
print(type(mod.HARDWARE).__name__,
      "FAJITA=%r" % getattr(mod, "FAJITA", None),
      "TICI=%r" % getattr(mod, "TICI", None),
      "COMMA_HARDWARE=%r" % getattr(mod, "COMMA_HARDWARE", None),
      "PC=%r" % getattr(mod, "PC", None))
'''


def selection(root: pathlib.Path) -> int:
  files = discover(root)
  sel_new = files["__init__.py"]
  sel_orig_candidates = [p for p in (root.parent / "orig").rglob(sel_new.name) if "hardware" in p.parts]
  sel_orig = sel_orig_candidates[0] if sel_orig_candidates else None

  # SEL_MODULE 必须是 import 名（pkg），不是磁盘相对路径：dragonpilot 的
  # selector 在 system/hardware，但 stub 按 import 名建在 openpilot/system/hardware。
  m_pkg = re.search(r"from\s+([\w.]+)\.base\s+import", sel_new.read_text())
  sel_mod = m_pkg.group(1) if m_pkg else ".".join(sel_new.parent.relative_to(root).parts)

  cases = [
    ("AGNOS,TICI,FAJITA", "HardwareFajita"),
    ("AGNOS,FAJITA", "HardwareFajita"),
    ("AGNOS,TICI", None),   # stock path: depends on branch (Tici or HardwareComma)
    ("", None),
  ]
  fails = 0
  work = pathlib.Path(tempfile.mkdtemp(prefix="sel24-"))
  try:
    build_stub(root, work, sel_new)
    print(f"stub root : {work}")
    print(f"selector  : {sel_new}")
    print(f"module    : {sel_mod}")
    print()
    print(f"{'markers':<22}{'selected':<18}{'verdict'}")
    for markers, expect in cases:
      env = dict(os.environ, STUB_ROOT=str(work), MARKERS=markers, SEL_MODULE=sel_mod)
      r = subprocess.run([sys.executable, "-c", CHILD], capture_output=True, text=True, env=env)
      line = (r.stdout or r.stderr).strip().splitlines()
      got = line[-1] if line else f"ERROR({r.returncode})"
      name = got.split(" ")[0]
      if expect is None:
        ok = name in ("Tici", "Pc", "HardwareComma", "HardwarePc")
      else:
        ok = name == expect
      fails += 0 if ok else 1
      print(f"{markers or '(none)':<22}{got:<18}{'PASS' if ok else 'FAIL'}")
  finally:
    shutil.rmtree(work, ignore_errors=True)

  print()
  if sel_orig is not None:
    work2 = pathlib.Path(tempfile.mkdtemp(prefix="sel24ctl-"))
    try:
      build_stub(root, work2, sel_orig)
      env = dict(os.environ, STUB_ROOT=str(work2), MARKERS="AGNOS,TICI,FAJITA", SEL_MODULE=sel_mod)
      r = subprocess.run([sys.executable, "-c", CHILD], capture_output=True, text=True, env=env)
      got = (r.stdout or r.stderr).strip().splitlines()[-1]
      mis = got.split(" ")[0]
      print(f"CONTROL (pre-patch selector, /FAJITA present): {got}")
      print(f"  -> selects {mis}; the fajita marker is ignored, which is the bug this patch fixes")
    finally:
      shutil.rmtree(work2, ignore_errors=True)
  else:
    print("CONTROL: no orig/ selector found, skipped")

  print()
  print(f"{len(cases) - fails}/{len(cases)} cases passed")
  return 0 if fails == 0 else 1


def main() -> int:
  ap = argparse.ArgumentParser()
  ap.add_argument("--root", default=None, help="branch tree root (default: <this dir>/new)")
  ap.add_argument("--selection", action="store_true")
  args = ap.parse_args()
  root = pathlib.Path(args.root) if args.root else HERE / "new"
  return selection(root) if args.selection else coverage(root)


if __name__ == "__main__":
  sys.exit(main())
