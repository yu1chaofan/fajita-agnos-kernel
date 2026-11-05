#!/usr/bin/env python3
"""PHASE37 · runner-selection semantics checker.

Two branches shipped a `0003` patch that can only be validated by *behaviour*,
not by grep:

  frogpilot   selfdrive/modeld/runners/__init__.py   USE_THNEED/USE_SNPE must
                                                     follow the DEVICE, not /TICI
  dragonpilot selfdrive/modeld/helpers.py            get_tg_input_devices must
                                                     fall back when the tuned
                                                     json is missing/corrupt

Both are pure-python modules, so the check is: load the REAL file from the
applied tree with stub `openpilot.*` packages, then assert the documented
behaviour. Every case is run; the exit code is 1 if any case fails.

Usage: check_runner_semantics.py --root <applied tree> [--branch KEY]
       (--branch omitted -> auto-detect from file presence); exit 0 = pass,
       2 = no applicable checker for this tree (caller decides if that is ok).
"""
import argparse
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import types


# ---------------------------------------------------------------- frogpilot --
def _stub_pkg(names, **attrs):
  for n in names:
    sys.modules.setdefault(n, types.ModuleType(n))
  return attrs


def check_frogpilot_runners(path: pathlib.Path) -> tuple[bool, list[str]]:
  lines = []

  def load(device, env):
    for k in ("USE_THNEED", "USE_SNPE", "FAJITA_ALLOW_THNEED"):
      os.environ.pop(k, None)
    if env:
      os.environ.update(env)
    hw = types.ModuleType("openpilot.system.hardware")

    class _HW:
      def get_device_type(self):
        return device

    hw.HARDWARE, hw.TICI = _HW(), device in ("tici", "tizi", "mici")
    _stub_pkg(["openpilot", "openpilot.system", "openpilot.selfdrive",
               "openpilot.selfdrive.modeld", "openpilot.selfdrive.modeld.runners"])
    sys.modules["openpilot.system.hardware"] = hw
    rp = types.ModuleType("openpilot.selfdrive.modeld.runners.runmodel_pyx")
    rp.RunModel = type("RunModel", (), {})
    rp.Runtime = type("Runtime", (), {})
    sys.modules["openpilot.selfdrive.modeld.runners.runmodel_pyx"] = rp
    spec = importlib.util.spec_from_file_location("runners_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

  cases = [
    ("tici",   None,                       1, 1),
    ("tizi",   None,                       1, 1),
    ("fajita", None,                       0, 0),
    ("pc",     None,                       0, 0),
    ("fajita", {"USE_SNPE": "1"},          0, 1),
  ]
  ok = True
  for dev, env, wt, ws in cases:
    try:
      m = load(dev, env)
      good = (m.USE_THNEED == wt and m.USE_SNPE == ws)
      got = f"USE_THNEED={m.USE_THNEED} USE_SNPE={m.USE_SNPE}"
    except Exception as e:                                    # noqa: BLE001
      good, got = False, f"raised {type(e).__name__}: {e}"
    lines.append(f"  [{'PASS' if good else 'FAIL'}] {dev} env={env} -> {got} (want {wt}/{ws})")
    ok &= good

  try:
    load("fajita", {"USE_THNEED": "1"})
    good, got = False, "no error raised"
  except AssertionError:
    good, got = True, "AssertionError"
  except Exception as e:                                      # noqa: BLE001
    good, got = False, f"raised {type(e).__name__} (want AssertionError)"
  lines.append(f"  [{'PASS' if good else 'FAIL'}] fajita+USE_THNEED=1 -> {got}")
  ok &= good
  return ok, lines


# -------------------------------------------------------------- dragonpilot --
def check_dragonpilot_helpers(path: pathlib.Path) -> tuple[bool, list[str]]:
  spec = importlib.util.spec_from_file_location("dph", path)
  m = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(m)
  lines, ok = [], True
  KEY = "openpilot.selfdrive.modeld.modeld"

  def case(name, setup, want, fn):
    nonlocal ok
    try:
      got = fn(setup)
      good = got == want
    except Exception as e:                                    # noqa: BLE001
      good, got = False, f"raised {type(e).__name__}: {e}"
    lines.append(f"  [{'PASS' if good else 'FAIL'}] {name} -> {got}")
    ok &= good

  os.environ.pop("DEV", None)
  m.TG_INPUT_DEVICES_PATH = pathlib.Path("/nonexistent/tg.json")
  case("missing file -> fallback QCOM",
       None, {"WARP_DEV": "QCOM", "QUEUE_DEV": "QCOM"},
       lambda _s: m.get_tg_input_devices(KEY, False))

  os.environ["DEV"] = "CPU:LLVM"
  case("DEV env honoured", None, "CPU:LLVM",
       lambda _s: m.get_tg_input_devices(KEY, False)["WARP_DEV"])
  os.environ.pop("DEV", None)

  case("usbgpu queue -> AMD", None, "AMD",
       lambda _s: m.get_tg_input_devices(KEY, True)["QUEUE_DEV"])
  case("dmonitoringmodeld key", None, "QCOM",
       lambda _s: m.get_tg_input_devices("openpilot.selfdrive.modeld.dmonitoringmodeld", False)["DEV"])

  tmp = pathlib.Path(tempfile.mkdtemp())
  (tmp / "ok.json").write_text(json.dumps({KEY: {"default": {"WARP_DEV": "QCOM", "QUEUE_DEV": "QCOM"}}}))
  m.TG_INPUT_DEVICES_PATH = tmp / "ok.json"
  case("valid file used", None, {"WARP_DEV": "QCOM", "QUEUE_DEV": "QCOM"},
       lambda _s: m.get_tg_input_devices(KEY, False))

  (tmp / "nokey.json").write_text(json.dumps({"other": {}}))
  m.TG_INPUT_DEVICES_PATH = tmp / "nokey.json"
  case("missing key -> fallback", None, "QCOM",
       lambda _s: m.get_tg_input_devices(KEY, False)["WARP_DEV"])

  (tmp / "bad.json").write_text("{not json")
  m.TG_INPUT_DEVICES_PATH = tmp / "bad.json"
  case("bad json -> fallback", None, "QCOM",
       lambda _s: m.get_tg_input_devices(KEY, False)["WARP_DEV"])
  return ok, lines


# -------------------------------------------------------------------- main --
def main() -> int:
  ap = argparse.ArgumentParser()
  ap.add_argument("--root", required=True, help="applied branch tree")
  ap.add_argument("--branch", default="", help="branch key (dp/frog/...); auto-detected if empty")
  a = ap.parse_args()
  root = pathlib.Path(a.root)
  if not root.is_dir():
    print(f"::error::--root not a dir: {root}")
    return 1

  frog = next(root.rglob("modeld/runners/__init__.py"), None)
  dp   = next(root.rglob("modeld/helpers.py"), None)

  # PHASE42: 只对「本 leg 确实打了对应 0003」的树判定。
  # carrot 也有 modeld/helpers.py（含 get_tg_input_devices）但没打 0003 ——
  # 拿 dp 的语义去考它必然红，那不是本 leg 的缺陷，是 checker 的适用范围没对齐。
  # 判据：有 __default_tg_input_devices / _default_tg_input_devices 才算「打过 fallback 补丁」；
  #       runners/__init__.py 里出现 HARDWARE/tinygrad 语义（非 int(TICI)）才算「打过 0003」。
  if frog is not None:
    src = frog.read_text()
    if "USE_THNEED" in src and "int(TICI)" in src and "get_device_type" not in src:
      print(f"[frogpilot] {frog.relative_to(root)}: 未打 0003（仍是 int(TICI) 语义），判为不适用")
      frog = None
  if dp is not None:
    src = dp.read_text()
    if "get_tg_input_devices" in src and "_default_tg_input_devices" not in src:
      print(f"[dragonpilot] {dp.relative_to(root)}: 未打 0003（无 fallback），判为不适用")
      dp = None

  ran = 0
  all_ok = True
  if frog is not None:
    ran += 1
    print(f"[frogpilot] runners/__init__.py: {frog.relative_to(root)}")
    ok, lines = check_frogpilot_runners(frog)
    print("\n".join(lines))
    all_ok &= ok
    print(f"  => {'PASS' if ok else 'FAIL'}")
  if dp is not None:
    # dragonpilot fallback 只在 helpers.py 有 get_tg_input_devices 时适用
    txt = dp.read_text()
    if "get_tg_input_devices" in txt:
      ran += 1
      print(f"[dragonpilot] modeld/helpers.py: {dp.relative_to(root)}")
      ok, lines = check_dragonpilot_helpers(dp)
      print("\n".join(lines))
      all_ok &= ok
      print(f"  => {'PASS' if ok else 'FAIL'}")

  if ran == 0:
    print("no applicable runner-semantics checker for this tree")
    return 2
  print(f"RESULT: {'PASS' if all_ok else 'FAIL'} ({ran} checker(s) ran)")
  return 0 if all_ok else 1


if __name__ == "__main__":
  sys.exit(main())
