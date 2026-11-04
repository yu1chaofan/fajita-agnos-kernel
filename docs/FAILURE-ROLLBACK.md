# 构建失败回退矩阵 (fajita AGNOS)

每一行 = 一个构建阶段 + 该阶段的**判定信号** + **退一级目标** + **具体回退命令**。
原则：任何阶段失败都退到「上一个已产出可用产物的阶段」，不整链重来。

| # | 阶段 | 失败信号 | 一级回退（保留已得产物） | 二级回退（换方案） |
|---|---|---|---|---|
| S0 | `materialize.sh` 拉源码 | `is not at <sha>` / fetch 失败 | 把 `repos.lock` 的 COMMIT 换成 `agnos-builder` 的上一 tag；LineageOS 侧换 `refs/heads/lineage-22.2` 的最新 sha | 改用 `LINEAGE_KERNEL_COMMIT` 对应 tag `lineage-22.2` 的 tar 包（`codeload.github.com/.../tar.gz/<sha>`），跳过 git |
| S1 | 打补丁 | `git apply` 冲突 | `git apply --3way`；仍冲突则 `patch -p1 --fuzz=3` | 只保留 `0002-configs`（配置类），DT 改用「直接 cp 到 dts 目录」而不是 patch |
| S2 | 工具链 `extract_tools.sh` | 404 / 解压失败 | 用 runner 自带 `gcc-aarch64-linux-gnu`（apt），`build_kernel.sh` 已有交叉编译分支 | 在 workflow 里显式 `export CROSS_COMPILE=aarch64-linux-gnu-` |
| S3 | `olddefconfig` | 出现 `CONFIG_X` 被关闭警告 | 从 `agnos_fajita.fragment` 删掉该行（它本来就不是必需项） | 改为 `make tici_defconfig` 后再 `scripts/config --enable` 逐项补 |
| S4 | 内核编译 | `error:` 在某个驱动文件 | 从 fragment 关掉该驱动（`# CONFIG_X is not set`），保留其余 | 若错误在 `qcom` 通用代码，说明 LineageOS 源与 comma 私有补丁冲突 → 改用 S4-B（下） |
| S4-B | 冲突降级 | 多处 `qcom` 代码冲突 | 放弃 LineageOS 源，改用 **comma 源 + LineageOS 只拷 DT 文件**（`sdm845-*.dtsi` + 面板 DTI），`comma_fajita.dts` 不变 | 若 DT 也编不过，退回 `sdm845-mtp.dtb`（无 fajita 外设，能起但黑屏） |
| S5 | `Image-dtb` 生成 | 找不到 `Image-dtb` | 检查 `CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE` 是否确实=y（`grep out/.config`） | 手工 `cat Image + comma_fajita.dtb` 生成 dtb 附加镜像 |
| S6 | `mkbootimg.sh` | `openssl pkeyutl` 失败 | 用 `openssl rsautl -sign`（老接口） | 换 `tools/mkbootimg` 加 `--dt` 单独塞 DTB |
| S7 | 刷机后不亮屏 | 无 boot logo / 卡 bootloader | 先刷回 `output/boot.img` 的上一版（保留在 artifacts） | 用 `flash_kernel.sh` 刷 LineageOS 原厂 boot.img 验证硬件没砖 |
| S8 | systemd 起不来 | 串口卡 `Reached target Basic System` 前 | 见 `S8` 细则：cmdline 加 `systemd.log_level=debug earlyprintk` | 换 `init=/bin/sh` 直连故障点 |
| S9 | `system.img` 构建 | docker buildx 失败 | 只发 boot.img（rootfs 用 `agnos-port/rootfs/out/system_a.img` 已有产物） | 用 `build_system.sh` 的 `NS=1` 分支走远端 builder |

## S8 细则：系统起不来的四类根因

1. **cmdline 缺 `isolcpus` 之外的东西**：AGNOS 的 `comma.service` 依赖 `tmux`、`/usr/local/venv`，缺 `/data` 挂载会反复重启。看 `journalctl -b -u comma` （串口 `ttyMSM0`）。
2. **`fs_setup.service` 失败**：fstab 里 `/dev/disk/by-partlabel/userdata`；fajita 的分区表里 userdata 名字一致，但 `by-label/dsp` / `modem_a` 需要 `90-bootdevice.rules` 的 PARTNAME 链接 —— fajita 的 ufshc 是 `1d84000.ufshc`（同 SoC），规则可用；若 `/firmware` 空则 `sound.service` 会超时 → 已被本补丁改成跳过。
3. **SELinux**：cmdline 里 `androidboot.selinux=permissive` 已在；若 kernel 里 `CONFIG_SECURITY_SELINUX_BOOTPARAM` 关闭则该项无效，需 `security=selinux selinux=0`。
4. **display**：`magic.service` 起不来不影响 comma.service（后者只等待 20 s）。真黑屏先查 `dmesg | grep -i dsi` / `sde`。

## 每次回退必须留档

```
output/boot.img.<stage>.<sha>   每个阶段成功就 cp 一份
artifacts/SHA256SUMS.txt        每次上传都带
RUNNER / KERNEL_COMMIT          workflow 已自动写入
```
