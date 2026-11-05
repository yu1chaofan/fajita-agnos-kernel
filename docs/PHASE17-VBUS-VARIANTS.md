# PHASE17 — USB host VBUS 5 V, one boot.img per variant

PHASE15 made `dwc3@a600000` (the 6T Type-C controller) come up as a host, but
nothing drives 5 V onto VBUS, so a panda plugged into the port never powers up.
This note records the four candidate mechanisms and which boot.img carries
which one. Build them all at once (matrix of 4), flash one at a time.

Everything below is a *kernel DT* change. No driver patch, no userspace patch.

## What the reference design does

| Board | 5 V generator | DT binding |
|---|---|---|
| `sdm845-mtp` | external boost chip, enabled by pmi8998 gpio10 | `ext_5v_boost` regulator-fixed (sdm845-pmic-overlay.dtsi) + `&ext_5v_boost { status = "ok" }` (sdm845-mtp.dtsi:343) |
| `sdm845-cdp` | external boost chip, enabled by pmi8998 gpio2 | `usb1_vbus_vreg` regulator-fixed, consumed as `vbus_dwc3-supply` (sdm845-cdp.dtsi:166, :352) |
| **OnePlus 6T (fajita)** | **PMI8998 SMB2 internal OTG boost** | `&pmi8998_pdphy { vbus-supply = <&smb2_vbus>; }` (fajita.dtsi:724); `op,vbus-ctrl-gpio = <&pmi8998_gpios 3 GPIO_ACTIVE_LOW>` is only `gpio_request()`ed, never driven |

`smb2_vbus` is `qcom,smb2-vbus` under `&pmi8998_charger`; enabling it writes
`OTG_EN_BIT` to `CMD_OTG_REG` (smb-lib.c `_smblib_vbus_regulator_enable`), i.e.
it turns on the PMIC's own 5 V boost on VBUS. That is the 6T's real generator.
`ext_5v_boost` on gpio10 is **not** the 6T's: on fajita gpio10 is `usb_sw`
(`GPIO_ACTIVE_LOW`), so leaving the MTP regulator enabled lets its probe drive
that pin.

## The four variants

`VBUS_VARIANT` is stamped into every artifact (`VBUS_VARIANT` file) and every
artifact name (`fajita-boot-v3-<run>`).

### v1 — B-1: let dwc3-msm enable the PMIC OTG boost

```dts
&ext_5v_boost { status = "disabled"; };
&pmi8998_pdphy { vbus-supply = <&smb2_vbus>; };
&usb0 {
	vbus_dwc3-supply = <&smb2_vbus>;
	qcom,no-vbus-vote-with-type-C;
};
```

`dwc3-msm` fetches `vbus_dwc3` lazily in `dwc3_otg_start_host()` and gates it on
`type_c`:

```c
/* dwc3-msm.c:4305 */
if (!mdwc->vbus_reg && (!mdwc->type_c ||
			(mdwc->type_c && !mdwc->no_vbus_vote_type_c))) {
	mdwc->vbus_reg = devm_regulator_get_optional(mdwc->dev, "vbus_dwc3");
```

`mdwc->type_c` defaults to **true** (`dwc3-msm.c:4003`), so without
`qcom,no-vbus-vote-with-type-C` the regulator is never even looked up. With it,
`DRD_STATE_HOST_IDLE -> dwc3_otg_start_host(1) -> regulator_enable(smb2_vbus)`
turns the boost on. Note the property name: `devm_regulator_get_optional(dev,
"vbus_dwc3")` resolves `vbus_dwc3-supply`, **not** `vbus-supply`.

### v2 — B-1 + forced OTG boost

v1 plus `&smb2_vbus { regulator-always-on; regulator-boot-on; };` — the boost
comes up at `regulator_init_complete` regardless of the dwc3 state machine. Use
when v1 boots but VBUS stays dead, or to tell "regulator never enabled" apart
from "regulator enabled but the host path bailed".

### v3 — B-2: drive pmi8998 gpio2 high

`ext_5v_boost` disabled, plus an always-on regulator-fixed on
`&pmi8998_gpios 2 GPIO_ACTIVE_HIGH` (the CDP boost-enable pin). gpio2 is unused
in every fajita/enchilada DT. This is the "there is an external boost chip after
all, and gpio2 arms it" hypothesis; it does **not** touch the dwc3 supply, so it
cannot regress PHASE15.

### v4 — B-3: assert pmi8998 gpio3 (ACTIVE_LOW)

`ext_5v_boost` disabled, plus an always-on regulator-fixed on
`&pmi8998_gpios 3 GPIO_ACTIVE_LOW` — the pin fajita.dtsi calls
`op,vbus-ctrl-gpio`. qpnp-smb2 only `gpio_request()`s it, so its boot level is
whatever the bootloader left. `GPIO_ACTIVE_LOW` in DT maps to `GPIOF_ACTIVE_LOW`
in `regulator-fixed`, so "enabled" drives it **low**. Also no dwc3 supply
change.

## Verification

`scripts/verify_dtb.py <variant> <dtc -O dts output>` runs in CI against the
built DTB and asserts, per variant:

* PHASE15 invariants survive: `dwc3@a600000` `dr_mode="host"`, usb0 `extcon`
  detached from the PD PHY;
* `ext_5v_boost` is `status = "disabled"` (never drove the 6T `usb_sw` line);
* v1/v2: `usb0`'s `vbus_dwc3-supply` **phandle-equals** the `smb2-vbus` node,
  `pmi8998_pdphy`'s `vbus-supply` points at the same node, and
  `qcom,no-vbus-vote-with-type-C` is present;
* v2: `smb2-vbus` carries `regulator-always-on`;
* v3/v4: the gpio regulator exists, is always-on, and its `gpio` cell is 2 / 3
  with the right polarity.

The same script against the PHASE15 DTB is the negative control: it fails on
exactly the three v1 assertions (missing supply, unused `smb2-vbus` phandle,
missing `qcom,no-vbus-vote-with-type-C`).

## Rollback

Flash the PHASE15 image back:
`phase15/kit/boot-phase15-usbhost.img` (50,300,928 B,
sha256 `9dddab7f…`), or any of the vN images — they share the PHASE15 base and
differ only in the appended DT block.
