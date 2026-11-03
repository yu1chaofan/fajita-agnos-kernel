# fajita-agnos-kernel

OnePlus 6T (fajita, SDM845) 的 AGNOS 内核构建仓库。

## 目标

用 **LineageOS 内核**替换 comma 的 agnos-kernel，因为 LineageOS 版本已包含
6T 全部板级适配（fajita DTS、s6e3fc2x01 面板、synaptics s3320 触摸、
camera_oneplus 框架），可省掉约 73 小时的驱动移植工作。

## 为什么这个仓库只有 CI 配置

内核源码 1.2 GB，超过 GitHub 单次 push 限制。所以：

- 本仓库只放 **workflow + 补丁**
- 内核源码在 Action 运行时 `git clone --depth 1` 拉取
- 产物通过 Artifacts 上传

## 使用

### 手动触发

GitHub → Actions → "Build AGNOS Kernel for OnePlus 6T (fajita)" → Run workflow

可配置参数：

| 参数 | 默认值 | 说明 |
|---|---|---|
| kernel_repo | LineageOS/android_kernel_oneplus_sdm845 | 内核源码仓库 |
| kernel_branch | lineage-22.2 | 分支 |
| defconfig | enchilada_defconfig | 6/6T 同平台配置 |
| variant | perf | 合并 vendor/sdm845-perf_defconfig |

### 产物

Actions 运行结束后，Artifacts 里会有：

```
fajita-kernel-<run_number>/
├── Image.gz-dtb           内核镜像（已内嵌 DTB）
├── kernel.config          实际使用的配置
├── SHA256SUMS.txt         校验和
└── *fajita*.dtbo          设备树 overlay（若有）
```

## 关键配置项（AGNOS 必需）

workflow 会强制写回并校验这些：

| CONFIG | 作用 |
|---|---|
| `CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y` | 6T bootloader 要求 DTB 内嵌 |
| `CONFIG_ANDROID=y` | AGNOS 的 Android 兼容层 |
| `CONFIG_ANDROID_BINDER_IPC=y` | binder 协议 |
| `CONFIG_IKCONFIG_PROC=y` | /proc/config.gz，AGNOS 版本校验用 |
| `CONFIG_USB_CONFIGFS=y` + `_NCM` | AGNOS 的 USB 网络 |
| `CONFIG_SECURITY_SELINUX=y` | 但 cmdline 需 permissive |
| `CONFIG_SPECTRA_CAMERA=y` | 相机框架 |
| `CONFIG_SCAN_UFS_QCOM=y` | UFS 存储 |

## 刷入后还需要做的（cmdline）

AGNOS 启动需要在 boot.img 的 cmdline 里加：

```
init=/init          # AGNOS 的自定义 init，不是 Android init
selinux=permissive  # 或 selinux=0
```

这三条（含 IKCONFIG_PROC）是"内核能起但系统起不来"的常见原因。

## 构建平台

使用 `ubuntu-24.04-arm`（原生 arm64 runner）：

- 公开仓库免费
- 不需要交叉编译工具链
- 比 x64 交叉编译快

## 许可

内核源码遵循各自上游许可（LineageOS 分支基于 Qualcomm msm-4.9，GPLv2）。
本仓库的 CI 配置为 MIT。


<!-- trigger build: WERROR disabled, hard checks added -->
