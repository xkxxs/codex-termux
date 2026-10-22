#!/data/data/com.termux/files/usr/bin/bash
# dns53 root 执行后端 — 被 install.sh / check_dns.sh / dns53-aaaa source
#
# Android 上有 root 不等于装了 Termux 的 sudo 包: Magisk/KernelSU 只提供 su。
# 只判断 `sudo -n` 会把「有 su、没 sudo」的设备误判成无 root。
# 探测顺序: direct (本身已是 root) → sudo -n → su -c, 结果缓存到
# $DNS_DIR/.root_mode (direct|sudo|su|none), 避免每次都探测 su 触发授权弹窗。
#
# 依赖变量: DNS_DIR (未设置时取默认值)

: "${DNS_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/dns53}"
ROOT_MODE="${DNS53_ROOT_MODE:-}"

dns53_detect_root_mode() {
    if [ "$(id -u 2>/dev/null)" = 0 ]; then echo direct; return 0; fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then echo sudo; return 0; fi
    if command -v su >/dev/null 2>&1; then
        local u
        u="$(timeout 5 su -c 'id -u' 2>/dev/null | tr -d '\r' | head -n 1)"
        if [ "$u" = 0 ]; then echo su; return 0; fi
    fi
    echo none
}

# $1=1 强制重新探测 (安装/--status 时用); 默认优先读缓存
dns53_load_root_mode() {
    local detect="${1:-0}"
    if [ "$detect" != 1 ] && [ -z "$ROOT_MODE" ] && [ -f "$DNS_DIR/.root_mode" ]; then
        ROOT_MODE="$(cat "$DNS_DIR/.root_mode" 2>/dev/null || true)"
    fi
    if [ "$detect" = 1 ] || [ -z "$ROOT_MODE" ]; then
        ROOT_MODE="$(dns53_detect_root_mode)"
        mkdir -p "$DNS_DIR" 2>/dev/null || true
        printf '%s\n' "$ROOT_MODE" > "$DNS_DIR/.root_mode" 2>/dev/null || true
    fi
}

dns53_have_root() { [ "${ROOT_MODE:-none}" != none ]; }

# dns53 是否活着: 心跳文件 90s 内更新过 (普通用户即可判断, 不需要 su)
dns53_alive() {
    local f="${DNS_DIR}/.alive" now mt
    [ -f "$f" ] || return 1
    now=$(date +%s)
    mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    [ $((now - mt)) -lt 90 ]
}

# 按后端执行: direct 直接跑, sudo 用 -n (不弹窗), su 用 -c (带正确转义)
dns53_root_exec() {
    case "${ROOT_MODE:-none}" in
        direct) "$@" ;;
        sudo)   sudo -n "$@" ;;
        su)
            # Magisk/KernelSU 的 root shell PATH 可能不含 Termux 的 bin
            # (node/nohup 会找不到), 这里显式补上。
            local p="${PREFIX:-/data/data/com.termux/files/usr}/bin"
            su -c "PATH=$p:/system/bin:/system/xbin:\$PATH $(printf '%q ' "$@")"
            ;;
        *)      return 1 ;;
    esac
}
