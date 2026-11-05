#!/usr/bin/env python3
"""Verify a PHASE17 USB-host VBUS variant inside a decompiled comma_fajita DTS.

usage: verify_dtb.py <variant 1..4> <dtc -I dtb -O dts output>

Every assertion prints "PHASE17-OK: ..." or "PHASE17-FAIL: ..." and the exit
status is non-zero when anything failed.  Nothing here reads the source DTS:
the point is to prove the *built* blob carries what we think it carries.
"""
import re
import sys

PROP = re.compile(r'^\s*([A-Za-z0-9,._+/#@:-]+)\s*(?:=\s*(.*?))?;\s*$')
NODE = re.compile(r'^\s*([A-Za-z0-9,._+/#@:-]+)\s*\{\s*$')


def parse(path):
    """Return {node-path: {prop: raw-value-string}} plus phandle map."""
    nodes = {}
    stack = ['']
    with open(path, encoding='utf-8', errors='replace') as fh:
        for raw in fh:
            line = raw.rstrip('\n')
            stripped = line.strip()
            if stripped.startswith('//') or stripped.startswith('/*'):
                continue
            m = NODE.match(line)
            if m:
                name = m.group(1)
                if name == '/':          # root node: keep the empty prefix
                    stack.append('')
                    nodes.setdefault('', {})
                else:
                    stack.append(stack[-1] + '/' + name)
                    nodes.setdefault(stack[-1], {})
                continue
            if stripped.startswith('};'):
                if len(stack) > 1:
                    stack.pop()
                continue
            if stripped.startswith('/dts-v1/') or stripped == '/' or \
                    stripped.startswith('/memreserve/'):
                continue
            m = PROP.match(line)
            if m and len(stack) > 1:
                nodes[stack[-1]][m.group(1)] = (m.group(2) or '').strip()
    return nodes


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    variant = int(sys.argv[1])
    nodes = parse(sys.argv[2])
    fails = []

    def ok(msg):
        print("PHASE17-OK: %s" % msg)

    def bad(msg):
        fails.append(msg)
        print("PHASE17-FAIL: %s" % msg)

    def find(substr):
        for path in nodes:
            if substr in path.rsplit('/', 1)[-1]:
                return path
        return None

    def phandle_of(path):
        props = nodes[path]
        for key in ('phandle', 'linux,phandle'):
            if key in props:
                m = re.search(r'0x([0-9a-fA-F]+)', props[key])
                if m:
                    return int(m.group(1), 16)
        return None

    def by_regulator_name(name):
        want = '"%s"' % name
        for path, props in nodes.items():
            if props.get('regulator-name') == want:
                return path
        return None

    # ---- invariants from PHASE15 that must survive -----------------------
    usb0 = find('ssusb@a600000')
    if not usb0:
        bad("ssusb@a600000 (usb0) node missing")
    else:
        ok("ssusb@a600000 present at %s" % usb0)

    dwc3 = find('dwc3@a600000')
    if not dwc3 or nodes[dwc3].get('dr_mode') != '"host"':
        bad("dwc3@a600000 dr_mode != host (PHASE15 regression)")
    else:
        ok("dwc3@a600000 dr_mode=host (PHASE15 intact)")

    if usb0 and not nodes[usb0].get('extcon', '').startswith('<0x00 0x00'):
        bad("usb0 extcon not detached: %r" % nodes[usb0].get('extcon'))
    elif usb0:
        ok("usb0 extcon detached")

    # ---- ext_5v_boost must stay off: gpio10 is the 6T usb_sw line --------
    ext5 = by_regulator_name('ext_5v_boost')
    if ext5 and nodes[ext5].get('status') != '"disabled"':
        bad("ext_5v_boost is not disabled (pmi8998 gpio10 = 6T usb_sw)")
    elif ext5:
        ok("ext_5v_boost disabled")
    else:
        print("PHASE17-WARN: ext_5v_boost node absent")

    smb2 = by_regulator_name('smb2-vbus')

    if variant in (1, 2):
        if not smb2:
            bad("qcom,smb2-vbus regulator node missing")
        else:
            ok("smb2-vbus present at %s" % smb2)
            want = phandle_of(smb2)
            got = nodes[usb0].get('vbus_dwc3-supply') if usb0 else None
            if want is None:
                bad("smb2-vbus has no phandle -> nothing references it")
            elif not got or int(re.search(r'0x([0-9a-fA-F]+)', got).group(1), 16) != want:
                bad("usb0 vbus_dwc3-supply=%r, expected phandle 0x%x" % (got, want))
            else:
                ok("usb0 vbus_dwc3-supply -> smb2-vbus (0x%x)" % want)
            pdphy = find('usb-pdphy@1700')
            if pdphy and want is not None:
                pv = nodes[pdphy].get('vbus-supply', '')
                m = re.search(r'0x([0-9a-fA-F]+)', pv)
                if not m or int(m.group(1), 16) != want:
                    bad("pmi8998_pdphy vbus-supply=%r != smb2-vbus" % pv)
                else:
                    ok("pmi8998_pdphy vbus-supply -> smb2-vbus")
        if usb0 and 'qcom,no-vbus-vote-with-type-C' not in nodes[usb0]:
            bad("qcom,no-vbus-vote-with-type-C missing on usb0 "
                "(dwc3-msm never fetches the vbus regulator without it)")
        elif usb0:
            ok("qcom,no-vbus-vote-with-type-C present on usb0")

    if variant == 2:
        if smb2 and 'regulator-always-on' not in nodes[smb2]:
            bad("smb2-vbus lacks regulator-always-on")
        elif smb2:
            ok("smb2-vbus forced always-on")

    if variant == 3:
        node = by_regulator_name('usb-vbus-boost-gpio2')
        if not node:
            bad("usb-vbus-boost-gpio2 regulator missing")
        else:
            ok("usb-vbus-boost-gpio2 present")
            if 'regulator-always-on' not in nodes[node]:
                bad("usb-vbus-boost-gpio2 lacks regulator-always-on")
            else:
                ok("usb-vbus-boost-gpio2 always-on")
            m = re.search(r'0x[0-9a-fA-F]+ 0x([0-9a-fA-F]+)',
                          nodes[node].get('gpio', ''))
            if not m or int(m.group(1), 16) != 2:
                bad("usb-vbus-boost-gpio2 gpio cell != 2: %r"
                    % nodes[node].get('gpio'))
            else:
                ok("usb-vbus-boost-gpio2 drives pmi8998 gpio2")

    if variant == 4:
        node = by_regulator_name('usb-vbus-ctrl-gpio3')
        if not node:
            bad("usb-vbus-ctrl-gpio3 regulator missing")
        else:
            ok("usb-vbus-ctrl-gpio3 present")
            m = re.search(r'0x[0-9a-fA-F]+ 0x([0-9a-fA-F]+)',
                          nodes[node].get('gpio', ''))
            if not m or int(m.group(1), 16) != 3:
                bad("usb-vbus-ctrl-gpio3 gpio cell != 3: %r"
                    % nodes[node].get('gpio'))
            else:
                ok("usb-vbus-ctrl-gpio3 drives pmi8998 gpio3")
            if 'enable-active-high' in nodes[node]:
                bad("usb-vbus-ctrl-gpio3 has enable-active-high "
                    "(fajita declares the line ACTIVE_LOW)")
            else:
                ok("usb-vbus-ctrl-gpio3 keeps the ACTIVE_LOW polarity")

    if fails:
        print("\n%d assertion(s) failed for variant %d" % (len(fails), variant))
        return 1
    print("\nall assertions passed for variant %d" % variant)
    return 0


if __name__ == '__main__':
    sys.exit(main())
