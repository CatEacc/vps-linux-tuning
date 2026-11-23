# Linux VPS 底层内核与内存调优指南（`vps-linux-tuning`）

[![Linux](https://img.shields.io/badge/Linux-Debian%20%7C%20Ubuntu-blue?logo=linux&logoColor=white)](#)
[![Kernel](https://img.shields.io/badge/Kernel-BBR%20%2B%20FQ-green)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Telegram](https://img.shields.io/badge/Telegram-%E7%8C%ABe%2Facc-26A5E4?logo=telegram)](https://t.me/CatCryptoMaster)

> **仓库地址**：`github.com/CatEacc/vps-linux-tuning`  
> **适用系统**：Debian 11 / 12 / 13、Ubuntu 20.04 / 22.04 / 24.04（AMD64 / ARM64），纯开源 Shell 文本无闭源二进制，方便直接审计。

---

## 一键执行（4 种模式 · 改前自动快照支持一键回滚）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CatEacc/vps-linux-tuning/main/tune.sh)
```

---

## 核心解决的 5 个运维痛点

1. **512M / 1G 小内存防 OOM（按内存分档网络缓冲）**：
   - 不再无脑套用 64MB 缓冲区导致小内存机器并发高时触发 OOM Killer。
   - 自动识别物理内存分三档：`<=700MB`（16M/8M/256K）、`700MB~1500MB`（32M/16M/512K）、`>=1500MB`（64M/32M/1M），配合 1GB Swap 兜底与 `vm.swappiness=10`。
2. **`/etc/sysctl.d/99-zzz-network-tuning.conf` 防重启覆盖**：
   - 利用 `systemd-sysctl` 字典序加载机制排在末尾兜底，彻底防止云镜像自带的 `99-cloudimg-*.conf` / `99-sysctl.conf` 重启后覆盖调优参数。
   - 使用官方 `-` 前缀兼容不同内核模块（`-net.mptcp.enabled = 0`、`-net.netfilter.nf_conntrack_max`）。
3. **`systemd-journald` 日志与内存映射收敛**：
   - 同时锁定 `SystemMaxUse=50M`、`SystemMaxFileSize=10M`、`RuntimeMaxUse=20M`，防止小硬盘被日志写满并压低常驻 RSS。
4. **Hyper-V `hv_balloon` 动态内存回收（Memory Ballooning）排查与防护**：
   - 自动检测 `hv_balloon` 模块；在用户二次确认后自动备份 `/etc/default/grub`、写入 `modprobe` + GRUB 黑名单，并在 `update-grub` 后强校验根分区 UUID（校验失败自动回滚）。
   - *注：部分超售 Hyper-V 商家 TOS 可能不允许禁用动态内存驱动，动手前请先确认商家条款。*
5. **Hyper-V 虚拟网卡 `GRO` 合包异常修复**：
   - 自动识别默认路由网卡名（兼容 `eth0` / `ens3` / `enp0s3` 等），通过 `ethtool -K <IFACE> gro off` 关闭并注册为 `nic-gro-off.service` 开机自启。

---

## 命令行直达模式

```bash
# 模式 1：一键全套底层调优
bash <(curl -fsSL https://raw.githubusercontent.com/CatEacc/vps-linux-tuning/main/tune.sh) 1

# 模式 2：Hyper-V 虚拟化专项排查与加固
bash <(curl -fsSL https://raw.githubusercontent.com/CatEacc/vps-linux-tuning/main/tune.sh) 2

# 模式 3：只读系统体检（零修改）
bash <(curl -fsSL https://raw.githubusercontent.com/CatEacc/vps-linux-tuning/main/tune.sh) 3

# 模式 4：一键回滚还原（恢复脚本修改前的原厂快照）
bash <(curl -fsSL https://raw.githubusercontent.com/CatEacc/vps-linux-tuning/main/tune.sh) 4
```

---

## 参数分档对照表

| 物理内存档位 | `rmem_max` / `wmem_max` | `tcp_rmem` / `tcp_wmem` 上限 | `rmem_default` / `wmem_default` | `nf_conntrack_max` |
| :--- | :---: | :---: | :---: | :---: |
| `<= 700 MB` (512M 小鸡) | 16 MB | 8 MB | 256 KB | 65,536 |
| `700 ~ 1500 MB` (1G 机器) | 32 MB | 16 MB | 512 KB | 65,536 |
| `>= 1500 MB` (2G+ 机器) | 64 MB | 32 MB | 1 MB | 131,072 |

---

## 开源协议

MIT License · 由 [猫e/acc (CatEacc)](https://github.com/CatEacc) 维护 · TG 频道：[https://t.me/CatCryptoMaster](https://t.me/CatCryptoMaster)
