#!/bin/bash
# ==============================================================================
# Linux VPS 底层内核与内存调优一键脚本 (CatEacc/vps-linux-tuning)
# 适用系统: Debian 11/12/13, Ubuntu 20.04/22.04/24.04 (AMD64 / ARM64)
# 功能菜单:
#   1) 一键全套底层调优 (改前自动存原厂快照 + 分档缓冲 + 99-zzz + BBR/FQ + 1G Swap + 默认封 TCP 25 + Journald 50M + Fail2ban)
#   2) Hyper-V 虚拟化专项排查与加固 (检测 hv_balloon 动态内存回收 / 持久化关闭网卡 GRO)
#   3) 只读系统体检 (查看当前内存、Swap、BBR、缓冲区档位、TCP 25 防护、Journald 与虚拟化状态)
#   4) 一键回滚还原 (恢复脚本修改前的原厂内核参数、日志、Swap 与虚拟化配置)
# ==============================================================================

set -euo pipefail

BACKUP_DIR="/var/backups/vps-linux-tuning"

if [ "$(id -u)" != "0" ]; then
    echo "[错误] 必须以 root 用户运行此脚本！请先执行 sudo -i"
    exit 1
fi

OS_INFO=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}" || uname -s)
KERNEL_INFO=$(uname -r | cut -d'-' -f1)
ARCH_INFO=$(uname -m)
MEM_SHOW=$(LC_ALL=C free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
MEM_SHOW="${MEM_SHOW:-0}"
SWAP_SHOW=$(LC_ALL=C free -m 2>/dev/null | awk '/^Swap:/ {print $2}')
SWAP_SHOW="${SWAP_SHOW:-0}"
BBR_STAT=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
VIRT_STAT=$(systemd-detect-virt 2>/dev/null || echo "unknown")
DEFAULT_IFACE=$( (ip -4 route show default 2>/dev/null; ip -6 route show default 2>/dev/null) | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true )
DEFAULT_IFACE="${DEFAULT_IFACE:-eth0}"

# 256 色丝滑渐变配色
ESC="$(printf '\033')"
R="${ESC}[0m"
B="${ESC}[1m"
SKY="${ESC}[38;5;39m"
CYAN="${ESC}[38;5;51m"
GREEN="${ESC}[38;5;46m"
YELLOW="${ESC}[38;5;220m"
ORANGE="${ESC}[38;5;208m"
PINK="${ESC}[38;5;205m"
WHITE="${ESC}[1;97m"
DIM="${ESC}[38;5;245m"

print_cateacc_logo() {
    G1="${ESC}[38;5;46m"
    G2="${ESC}[38;5;82m"
    G3="${ESC}[38;5;118m"
    G4="${ESC}[38;5;226m"
    G5="${ESC}[38;5;220m"
    G6="${ESC}[38;5;208m"
    G7="${ESC}[38;5;199m"
    awk -v c1="$G1" -v c2="$G2" -v c3="$G3" -v c4="$G4" -v c5="$G5" -v c6="$G6" -v c7="$G7" -v rs="$R" -v bd="$B" '
    {
        line = $0
        while (length(line) < 42) line = line " "
        printf "  %s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", \
            bd c1, substr(line, 1, 6), \
            c2, substr(line, 7, 6), \
            c3, substr(line, 13, 6), \
            c4, substr(line, 19, 6), \
            c5, substr(line, 25, 6), \
            c6, substr(line, 31, 6), \
            c7, substr(line, 37, 6), \
            rs
    }
    ' <<'BANNER'
   ______      __  ______               
  / ____/___ _/ /_/ ____/___ ___________
 / /   / __ `/ __/ __/ / __ `/ ___/ ___/
/ /___/ /_/ / /_/ /___/ /_/ / /__/ /__  
\____/\__,_/\__/_____/\__,_/\___/\___/  
BANNER
}

# ------------------------------------------------------------------------------
# 0. 交互菜单（也支持命令行传参: bash tune.sh [1|2|3|4]）
# ------------------------------------------------------------------------------
MODE="${1:-}"
if [ -z "$MODE" ]; then
    clear 2>/dev/null || true
    printf '\n'
    print_cateacc_logo
    printf '\n'
    printf "  ${CYAN}猫e/acc (CatEacc)${R} ${DIM}· Linux VPS 底层内核与内存调优脚本 ${YELLOW}v1.1.1${R}\n"
    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n"
    printf "  ${SKY}OS:${R}       ${GREEN}${OS_INFO} (${ARCH_INFO})${R}\n"
    printf "  ${SKY}Kernel:${R}   ${GREEN}${KERNEL_INFO}${R}  ${DIM}|${R}  ${SKY}Virt:${R} ${GREEN}${VIRT_STAT}${R}  ${DIM}|${R}  ${SKY}NIC:${R} ${CYAN}${DEFAULT_IFACE}${R}\n"
    printf "  ${SKY}Memory:${R}   ${GREEN}${MEM_SHOW} MB${R}  ${DIM}|${R}  ${SKY}Swap:${R} ${GREEN}${SWAP_SHOW} MB${R}  ${DIM}|${R}  ${SKY}BBR:${R} ${GREEN}${BBR_STAT}${R}\n"
    printf "  ${SKY}GitHub:${R}   ${CYAN}https://github.com/CatEacc/vps-linux-tuning${R}\n"
    printf "  ${SKY}Channel:${R}  ${CYAN}https://t.me/CatCryptoMaster${R}\n"
    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n\n"
    printf "  ${WHITE}请选择操作模式：${R}\n"
    printf "  ${GREEN}[1]${R} ${WHITE}一键全套底层调优${R} ${CYAN}★ 推荐 · 改前自动快照${R}\n"
    printf "      ${DIM}分档缓冲 + 99-zzz 防覆盖 + BBR/FQ + 1G Swap + 默认封 TCP 25 + Journald 50M + Fail2ban${R}\n"
    printf "  ${GREEN}[2]${R} ${WHITE}Hyper-V 虚拟化专项排查与加固${R} ${YELLOW}· hv_balloon / GRO${R}\n"
    printf "      ${DIM}检测动态内存回收（确认后写 GRUB 黑名单）+ 持久化关闭网卡 GRO 合包${R}\n"
    printf "  ${GREEN}[3]${R} ${WHITE}只读系统体检${R} ${PINK}· 零修改${R}\n"
    printf "      ${DIM}输出当前内存、Swap、BBR、缓冲区上限、TCP 25 防护、Journald 与 Hyper-V 状态${R}\n"
    printf "  ${GREEN}[4]${R} ${WHITE}一键回滚还原${R} ${ORANGE}· 恢复原厂快照${R}\n"
    printf "      ${DIM}撤销本脚本写入的 sysctl / Journald / Fail2ban / Swap / GRO 与 GRUB 修改${R}\n\n"
    read -rp "$(printf "${YELLOW}  请输入模式编号 [1-4] (回车默认 1): ${R}")" MODE
    MODE="${MODE:-1}"
fi

# ------------------------------------------------------------------------------
# 模式 3：只读系统体检
# ------------------------------------------------------------------------------
run_audit() {
    echo ""
    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n"
    printf "  ${WHITE}Linux 系统底层体检报告${R}\n"
    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n"
    echo "  物理内存 / Swap     : ${MEM_SHOW} MB / ${SWAP_SHOW} MB (swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo N/A))"
    echo "  虚拟化 / 默认网卡   : ${VIRT_STAT} / ${DEFAULT_IFACE}"
    echo "  拥塞控制 / 队列算法 : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A) / $(sysctl -n net.core.default_qdisc 2>/dev/null || echo N/A)"
    echo "  MPTCP 状态          : $(sysctl -n net.mptcp.enabled 2>/dev/null || echo 未启用或不支持)"
    echo "  rmem_max / default  : $(sysctl -n net.core.rmem_max 2>/dev/null || echo N/A) / $(sysctl -n net.core.rmem_default 2>/dev/null || echo N/A)"
    echo "  tcp_rmem            : $(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo N/A)"
    echo "  Journald 磁盘占用   : $(journalctl --disk-usage 2>/dev/null | sed 's/Archived and active journals take up //; s/ in the file system\.//' || echo N/A)"
    if command -v nft >/dev/null 2>&1 && (
        nft list table inet smtp_guard 2>/dev/null | grep -Eq 'dport 25[[:space:]].*(reject|drop)' ||
        nft list ruleset 2>/dev/null | awk '/hook output/{f=1} /^\t\}/{f=0} f && /dport 25.*(reject|drop)/{ok=1} END{exit !ok}'
    ); then
        echo "  出站 TCP 25 防护    : 已封禁 (nftables output)"
    else
        echo "  出站 TCP 25 防护    : 未检测到出站封禁规则（可运行模式 1 自动加固）"
    fi
    if lsmod 2>/dev/null | grep -q "^hv_balloon"; then
        echo "  Hyper-V hv_balloon  : [已加载] 宿主机可动态回收空闲内存"
    else
        echo "  Hyper-V hv_balloon  : 未加载"
    fi
    if command -v ethtool >/dev/null 2>&1 && [ -n "$DEFAULT_IFACE" ]; then
        GRO_STAT=$(ethtool -k "$DEFAULT_IFACE" 2>/dev/null | awk '/generic-receive-offload:/ {print $2}' || echo "N/A")
        echo "  网卡 GRO 状态       : ${DEFAULT_IFACE} -> ${GRO_STAT}"
    fi
    if [ -f /etc/sysctl.d/99-zzz-network-tuning.conf ]; then
        echo "  99-zzz 持久化配置   : 已部署 (/etc/sysctl.d/99-zzz-network-tuning.conf)"
    else
        echo "  99-zzz 持久化配置   : 未部署"
    fi
    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n"
}

# ------------------------------------------------------------------------------
# 修改前自动存原厂快照（仅首次存档，重复运行不覆盖原厂值）
# ------------------------------------------------------------------------------
save_snapshot() {
    if [ -f "${BACKUP_DIR}/snapshot.done" ]; then
        return 0
    fi
    (
        umask 077
        mkdir -p "$BACKUP_DIR"
        [ -f /etc/systemd/journald.conf ] && cp -a /etc/systemd/journald.conf "${BACKUP_DIR}/journald.conf.bak"
        [ -f /etc/fail2ban/jail.local ] && cp -a /etc/fail2ban/jail.local "${BACKUP_DIR}/jail.local.bak"
        [ -f /etc/security/limits.d/99-nofile.conf ] && cp -a /etc/security/limits.d/99-nofile.conf "${BACKUP_DIR}/99-nofile.conf.bak"
        : > "${BACKUP_DIR}/sysctl_orig.conf"
        for key in \
            net.core.default_qdisc net.ipv4.tcp_congestion_control net.mptcp.enabled \
            net.core.somaxconn net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog \
            net.ipv4.ip_local_port_range net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout \
            net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes \
            net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing \
            net.ipv4.tcp_no_metrics_save net.ipv4.tcp_ecn net.core.rmem_max net.core.wmem_max \
            net.core.rmem_default net.core.wmem_default net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min \
            net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_fastopen net.ipv4.tcp_notsent_lowat \
            net.ipv4.tcp_adv_win_scale net.netfilter.nf_conntrack_max \
            net.netfilter.nf_conntrack_udp_timeout net.netfilter.nf_conntrack_udp_timeout_stream \
            fs.file-max vm.swappiness; do
            val=$(sysctl -n "$key" 2>/dev/null || true)
            if [ -n "$val" ]; then
                printf "%s = %s\n" "$key" "$(echo "$val" | tr '\t' ' ' | tr -s ' ')" >> "${BACKUP_DIR}/sysctl_orig.conf"
            fi
        done
        date -u +"%Y-%m-%dT%H:%M:%SZ" > "${BACKUP_DIR}/snapshot.done"
    )
    echo "[快照] 已自动保存原厂内核与配置快照至 ${BACKUP_DIR}（随时可用模式 4 一键回滚）"
}

# ------------------------------------------------------------------------------
# 模式 1：一键全套底层调优
# ------------------------------------------------------------------------------
run_full_tune() {
    echo ""
    save_snapshot
    echo "[1/4] 安装基础运维组件 (chrony / nftables / fail2ban / ethtool)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl chrony nftables fail2ban python3-systemd ethtool >/dev/null 2>&1 || \
      apt-get install -y curl chrony nftables fail2ban ethtool

    echo "[2/4] 配置 NTP 对时、1GB Swap 兜底、默认封禁出站 TCP 25 与 Journald 50M 限额..."
    systemctl enable --now chrony 2>/dev/null || true
    chronyc makestep >/dev/null 2>&1 || true

    if [ ! -f /swapfile ]; then
        if fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; then
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1 || true
            if swapon /swapfile 2>/dev/null; then
                touch "${BACKUP_DIR}/swap_created_by_script"
            else
                rm -f /swapfile
                dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null || true
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null 2>&1 || true
                if swapon /swapfile 2>/dev/null; then
                    touch "${BACKUP_DIR}/swap_created_by_script"
                else
                    rm -f /swapfile
                    echo "  [提示] 当前容器/文件系统不支持挂载 Swap，已自动跳过。"
                fi
            fi
        fi
    fi
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "/swapfile"; then
        grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw,nofail 0 0" >> /etc/fstab
        if [ -f /swap.img ] && [ "$(stat -c%s /swap.img 2>/dev/null || echo 1073741824)" -lt 943718400 ]; then
            swapoff /swap.img 2>/dev/null || true
            sed -i '\|/swap\.img|d' /etc/fstab
            rm -f /swap.img
        fi
    fi

    if command -v nft >/dev/null 2>&1; then
        mkdir -p /etc/nftables.d
        [ ! -f /etc/nftables.d/smtp-guard.nft ] && touch "${BACKUP_DIR}/smtp_guard_created_by_script"
        cat << 'EOF' > /etc/nftables.d/smtp-guard.nft
table inet smtp_guard
delete table inet smtp_guard
table inet smtp_guard {
    chain output {
        type filter hook output priority filter; policy accept;
        tcp dport 25 reject with tcp reset
    }
}
EOF
        nft -f /etc/nftables.d/smtp-guard.nft 2>/dev/null || true
        cat << 'EOF' > /etc/systemd/system/smtp-guard.service
[Unit]
Description=Block Outbound TCP 25 (SMTP Anti-Spam)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables.d/smtp-guard.nft
ExecStop=/usr/sbin/nft delete table inet smtp_guard

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable --now smtp-guard.service >/dev/null 2>&1 || true
    fi

    cat << 'EOF' > /etc/systemd/journald.conf
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
RuntimeMaxUse=20M
MaxRetentionSec=7day
ForwardToSyslog=no
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    journalctl --rotate 2>/dev/null || true
    journalctl --vacuum-size=40M >/dev/null 2>&1 || true

    echo "[3/4] 写入按物理内存分档的 /etc/sysctl.d/99-zzz-network-tuning.conf..."
    mkdir -p /etc/modules-load.d
    printf "tcp_bbr\nnf_conntrack\n" > /etc/modules-load.d/99-network-tuning.conf
    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true

    MEM_MB=$(LC_ALL=C free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
    if [ "${MEM_MB:-1000}" -le 700 ]; then
        TIER="512M 档 (防 OOM 紧凑缓冲)"
        RMEM_MAX=16777216; TCP_MAX=8388608; DEF_BUF=262144; CONN_MAX=65536
    elif [ "${MEM_MB:-1000}" -lt 1500 ]; then
        TIER="1G 档 (均衡缓冲)"
        RMEM_MAX=33554432; TCP_MAX=16777216; DEF_BUF=524288; CONN_MAX=65536
    else
        TIER="2G+ 档 (满血高吞吐缓冲)"
        RMEM_MAX=67108864; TCP_MAX=33554432; DEF_BUF=1048576; CONN_MAX=131072
    fi

    cat << EOF > /etc/sysctl.d/99-zzz-network-tuning.conf
# CatEacc/vps-linux-tuning (${TIER})
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
-net.mptcp.enabled = 0
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $RMEM_MAX
net.core.rmem_default = $DEF_BUF
net.core.wmem_default = $DEF_BUF
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_rmem = 4096 87380 $TCP_MAX
net.ipv4.tcp_wmem = 4096 65536 $TCP_MAX
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_adv_win_scale = 1
-net.netfilter.nf_conntrack_max = $CONN_MAX
-net.netfilter.nf_conntrack_udp_timeout = 30
-net.netfilter.nf_conntrack_udp_timeout_stream = 60
fs.file-max = 2097152
vm.swappiness = 10
EOF

    grep -vE '^\s*#|^\s*$' /etc/sysctl.d/99-zzz-network-tuning.conf | sed 's/^-//' | while IFS='=' read -r k v; do
        sysctl -w "$(echo "$k" | xargs)=$(echo "$v" | xargs)" >/dev/null 2>&1 || true
    done

    cat << 'EOF' > /etc/security/limits.d/99-nofile.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    echo "[4/4] 配置 Fail2ban SSH 防爆破加固..."
    mkdir -p /run/sshd
    SSH_PORTS=$( (sshd -T 2>/dev/null || true) | awk '$1=="port"{print $2}' | paste -sd, - )
    SSH_PORTS="${SSH_PORTS:-22}"
    BAN_ACTION_LINE=""
    if command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
        BAN_ACTION_LINE="banaction = nftables-multiport"
    fi
    cat << EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 86400
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 2592000
findtime = 600
maxretry = 3
backend = systemd
${BAN_ACTION_LINE}

[sshd]
enabled = true
port = $SSH_PORTS
mode = aggressive
EOF
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

    echo ""
    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n"
    printf "  ${WHITE}底层调优全部完成！${R}\n"
    echo "  已套用档位 : ${TIER}"
    echo "  拥塞控制   : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A) + $(sysctl -n net.core.default_qdisc 2>/dev/null || echo N/A)"
    echo "  Swap 总量  : $(LC_ALL=C free -m | awk '/^Swap:/ {print $2}') MB (swappiness=10)"
    if command -v nft >/dev/null 2>&1 && nft list table inet smtp_guard 2>/dev/null | grep -Eq 'dport 25[[:space:]].*(reject|drop)'; then
        echo "  出站 TCP 25: 已封禁 (smtp-guard.service)"
    else
        echo "  出站 TCP 25: 未生效（当前环境可能不支持 nftables）"
    fi
    echo "  持久化文件 : /etc/sysctl.d/99-zzz-network-tuning.conf"
    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n"
}

# ------------------------------------------------------------------------------
# 模式 2：Hyper-V 虚拟化专项排查与加固
# ------------------------------------------------------------------------------
run_hyperv_fix() {
    echo ""
    echo "[Hyper-V 专项] 正在检测虚拟化驱动与网卡状态..."
    echo "  当前虚拟化类型 : ${VIRT_STAT}"
    echo "  默认路由网卡   : ${DEFAULT_IFACE}"

    if dmesg 2>/dev/null | grep -qi "suspect GRO implementation"; then
        echo "  [发现] dmesg 中检测到 GRO 合包异常告警 (suspect GRO implementation)"
    fi

    read -rp "是否关闭默认网卡 (${DEFAULT_IFACE}) 的 GRO 并注册开机自启服务？[y/N]: " DO_GRO
    if [[ "${DO_GRO:-n}" =~ ^[Yy]$ ]]; then
        export DEBIAN_FRONTEND=noninteractive
        command -v ethtool >/dev/null 2>&1 || (apt-get update -y >/dev/null && apt-get install -y ethtool >/dev/null)
        ETHTOOL_BIN=$(command -v ethtool)
        "$ETHTOOL_BIN" -K "$DEFAULT_IFACE" gro off || true
        cat << EOF > /etc/systemd/system/nic-gro-off.service
[Unit]
Description=Disable GRO on ${DEFAULT_IFACE}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-${ETHTOOL_BIN} -K ${DEFAULT_IFACE} gro off

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now nic-gro-off.service >/dev/null 2>&1 || true
        echo "  [完成] 已关闭 ${DEFAULT_IFACE} GRO 并持久化为 nic-gro-off.service"
    fi

    if lsmod 2>/dev/null | grep -q "^hv_balloon"; then
        echo ""
        echo "  [发现] 当前系统已加载 hv_balloon 动态内存气球驱动！"
        echo "  [提醒] 部分超售 Hyper-V 商家 TOS 可能不允许禁用气球驱动，操作前请先确认商家条款。"
        read -rp "是否写入 modprobe + GRUB 黑名单以屏蔽 hv_balloon？[y/N]: " DO_BALLOON
        if [[ "${DO_BALLOON:-n}" =~ ^[Yy]$ ]]; then
            if ! command -v update-grub >/dev/null 2>&1 || [ ! -f /etc/default/grub ]; then
                echo "  [提示] 当前系统未使用标准 GRUB（缺少 update-grub 或 /etc/default/grub），已跳过 GRUB 修改。"
            else
                mkdir -p "$BACKUP_DIR" /etc/default/grub.d
                [ -f "${BACKUP_DIR}/grub.default.bak" ] || cp -a /etc/default/grub "${BACKUP_DIR}/grub.default.bak"
                printf "blacklist hv_balloon\n" > /etc/modprobe.d/blacklist-hv_balloon.conf
                cat << 'EOF' > /etc/default/grub.d/99-zz-hv-balloon.cfg
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+$GRUB_CMDLINE_LINUX }modprobe.blacklist=hv_balloon"
EOF
                GRUB_OK="0"
                GRUB_CFG="/boot/grub/grub.cfg"
                [ ! -f "$GRUB_CFG" ] && [ -f /boot/grub2/grub.cfg ] && GRUB_CFG="/boot/grub2/grub.cfg"
                if update-initramfs -u && update-grub; then
                    ROOT_UUID=$(findmnt -no UUID / || true)
                    ROOT_SRC=$(findmnt -no SOURCE / || true)
                    if [ -f "$GRUB_CFG" ] && grep -q "modprobe.blacklist=hv_balloon" "$GRUB_CFG" 2>/dev/null && (
                        { [ -n "$ROOT_UUID" ] && grep -q "$ROOT_UUID" "$GRUB_CFG" 2>/dev/null; } ||
                        { [ -n "$ROOT_SRC" ] && grep -Fq "root=$ROOT_SRC" "$GRUB_CFG" 2>/dev/null; } ||
                        grep -Eq '^[[:space:]]*linux(efi)?[[:space:]]+/' "$GRUB_CFG" 2>/dev/null
                    ); then
                        GRUB_OK="1"
                    fi
                fi
                if [ "$GRUB_OK" = "1" ]; then
                    echo "  [校验通过] GRUB 引导项与黑名单参数完整，已备份原配置至 ${BACKUP_DIR}/grub.default.bak。"
                    echo "  闲时执行 systemctl reboot 即可生效并恢复完整初始内存。"
                else
                    echo "  [警告] GRUB 校验未通过！已自动完整回滚 modprobe 与 GRUB 配置，请勿强行重启。"
                    rm -f /etc/modprobe.d/blacklist-hv_balloon.conf /etc/default/grub.d/99-zz-hv-balloon.cfg
                    [ -f "${BACKUP_DIR}/grub.default.bak" ] && cp -a "${BACKUP_DIR}/grub.default.bak" /etc/default/grub
                    update-initramfs -u >/dev/null 2>&1 || true
                    update-grub >/dev/null 2>&1 || true
                fi
            fi
        fi
    else
        echo "  [正常] 未检测到 hv_balloon 模块。"
    fi
}

# ------------------------------------------------------------------------------
# 模式 4：一键回滚还原（恢复原厂快照）
# ------------------------------------------------------------------------------
run_rollback() {
    echo ""
    printf "  ${YELLOW}即将撤销 vps-linux-tuning 写入的系统调优并恢复原厂快照。${R}\n"
    read -rp "确认执行一键回滚还原？[y/N]: " DO_RB
    if [[ ! "${DO_RB:-n}" =~ ^[Yy]$ ]]; then
        echo "  已取消回滚。"
        return 0
    fi

    echo "[1/4] 移除 99-zzz 内核配置文件并恢复原厂 sysctl 运行态参数..."
    rm -f /etc/sysctl.d/99-zzz-network-tuning.conf /etc/modules-load.d/99-network-tuning.conf
    if [ -f "${BACKUP_DIR}/sysctl_orig.conf" ]; then
        while IFS='=' read -r k v; do
            [ -n "${k:-}" ] && sysctl -w "$(echo "$k" | xargs)=$(echo "$v" | xargs)" >/dev/null 2>&1 || true
        done < "${BACKUP_DIR}/sysctl_orig.conf"
    fi
    sysctl --system >/dev/null 2>&1 || true

    echo "[2/4] 恢复 Journald、nofile、Fail2ban 与本脚本创建的防火墙规则..."
    if [ -f "${BACKUP_DIR}/journald.conf.bak" ]; then
        cp -a "${BACKUP_DIR}/journald.conf.bak" /etc/systemd/journald.conf
        systemctl restart systemd-journald 2>/dev/null || true
    elif [ -f /etc/systemd/journald.conf ] && [ -f "${BACKUP_DIR}/snapshot.done" ]; then
        rm -f /etc/systemd/journald.conf
        systemctl restart systemd-journald 2>/dev/null || true
    fi
    if [ -f "${BACKUP_DIR}/99-nofile.conf.bak" ]; then
        cp -a "${BACKUP_DIR}/99-nofile.conf.bak" /etc/security/limits.d/99-nofile.conf
    elif [ -f "${BACKUP_DIR}/snapshot.done" ]; then
        rm -f /etc/security/limits.d/99-nofile.conf
    fi
    if [ -f "${BACKUP_DIR}/jail.local.bak" ]; then
        cp -a "${BACKUP_DIR}/jail.local.bak" /etc/fail2ban/jail.local
        systemctl restart fail2ban 2>/dev/null || true
    elif [ -f /etc/fail2ban/jail.local ] && [ -f "${BACKUP_DIR}/snapshot.done" ]; then
        rm -f /etc/fail2ban/jail.local
        systemctl restart fail2ban 2>/dev/null || true
    fi
    if [ -f "${BACKUP_DIR}/smtp_guard_created_by_script" ]; then
        systemctl disable --now smtp-guard.service >/dev/null 2>&1 || true
        nft delete table inet smtp_guard >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/smtp-guard.service /etc/nftables.d/smtp-guard.nft "${BACKUP_DIR}/smtp_guard_created_by_script"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    echo "[3/4] 检查并清理本脚本新建的 Swap..."
    if [ -f "${BACKUP_DIR}/swap_created_by_script" ] && [ -f /swapfile ]; then
        swapoff /swapfile 2>/dev/null || true
        sed -i '\|/swapfile|d' /etc/fstab
        rm -f /swapfile "${BACKUP_DIR}/swap_created_by_script"
    fi

    echo "[4/4] 检查并还原网卡 GRO 与 Hyper-V GRUB 配置..."
    if [ -f /etc/systemd/system/nic-gro-off.service ]; then
        systemctl disable --now nic-gro-off.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/nic-gro-off.service
        systemctl daemon-reload
        command -v ethtool >/dev/null 2>&1 && ethtool -K "$DEFAULT_IFACE" gro on >/dev/null 2>&1 || true
    fi
    if [ -f /etc/modprobe.d/blacklist-hv_balloon.conf ] || [ -f /etc/default/grub.d/99-zz-hv-balloon.cfg ]; then
        rm -f /etc/modprobe.d/blacklist-hv_balloon.conf /etc/default/grub.d/99-zz-hv-balloon.cfg
        if [ -f "${BACKUP_DIR}/grub.default.bak" ]; then
            cp -a "${BACKUP_DIR}/grub.default.bak" /etc/default/grub
        elif [ -f /root/grub.default.bak ]; then
            cp -a /root/grub.default.bak /etc/default/grub
        fi
        update-initramfs -u >/dev/null 2>&1 || true
        update-grub >/dev/null 2>&1 || true
        echo "  [提示] 已还原 Hyper-V GRUB 配置，重启后恢复原厂 hv_balloon 状态。"
    fi

    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n"
    printf "  ${WHITE}一键回滚还原完成！${R}\n"
    echo "  当前拥塞控制 : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A) + $(sysctl -n net.core.default_qdisc 2>/dev/null || echo N/A)"
    echo "  快照备份目录 : ${BACKUP_DIR}（已保留以备查验）"
    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n"
}

case "$MODE" in
    1) run_full_tune ;;
    2) run_hyperv_fix ;;
    3) run_audit ;;
    4) run_rollback ;;
    *)
        echo "[错误] 无效的模式编号: ${MODE}，仅支持 1 / 2 / 3 / 4"
        exit 1
        ;;
esac

printf "  ${CYAN}本脚本由 猫e/acc (CatEacc) 维护提供${R}\n"
printf "  ${SKY}GitHub:${R}  ${CYAN}https://github.com/CatEacc/vps-linux-tuning${R}\n"
printf "  ${SKY}Channel:${R} ${CYAN}https://t.me/CatCryptoMaster${R}\n"
