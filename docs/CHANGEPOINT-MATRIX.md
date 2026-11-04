# fajita × AGNOS 改造点矩阵

图例：难度 D1(改配置) < D2(改脚本/DT) < D3(写驱动) < D4(写 HAL)
风险：R1(不影响启动) < R2(可回退) < R3(需上机验证) < R4(可能砖)

| # | 模块 | 现状（实测） | 需要改什么 | 难度 | 风险 |
|---|---|---|---|---|---|
| 1 | DTS compatible | `agnos-kernel-sdm845/Makefile` 只编 `comma_tizi/mici/ultimate_provisioning.dtb`；`comma.sh` grep `mici`、`gpio.sh` grep `comma tici`。LineageOS 侧 fajita 只有 **dtbo 插件**（`fajita-*.dtbo-base := sdm845-v2.1.dtb`），**没有可 append 的整机 DT** | 新增 `comma_fajita.dts`（基于 `sdm845-v2.1-mtp.dtsi`）+ Makefile 一行；`model = "comma fajita"` 让 `comma.sh` 的 tici/mici 分支自然走 else 分支 | D2 | R2 |
| 2 | 内核 cmdline | tici: 8 核 `isolcpus=6,7`（只隔离 2 核）。fajita 同为 8 核 4×A75(2.8G)+4×A55(1.8G)，AGNOS 的 `comma.sh` 按 `policy0/policy4` 两簇调频 | 改 `AGNOS_CMDLINE`：`isolcpus=1-7 nohz_full=1-7 rcu_nocbs=1-7 irqaffinity=0`（cpu0 = IRQ/housekeeping，1-7 给 openpilot）；去掉 `ehci-hcd.park`、`service_locator` | D1 | R2 |
| 3 | 相机 camx/CHI | rootfs 侧实测：镜像里**无** `libcamera*`/`camx*`/`chi*`/`v4l2` 用户库；内核侧 `CONFIG_SPECTRA_CAMERA=y`（可用） | **无 Android HAL 可用**。绕行：内核保留 SPECTRA（DT 里 `&cam_cci` 关掉以省 probe 时间），用户态走 `v4l2-ctl`（`CONFIG_MSM_VIDC_V4L2` 只覆盖编解码，ISP 出片需 QMMF——不存在）。**建议先用 USB UVC 摄像头过渡**（`CONFIG_USB_VIDEO_CLASS` 需补） | D4 | R4 |
| 4 | 显示 Weston/DRM | rootfs **不装 Weston**：`magic.service` 跑 raylib→EGL/GBM→`/dev/dri/card0`，并把 DRM master 通过 `SCM_RIGHTS` 给客户端；`libEGL_adreno.so`+`libgbm.so.1` 是 comma 打包的 A630 blob | 内核 `CONFIG_DRM_MSM=y` + `CONFIG_DRM_FBDEV_EMULATION` 已满足；fajita 面板 s6e3fc2x01 需 DT 节点；backlight 名 `panel0-backlight` 是 tici 特有（`94-backlight.rules` 硬编码）→ 要么改 DT 名要么改 rules | D2 | R3 |
| 5 | 触摸 synaptics s3320 | LineageOS DT: `qupv3_se12_i2c` / `HWK,synaptics,s3320` / reg `0x20` / IRQ tlmm 125 / reset 99 | `CONFIG_TOUCHSCREEN_SYNAPTICS_S3320_I2C_RMI=y`（LineageOS defconfig 已有）；AGNOS 侧只需 `93-input.rules`（已有，chmod 666） | D1 | R2 |
| 6 | IMU | tici 用 `CONFIG_INV_MPU_IIO_ICM42600` + `INPUT_HBTP_INPUT`；fajita 是 **LSM6DSL + AK09918**，在 OnePlus 的 `oneplus,sensorhub` SPI 桥后面 | 需确认 fajita 是否 I2C 直挂；若是则加 `st,lsm6dsl`/`ak09918` IIO 驱动配置；`CONFIG_INPUT_HBTP_INPUT` 可保留（无设备则不 probe） | D3 | R3 |
| 7 | GPS | tizi 有独立 GPS 模块（`gpio.sh` 里 `GPS_PWR_EN`=34 等）；**fajita 无该硬件**，只有 modem 侧 GNSS | `gpio.service` 会死等 gpio 节点（已打补丁跳过）；openpilot 需 `ublox` 类源 → **fajita 无可用 GPS**，只能靠 modem GNSS（未验证） | D3 | R4 |
| 8 | 音频 | `sound_init.sh` 死等 `/proc/asound/sdm845tavilsndc`；`amplifier.py` 是 MAX98089（tici）。fajita 是 **TFA9894 @ qupv3_se4** | 内核有 `CONFIG_SND_SOC_MACHINE_SDM845`（generic-codec）；补 `generic-codec` DT 节点使 card 出现；amp 无 Linux 驱动（需自写，或先不驱动） | D3/D4 | R3 |
| 9 | USB host | `CONFIG_USB_DWC3_DUAL_ROLE` + `extcon_usb1`（`pmi8998_gpios 8`）；tici 还有 `gpio.sh` 里 `HUB_RST_N`(30) 等 hub GPIO | fajita 无 hub 控制 GPIO，`gpio.service` 已跳过；USB3 panda 需 `usb_qmp_phy` ok | D1 | R1 |
| 10 | rootfs 服务 | `services.sh` 无条件 `systemctl enable cdsp`（fajita 无 CDSP 节点）；`comma.sh` 读 `input2/device/touch_count`（fajita 触摸驱动无此属性） | 两处加存在性判断 | D1 | R1 |
| 11 | systemd 配置 | tici_defconfig 里 `# CONFIG_FANOTIFY is not set`、`# CONFIG_ION`/`KGSL` 有、`DEVTMPFS` 有 | fragment 里补 `FANOTIFY=y`、`ION=y`、`ION_MSM=y`、`MEMCG`、`SECCOMP_FILTER` | D1 | R2 |

## 结论

- **能靠补丁解决**：1、2、4(部分)、5、9、10、11 → 已交付。
- **需要额外代码**：6、8（驱动配置/DT 无设备则不 probe，风险可控）。
- **硬缺口**：3（相机 HAL）、7（GPS 硬件）—— 不是补丁能解决的，必须降级方案（USB 摄像头 / modem GNSS）。
