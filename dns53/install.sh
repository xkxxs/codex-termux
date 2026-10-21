#!/data/data/com.termux/files/usr/bin/bash
# dns53 独立组件安装器
#
# 安装目录: ${XDG_DATA_HOME:-$HOME/.local/share}/dns53
# 该目录不属于任何 agent, 删除/重装 ~/.codex、~/.config/opencode 等不会影响它。
#
# 用法:
#   bash install.sh              安装/升级并启动
#   bash install.sh --force      强制覆盖已安装文件 (默认拒绝降级)
#   bash install.sh --status     查看状态
#   bash install.sh --uninstall  仅卸载本组件 (不动 agent 目录)
set -euo pipefail

DNS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dns53"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$DNS_DIR/logs"
SRC_VER="$(cat "$SELF_DIR/VERSION" 2>/dev/null || echo 0)"
FILES=(install.sh VERSION dns53.js dns-bootstrap.js dnsq.js check_dns.sh dns53-aaaa)

info() { printf '\033[36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }

have_root() { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }

is_running() {
    have_root && sudo -n pgrep -f '^node .*dns5[3]\.js' >/dev/null 2>&1
}

# $1 是否比 $2 新 (按版本号排序)
ver_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# 删除旧版 .bashrc 钩子 (旧的无标记块 + 新的 marker 块), 其余内容原样保留
strip_bashrc() {
    local rc="$HOME/.bashrc"
    [ -f "$rc" ] || return 0
    awk '
        /^# >>> dns53 >>>$/ {skip=1; next}
        /^# <<< dns53 <<<$/ {skip=0; next}
        /^# ===== DNS 转发器常驻 \(dns53\) =====$/ {legacy=1; next}
        legacy && /^fi$/ {legacy=0; next}
        !skip && !legacy {print}
    ' "$rc" > "$rc.dns53.$$"
    mv "$rc.dns53.$$" "$rc"
}

write_bashrc() {
    strip_bashrc
    cat >> "$HOME/.bashrc" << 'BASHRC_EOF'

# >>> dns53 >>>
# 独立组件 (~/.local/share/dns53), 与任何 agent 目录无关; 删 agent 不会影响它
DNS53_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dns53"
if [ -f "$DNS53_DIR/dns53.js" ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    if ! sudo -n pgrep -f '^node .*dns5[3]\.js' >/dev/null 2>&1; then
        mkdir -p "$DNS53_DIR/logs"
        sudo -n nohup node "$DNS53_DIR/dns53.js" >> "$DNS53_DIR/logs/dns53.log" 2>&1 &
        sleep 1
    fi
fi
# <<< dns53 <<<
BASHRC_EOF
}

# 清理旧安装位置 (旧版把 dns53 放在 ~/.local/bin 和 ~/.codex)
migrate_legacy() {
    rm -f "$HOME/.local/bin/dns53.js" "$HOME/.local/bin/dns-bootstrap.js" \
          "$HOME/.local/bin/dnsq.js" "$HOME/.local/bin/dns53-aaaa" \
          "$HOME/.check_dns.sh"
    rm -f "$HOME/.codex/dns53.log" "$HOME/.codex/dns-bootstrap.log"
}

install_files() {
    local force="${1:-0}" installed_ver="" f
    mkdir -p "$DNS_DIR" "$LOG_DIR"
    installed_ver="$(cat "$DNS_DIR/VERSION" 2>/dev/null || echo "")"

    if [ "$SELF_DIR" = "$DNS_DIR" ]; then
        : # 已在目标目录, 只补权限
    elif [ "$force" != "1" ] && [ -n "$installed_ver" ] && ver_gt "$installed_ver" "$SRC_VER"; then
        warn "已安装 $installed_ver 高于当前载荷 $SRC_VER, 保留现有文件 (--force 可强制覆盖)"
        SRC_VER="$installed_ver"
        return 0
    else
        for f in "${FILES[@]}"; do
            [ -f "$SELF_DIR/$f" ] || fail "组件载荷不完整: 缺少 $f"
            cp -f "$SELF_DIR/$f" "$DNS_DIR/$f"
        done
    fi

    chmod 700 "$DNS_DIR"/*.js "$DNS_DIR/install.sh" "$DNS_DIR/dns53-aaaa" "$DNS_DIR/check_dns.sh"
    printf '%s\n' "$SRC_VER" > "$DNS_DIR/VERSION"
}

start_dns53() {
    if is_running; then
        ok "dns53 已在运行 (127.0.0.1:53)"
        return 0
    fi
    mkdir -p "$LOG_DIR"
    sudo -n nohup node "$DNS_DIR/dns53.js" >> "$LOG_DIR/dns53.log" 2>&1 &
    sleep 1
    if is_running; then
        ok "dns53 已启动 (127.0.0.1:53)"
    else
        warn "dns53 启动失败, 日志: $LOG_DIR/dns53.log"
    fi
}

show_status() {
    echo "目录: $DNS_DIR"
    echo "版本: $(cat "$DNS_DIR/VERSION" 2>/dev/null || echo 未安装)"
    if have_root; then
        echo "root: 可用 (dns53 常驻方案)"
        if is_running; then
            echo "dns53: 运行中 (PID $(sudo -n pgrep -f '^node .*dns5[3]\.js' | head -1))"
        else
            echo "dns53: ★ 未运行 (bash $DNS_DIR/install.sh 可拉起)"
        fi
    else
        echo "root: 不可用 (dns-bootstrap + proot 方案)"
        awk '/^nameserver/{print "nameserver: "$2}' \
            "${PREFIX:-/data/data/com.termux/files/usr}/etc/resolv.conf" 2>/dev/null | head -4 || true
    fi
    echo "日志: $LOG_DIR"
}

uninstall() {
    have_root && sudo -n pkill -f '^node .*dns5[3]\.js' 2>/dev/null || true
    strip_bashrc
    migrate_legacy
    rm -rf "$DNS_DIR"
    ok "已卸载 dns53 (agent 目录未改动)"
}

activate() {
    migrate_legacy
    if have_root; then
        write_bashrc
        # 旧安装的 dns53 可能仍从 ~/.local/bin 运行: 重启到新目录
        local cur
        cur="$(sudo -n pgrep -af '^node .*dns5[3]\.js' 2>/dev/null || true)"
        if [ -n "$cur" ] && ! printf '%s\n' "$cur" | grep -qF "$DNS_DIR/dns53.js"; then
            info "检测到旧路径的 dns53, 重启以切换到独立目录"
            sudo -n pkill -f '^node .*dns5[3]\.js' 2>/dev/null || true
            sleep 1
        fi
        start_dns53
    else
        strip_bashrc
        info "无 root: 使用 dns-bootstrap 写 resolv.conf"
        node "$DNS_DIR/dns-bootstrap.js" || warn "dns-bootstrap 失败 (可稍后重试)"
    fi
    ok "dns53 组件已就绪: $DNS_DIR (版本 $(cat "$DNS_DIR/VERSION" 2>/dev/null || echo '?'))"
}

main() {
    case "${1:-install}" in
        --status)    show_status ;;
        --uninstall) uninstall ;;
        --force)     install_files 1; activate ;;
        install|--install) install_files 0; activate ;;
        *) fail "用法: bash install.sh [--force|--status|--uninstall]" ;;
    esac
}

main "${1:-install}"
