#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# codex-termux — 在 Termux (Android aarch64) 上一键安装官方 Codex CLI
# 前置要求: 有 root → dns53 原生方案; 无 root → proot 兜底 (无需 root, 自动检测)
#
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/codex-termux/main/install.sh)
#   bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/codex-termux/main/install.sh) --update
#   bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/codex-termux/main/install.sh) --uninstall
#
# 原理:
#   官方 @openai/codex 的 linux-arm64 平台包是 musl 静态链接,
#   可直接运行在 Android Bionic 上。但 npm 的 os 字段只声明 linux,
#   在 android 上会被拒绝安装, 因此手动下载 tarball 解压到 vendor。
#
# 配置模型 (DeepSeek 等) 请参考官方文档, 本脚本只负责安装:
#   https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/codex
# ============================================================
set -euo pipefail

# ---------- 常量 ----------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
CODEX_PKG_DIR="$PREFIX/lib/node_modules/@openai/codex"
VENDOR_BIN="$CODEX_PKG_DIR/vendor/aarch64-unknown-linux-musl/bin/codex"
WRAPPER_PATH="$HOME_DIR/.local/bin/codex"
# 本脚本所在目录: 有本地仓库时优先使用仓库里的 dns53/ 组件
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
CERT_FILE="$PREFIX/etc/tls/cert.pem"
UPSTREAM_DOCS_URL="https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/codex"

# ---------- 颜色 ----------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[1;36m'; NC='\033[0m'
ok()   { echo -e "${GRN}✓${NC} $*"; }
info() { echo -e "${BLU}▸${NC} $*"; }
warn() { echo -e "${YEL}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# ---------- 进度显示 ----------
# 背景: npm install / npm pack 全程无输出, 大包下载会让人以为卡死。
# ① npm install -g 这类无输出的长步骤 → 转圈 + 已耗时 (输出存 $SPIN_LOG, 失败才打印)
# ② 平台包下载 → 先用 npm view 拿真实 URL (跟随 registry 配置, 如 npmmirror),
#    再用 curl --progress-bar 下载 (有进度条/速度/剩余时间); 失败换镜像, 再回退 npm pack。
SPIN_CHARS='|/-\'
SPIN_LOG=""

run_with_spinner() {
    local msg="$1"; shift
    SPIN_LOG="${TMPDIR:-$PREFIX/tmp}/spin.$$.log"
    "$@" >"$SPIN_LOG" 2>&1 &
    local pid=$! i=0 t0=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r\033[K%s %s (%ds)' "$msg" "${SPIN_CHARS:$((i++ % 4)):1}" "$((SECONDS - t0))"
        sleep 0.5
    done
    wait "$pid"; local rc=$?
    printf '\r\033[K'
    if [ "$rc" -ne 0 ]; then
        warn "$msg 失败, 输出如下:"
        cat "$SPIN_LOG" >&2
    else
        echo -e "${msg} ${GRN}完成${NC} (${SECONDS}秒)"
    fi
    return $rc
}

npm_tarball_url() { npm view "$1" dist.tarball 2>/dev/null | tail -1; }

download_npm_tarball() {
    local spec="$1" out="$2" url="" alt=""
    url="$(npm_tarball_url "$spec")"
    if [ -n "$url" ]; then
        curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$url" -o "$out" && return 0
        case "$url" in
            *registry.npmjs.org*)     alt="${url/registry.npmjs.org/registry.npmmirror.com}" ;;
            *registry.npmmirror.com*) alt="${url/registry.npmmirror.com/registry.npmjs.org}" ;;
        esac
        if [ -n "$alt" ] && [ "$alt" != "$url" ]; then
            warn "直连失败, 换镜像重试…"
            curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$alt" -o "$out" && return 0
        fi
    fi
    info "直连失败, 回退 npm pack (此方式无进度显示)…"
    (cd "$(dirname "$out")" && npm pack "$spec" --silent >/dev/null 2>&1) || return 1
    local packed
    packed="$(ls "$(dirname "$out")"/*.tgz 2>/dev/null | head -1)"
    [ -n "$packed" ] || return 1
    [ "$packed" = "$out" ] || mv -f "$packed" "$out"
    return 0
}

# ---------- 环境检查 ----------
check_environment() {
    if [ "$(uname -o 2>/dev/null || true)" != "Android" ] && [ ! -x "$PREFIX/bin/pkg" ]; then
        fail "此脚本仅支持 Termux (Android)。普通 Linux 请直接: npm install -g @openai/codex"
    fi
    [ "$(uname -m)" = "aarch64" ] || fail "仅支持 aarch64 (ARM64) 架构, 当前: $(uname -m)"
    command -v curl >/dev/null || { info "安装 curl…"; pkg install -y curl; }
    info "环境检查通过 (Termux aarch64)"
}

# ---------- 依赖 ----------
install_dependencies() {
    local need=()
    # root 判定统一走 dns53 的 root.sh (direct/sudo/su); 安装时强制重新探测,
    # 避免沿用上次遗留的 .root_mode (例如上次无 root、这次已是 root)
    load_root_backend 1 >/dev/null 2>&1 || true
    command -v node >/dev/null || need+=(nodejs-lts)
    command -v npm >/dev/null || need+=(nodejs-lts)
    command -v patchelf >/dev/null || need+=(patchelf)
    # 有 root → dns53 原生方案; 无 root → proot 兜底 (wrapper 运行时自动选择)
    # 有 root 也装 proot: dns53 挂掉时用它绑 resolv.conf, 否则原生执行无 DNS
    if have_root; then
        command -v proot >/dev/null 2>&1 || need+=(proot)
    else
        need+=(proot)
        command -v sudo >/dev/null 2>&1 || need+=(sudo)
    fi
    if [ ${#need[@]} -gt 0 ]; then
        info "安装依赖: ${need[*]}"
        pkg install -y "${need[@]}" || fail "依赖安装失败, 请先手动执行 pkg update && pkg upgrade"
    else
        ok "依赖已就绪 (node $(node --version), patchelf)"
    fi
    # 装完后再判定一次 (刚装的 sudo 可能已可用); 有 root 但缺 proot 时补装
    load_root_backend 1 >/dev/null 2>&1 || true
    if have_root; then
        command -v proot >/dev/null 2>&1 \
            || { info "安装 proot (dns53 不可用时的 DNS 兜底)…"; pkg install -y proot; }
    else
        command -v proot >/dev/null 2>&1 || { info "未检测到 root, 安装 proot 兜底…"; pkg install -y proot; }
        warn "未检测到 root: 将使用 proot 兜底方案 (性能略降)"
    fi
}

# ---------- 镜像源适配 ----------
# 刚装的 Termux 默认官方源, 国内经常慢/不可达。本函数对候选源逐个探测 + 测速,
# 再按"新鲜度优先、速度兜底"选一个自动切换 (幂等; 切换后 apt update 失败会回滚)。
#
# 排序规则 —— 每一条都是实测踩出来的:
#   1) 可用性: HTTP 200 **且 Release 里能解析出 Date: 字段**
#      华为云是反例: /termux/... 路径下 Release 与 Packages 都返回 200, 内容却是
#      一个 12KB 的 HTML 页面。只校验状态码的话它会被算进候选。
#   2) 绝对陈旧: Release 日期距今超过 MIRROR_MAX_AGE 的直接判废。
#      腾讯云实测停留在 4 个月前 (2831 包 vs 官方 3009 包, python 3.13 vs 3.14)。
#   3) 新鲜度优先: Release 日期落后"最新的那个候选"超过 MIRROR_FRESH_GRACE 就不要。
#      实测 2026-10-19 —— 快慢和新鲜度并不一致:
#        官方/清华      python 3.14.8   nodejs 26.4.0-1   patchelf 0.19.2
#        中科大/阿里云  python 3.14.6-1 (其余同上)
#        腾讯云         python 3.13.13  nodejs 26.3.1    patchelf 0.19.0
#      只看速度很容易切到一个包版本偏旧的源。
#   4) 落在宽限窗口内的多个候选 → 选最快的。
MIRROR_FRESH_GRACE="${MIRROR_FRESH_GRACE:-43200}"   # 12 小时
MIRROR_MAX_AGE="${MIRROR_MAX_AGE:-2592000}"         # 30 天

# $1=Release 文件路径 → 输出 Unix 时间戳; 解析不出返回非零
release_ts() {
    local d
    d=$(awk -F': ' '/^Date: /{print $2; exit}' "$1" 2>/dev/null) || d=""
    [ -n "$d" ] || return 1
    date -d "$d" +%s 2>/dev/null || return 1
}

fix_mirror() {
    local sources_file="$PREFIX/etc/apt/sources.list"
    [ -f "$sources_file" ] || { warn "未找到 apt 源文件, 跳过镜像适配"; return; }

    # 候选: "显示名 base URL" (路径各不相同, 已逐个实测 HTTP 200)
    local candidates=(
        "官方 https://packages.termux.dev/apt/termux-main"
        "清华 https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
        "中科大 https://mirrors.ustc.edu.cn/termux/apt/termux-main"
        "阿里云 https://mirrors.aliyun.com/termux/termux-main"
        "北大 https://mirrors.pku.edu.cn/termux/termux-main"
        "南科大 https://mirrors.sustech.edu.cn/termux/apt/termux-main"
        "南阳理工 https://mirror.nyist.edu.cn/termux/apt/termux-main"
    )

    local work entry name url code ts age t1 t2 t i cut
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/mirror.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" RETURN

    local now n=0 newest=0
    local -a NAMES=() URLS=() TIMES=() STAMPS=()
    now=$(date +%s)

    for entry in "${candidates[@]}"; do
        name="${entry%% *}"
        url="${entry##* }"
        code=$(curl -s -o "$work/rel" -w '%{http_code}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || code=000
        if [ "$code" != "200" ]; then
            info "跳过 $name (Release HTTP $code)"
            continue
        fi
        # 关键在于必须解析得出 Date —— 挡掉返回 HTML 却给 200 的假源
        ts=$(release_ts "$work/rel") || {
            info "跳过 $name (Release 里没有 Date 字段 —— 多半是个返回网页的假源)"
            continue
        }
        age=$(( now - ts ))
        if [ "$age" -gt "$MIRROR_MAX_AGE" ]; then
            info "跳过 $name (同步于 $(( age / 86400 )) 天前, 太陈旧)"
            continue
        fi
        t1=$(curl -s -o /dev/null -w '%{time_total}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || t1=999
        t2=$(curl -s -o /dev/null -w '%{time_total}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || t2=999
        t=$(printf '%s\n%s\n' "$t1" "$t2" | sort -n | head -1)
        info "候选 $name: ${t}s, 同步于 $(( age / 3600 )) 小时前"
        [ "$ts" -gt "$newest" ] && newest=$ts
        NAMES+=("$name"); URLS+=("$url"); TIMES+=("$t"); STAMPS+=("$ts")
        n=$(( n + 1 ))
    done

    if [ "$n" -eq 0 ]; then
        warn "所有候选源都不可用, 保持当前配置 (可手动: pkg change-repo)"
        return
    fi

    # 只保留"新鲜度落在宽限窗口内"的, 再从中选最快的
    local best_name="" best_url="" best_t=999999 best_ts=0
    cut=$(( newest - MIRROR_FRESH_GRACE ))
    i=0
    while [ "$i" -lt "$n" ]; do
        if [ "${STAMPS[$i]}" -ge "$cut" ]; then
            t="${TIMES[$i]}"
            if [ -z "$best_url" ] || awk "BEGIN{exit !($t < $best_t)}"; then
                best_name="${NAMES[$i]}"; best_url="${URLS[$i]}"; best_t="$t"; best_ts="${STAMPS[$i]}"
            fi
        fi
        i=$(( i + 1 ))
    done

    if [ -z "$best_url" ]; then
        warn "候选源的同步时间都超出宽限窗口, 保持当前配置"
        return
    fi
    ok "选定源: $best_name (${best_t}s, 同步于 $(( (now - best_ts) / 3600 )) 小时前)"

    # 当前已是选定源 → 不动
    if grep -qF "$best_url" "$sources_file" 2>/dev/null; then
        ok "当前源已是选定源, 无需切换"
        return
    fi

    local backup="$sources_file.bak.$(date +%s)"
    cp "$sources_file" "$backup"
    warn "切换源: $(grep -oE 'https://[^ ]+' "$sources_file" | head -1) → $best_name"
    {
        echo "# 由 install.sh 自动切换 (选定: $best_name ${best_t}s, Release $(( (now - best_ts) / 3600 )) 小时前)"
        echo "deb $best_url stable main"
    } > "$sources_file"

    if DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1; then
        ok "apt update 成功 ($best_name), 原配置备份: $(basename "$backup")"
    else
        warn "apt update 失败, 已自动回滚到原配置"
        cp "$backup" "$sources_file"
        DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1 || true
    fi
}

upgrade_packages() {
    info "更新软件包索引并升级全部软件包…"
    info "提示: 全新 Termux 首次升级可能耗时数分钟 (下载量大), 请耐心等待, 不要打断"
    if DEBIAN_FRONTEND=noninteractive pkg upgrade -y; then
        ok "软件包已是最新"
    else
        warn "pkg upgrade 未完全成功, 请稍后重试 (pkg upgrade -y)"
    fi
}


# ---------- 证书修复 ----------
fix_cert() {
    if [ ! -f "$CERT_FILE" ]; then
        warn "未找到 CA 证书 ($CERT_FILE), 尝试安装 ca-certificates…"
        pkg install -y ca-certificates
    fi
    # 写入 .bashrc (幂等)
    if ! grep -q 'SSL_CERT_FILE' "$HOME_DIR/.bashrc" 2>/dev/null; then
        echo "export SSL_CERT_FILE=$CERT_FILE" >> "$HOME_DIR/.bashrc"
        info "SSL_CERT_FILE 已写入 ~/.bashrc"
    fi
    export SSL_CERT_FILE="$CERT_FILE"
    ok "证书路径已设置: $CERT_FILE"
}

# ---------- dns53 独立组件 ----------
# dns53 (musl 程序的 DNS 兜底) 不再内嵌在本脚本、也不再写入任何 agent 目录,
# 而是作为独立组件安装到 ~/.local/share/dns53, 源码与安装器见仓库 dns53/。
# 其他 agent 可复用同一目录, 也可直接运行:
#   bash ~/.local/share/dns53/install.sh
DNS53_DIR="${XDG_DATA_HOME:-$HOME_DIR/.local/share}/dns53"
DNS53_RAW_BASES=(
    "https://cdn.jsdelivr.net/gh/xkxxs/codex-termux@main/dns53"
    "https://raw.githubusercontent.com/xkxxs/codex-termux/main/dns53"
)
DNS53_FILES=(install.sh VERSION root.sh dns53.js dns-bootstrap.js dnsq.js check_dns.sh dns53-aaaa)

# ---------- root 探测 / 执行 ----------
# Android 上有 root 不等于装了 Termux 的 sudo 包: Magisk/KernelSU 只提供 su,
# 只认 `sudo -n` 会把这类设备误判成无 root。这里优先复用 dns53 组件的 root.sh
# (探测顺序 direct → sudo -n → su -c, 结果缓存到 $DNS53_DIR/.root_mode),
# 组件还没下载时用下面的等价内置实现。
ROOT_HELPER=""
ROOT_MODE=""

load_root_backend() {
    if [ -n "$ROOT_HELPER" ]; then
        if [ "${1:-0}" = 1 ]; then dns53_load_root_mode 1; fi
        return 0
    fi
    local f
    for f in "${SCRIPT_DIR:+$SCRIPT_DIR/dns53/root.sh}" "$DNS53_DIR/root.sh"; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        # shellcheck source=/dev/null
        . "$f"
        ROOT_HELPER="$f"
        dns53_load_root_mode "${1:-0}"
        return 0
    done
    return 1
}

# 内置探测 (仅在没有 root.sh 可用时): 与 dns53/root.sh 的探测顺序一致
detect_root_mode() {
    if [ "$(id -u 2>/dev/null)" = 0 ]; then echo direct; return 0; fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then echo sudo; return 0; fi
    if command -v su >/dev/null 2>&1; then
        local u
        u="$(timeout 5 su -c 'id -u' 2>/dev/null | tr -d '\r' | head -n 1 || true)"
        if [ "$u" = 0 ]; then echo su; return 0; fi
    fi
    echo none
}

have_root() {
    if load_root_backend 0; then
        dns53_have_root
        return
    fi
    [ "$(detect_root_mode)" != none ]
}

# 以 root 执行一条命令 (direct 直接跑 / sudo -n 不弹窗 / su -c 带转义)
root_exec() {
    if load_root_backend 0; then
        dns53_root_exec "$@"
        return
    fi
    case "$(detect_root_mode)" in
        direct) "$@" ;;
        sudo)   sudo -n "$@" ;;
        su)
            # Magisk/KernelSU 的 root shell PATH 可能不含 Termux 的 bin
            local p="${PREFIX:-/data/data/com.termux/files/usr}/bin"
            su -c "PATH=$p:/system/bin:/system/xbin:\$PATH $(printf '%q ' "$@")"
            ;;
        *)      return 1 ;;
    esac
}

fetch_dns53_payload() {
    local dst="$1" base f all
    mkdir -p "$dst"
    for base in "${DNS53_RAW_BASES[@]}"; do
        all=1
        for f in "${DNS53_FILES[@]}"; do
            if ! curl -fsSL --connect-timeout 10 --max-time 60 "$base/$f" -o "$dst/$f"; then
                all=0
                break
            fi
        done
        if [ "$all" = "1" ]; then
            return 0
        fi
        warn "dns53 组件下载失败, 换源: $base"
    done
    return 1
}

install_dns53() {
    local src="" tmp=""
    if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/dns53/install.sh" ]; then
        src="$SCRIPT_DIR/dns53"
        info "dns53 组件: 使用本地仓库 dns53/"
    else
        tmp="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/dns53.XXXXXX")" || tmp=""
        if [ -n "$tmp" ] && fetch_dns53_payload "$tmp"; then
            src="$tmp"
            info "dns53 组件: 已从仓库下载"
        else
            if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
            tmp=""
            if [ -f "$DNS53_DIR/install.sh" ]; then
                src="$DNS53_DIR"
                warn "dns53 组件下载失败, 沿用已安装版本"
            else
                warn "dns53 组件获取失败, 跳过 DNS 配置 (可稍后重跑本脚本)"
                return 0
            fi
        fi
    fi
    if ! bash "$src/install.sh"; then
        warn "dns53 组件安装异常 (详见上方输出)"
    fi
    if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
}


# ---------- SELinux context 自愈 ----------
# Android SELinux MLS: 若 codex 相关文件 context 缺少当前进程的 MCS 类别
# (常见于曾被 root/magisk 创建的文件, 只有 s0 无类别), untrusted_app 将无法
# rename/readlink → npm install 报 EACCES。有 root 时对齐文件的 MLS 级别自愈。
# 注意: 进程 context 是 domain (u:r:...), 文件必须是 type (u:object_r:...),
#       只能取进程的 :sN... 类别段拼到文件已有 type 上。
fix_selinux_context() {
    local ctx mcs
    ctx=$(tr -d '\0' < /proc/self/attr/current 2>/dev/null || true)
    [ -n "$ctx" ] || return 0
    mcs=$(printf '%s' "$ctx" | sed -n 's/.*\(:s[0-9][0-9]*.*\)$/\1/p')
    [ -n "$mcs" ] || return 0
    have_root || return 0

    local fixed=0 p fctx target
    for p in "$PREFIX/bin/codex" "$CODEX_PKG_DIR"; do
        # 坏 context 的 symlink 无法被 unprivileged -e 探测, 先查 -L
        if [ ! -L "$p" ] && [ ! -e "$p" ]; then
            root_exec test -e "$p" 2>/dev/null || continue
        fi
        fctx=$(root_exec stat -c '%C' "$p" 2>/dev/null || true)
        [ -n "$fctx" ] || continue
        target="${fctx%%:s*}${mcs}"
        [ "$fctx" != "$target" ] || continue
        if [ -L "$p" ]; then
            root_exec chcon -h "$target" "$p" 2>/dev/null && fixed=1
        else
            root_exec chcon -R "$target" "$p" 2>/dev/null && fixed=1
        fi
    done
    if [ "$fixed" = 1 ]; then
        ok "已修复 SELinux context (MCS 类别对齐)"
    fi
    return 0
}

# ---------- 安装官方 Codex ----------
install_codex() {
    info "安装官方 @openai/codex (npm)…"
    fix_selinux_context

    local rc=0
    run_with_spinner "安装 @openai/codex (npm)…" npm install -g @openai/codex@latest || rc=$?
    if [ "$rc" -ne 0 ] && grep -q 'EACCES' "$SPIN_LOG" 2>/dev/null; then
        warn "npm 报 EACCES, 尝试修复 SELinux context 后重试…"
        fix_selinux_context
        rc=0
        run_with_spinner "安装 @openai/codex (npm)…" npm install -g @openai/codex@latest || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        fail "npm 安装失败 (错误见上)"
    fi
    rm -f "$SPIN_LOG"

    local version
    version=$(npm view @openai/codex version) || fail "无法获取版本号"
    info "下载 linux-arm64 平台二进制 v$version (绕过 npm os 限制)…"

    # npm 会因 os=linux vs android 拒绝安装平台包, 手动解压 tarball
    local work tgz
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/codex-pkg.XXXXXX")
    tgz="$work/codex.tgz"
    download_npm_tarball "@openai/codex@${version}-linux-arm64" "$tgz" || fail "平台包下载失败"
    mkdir -p "$CODEX_PKG_DIR"
    tar xzf "$tgz" -C "$CODEX_PKG_DIR" --strip-components=1 package/vendor
    rm -rf "$work"

    [ -x "$VENDOR_BIN" ] || fail "二进制未就位: $VENDOR_BIN"
    chmod +x "$VENDOR_BIN"
    ok "Codex $version 二进制已安装"
}

# ---------- 关闭 app-server daemon ----------
# Codex ≥0.157 新增实验性 app-server daemon: 启动时 fork 守护进程并连它的 unix socket,
# 而该守护进程在 Android 上启动即退出 ("Error: No such file or directory (os error 2)",
# 与 musl/patchelf 无关 —— 它的两个二进制都是静态的且单独跑都正常), 于是 CLI 卡在
#   "app server did not become ready on ~/.codex/app-server-control/app-server-control.sock"
# 官方给了两个规避: 每条命令加 --no-daemon, 或配置 daemon_auto_start = false (0.157 起被识别)。
# 这里写配置一劳永逸; 用户显式设过则不动 (幂等)。
disable_app_server_daemon() {
    local cfg="$HOME_DIR/.codex/config.toml"
    mkdir -p "$HOME_DIR/.codex" 2>/dev/null || { warn "无法创建 ~/.codex, 跳过 daemon 设置"; return 0; }
    if [ ! -f "$cfg" ]; then
        printf 'daemon_auto_start = false\n' > "$cfg"
        ok "已写入 $cfg (关闭 app-server daemon 自动启动)"
        return 0
    fi
    if grep -qE '^[[:space:]]*daemon_auto_start' "$cfg" 2>/dev/null; then
        ok "app-server daemon 设置已存在, 未改动"
        return 0
    fi
    printf '\ndaemon_auto_start = false\n' >> "$cfg"
    ok "已追加 daemon_auto_start = false 到 ~/.codex/config.toml"
}

# ---------- 启动 wrapper ----------
write_wrapper() {
    mkdir -p "$HOME_DIR/.local/bin"
    cat > "$WRAPPER_PATH" << 'WRAPPER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# codex wrapper for Termux (由 codex-termux/install.sh 生成)
# - 启动前自动检查最新版本, 非最新则自动更新再启动
#   (可用 CODEX_NO_AUTO_UPDATE=1 跳过检查)
# - 固定 ~/.codex/version.json, 避免上游版本号与本地二进制
#   不一致导致的假升级循环
# - 注入 SSL_CERT_FILE (musl 二进制不认 Android 的 CA 路径)
# - DNS: 有 root → dns53 转发器; 无 root → proot 绑 resolv.conf
# ============================================================
set -euo pipefail

# musl 二进制不认识 Android 的 CA 路径, 必须指定
export SSL_CERT_FILE="${SSL_CERT_FILE:-/data/data/com.termux/files/usr/etc/tls/cert.pem}"

REAL_JS="/data/data/com.termux/files/usr/lib/node_modules/@openai/codex/bin/codex.js"
PKG_DIR="/data/data/com.termux/files/usr/lib/node_modules/@openai/codex"
VENDOR_BIN="$PKG_DIR/vendor/aarch64-unknown-linux-musl/bin/codex"
VERSION_FILE="$HOME/.codex/version.json"
# dns53 独立组件 (与 agent 目录解耦)
DNS53_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dns53"

# root 判定: 优先用 dns53 组件的 root.sh (direct → sudo -n → su -c,
# 结果缓存到 $DNS53_DIR/.root_mode); 没有 root.sh 时退回内置探测。
# Android 上 Magisk/KernelSU 只提供 su, 不能只认 Termux 的 sudo 包。
if [ -f "$DNS53_DIR/root.sh" ]; then
    . "$DNS53_DIR/root.sh"
    dns53_load_root_mode 0
fi

have_root() {
    if command -v dns53_have_root >/dev/null 2>&1; then
        dns53_have_root
        return
    fi
    [ "$(id -u 2>/dev/null)" = 0 ] && return 0
    command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && return 0
    if command -v su >/dev/null 2>&1; then
        local u
        u="$(timeout 5 su -c 'id -u' 2>/dev/null | tr -d '\r' | head -n 1 || true)"
        [ "$u" = 0 ] && return 0
    fi
    return 1
}

# 以 root 执行一条命令: dns53_root_exec (direct/sudo/su) 优先, 否则 sudo -n
root_exec() {
    if command -v dns53_root_exec >/dev/null 2>&1; then
        dns53_root_exec "$@"
        return
    fi
    have_root || return 1
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -n "$@"
        return
    fi
    local p="${PREFIX:-/data/data/com.termux/files/usr}/bin"
    su -c "PATH=$p:/system/bin:/system/xbin:\$PATH $(printf '%q ' "$@")"
}

# 本地实际版本 (如 0.147.0); 失败时为空
current_version() {
    node "$REAL_JS" --version 2>/dev/null | sed 's/.*cli //'
}

# ---------- 下载进度 ----------
# npm pack 无进度显示: 先用 npm view 拿真实 URL (跟随 registry 配置),
# 再用 curl --progress-bar 下载; 失败换镜像, 再回退 npm pack。
SPIN_CHARS='|/-\'
SPIN_LOG=""

run_with_spinner() {
    local msg="$1"; shift
    SPIN_LOG="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/spin.$$.log"
    "$@" >"$SPIN_LOG" 2>&1 &
    local pid=$! i=0 t0=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r\033[K%s %s (%ds)' "$msg" "${SPIN_CHARS:$((i++ % 4)):1}" "$((SECONDS - t0))"
        sleep 0.5
    done
    wait "$pid"; local rc=$?
    printf '\r\033[K'
    if [ "$rc" -ne 0 ]; then
        echo "!! $msg 失败, 输出如下:" >&2
        cat "$SPIN_LOG" >&2
    else
        echo "$msg 完成 ($((SECONDS - t0))秒)"
    fi
    return $rc
}

npm_tarball_url() { npm view "$1" dist.tarball 2>/dev/null | tail -1; }

download_npm_tarball() {
    local spec="$1" out="$2" url="" alt=""
    url="$(npm_tarball_url "$spec")"
    if [ -n "$url" ]; then
        curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$url" -o "$out" && return 0
        case "$url" in
            *registry.npmjs.org*)     alt="${url/registry.npmjs.org/registry.npmmirror.com}" ;;
            *registry.npmmirror.com*) alt="${url/registry.npmmirror.com/registry.npmjs.org}" ;;
        esac
        if [ -n "$alt" ] && [ "$alt" != "$url" ]; then
            echo "!! 直连失败, 换镜像重试…" >&2
            curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$alt" -o "$out" && return 0
        fi
    fi
    echo "→ 直连失败, 回退 npm pack (无进度显示)…" >&2
    (cd "$(dirname "$out")" && npm pack "$spec" --silent >/dev/null 2>&1) || return 1
    local packed
    packed="$(ls "$(dirname "$out")"/*.tgz 2>/dev/null | head -1)"
    [ -n "$packed" ] || return 1
    [ "$packed" = "$out" ] || mv -f "$packed" "$out"
    return 0
}

# npm 源上的最新版本; 失败时为空 (快速失败, 不拖慢启动)
latest_version() {
    npm view @openai/codex version --fetch-timeout=10000 --fetch-retries=0 2>/dev/null || true
}

# 版本比较: $1 >= $2 返回 0 (sort -V 语义)
version_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# Codex ≥0.157 的 app-server daemon 在 Android 上起不来 → 关掉自动启动。
# 幂等: 用户自己显式设过 daemon_auto_start 就不动。
ensure_no_daemon() {
    local cfg="$HOME/.codex/config.toml"
    mkdir -p "$HOME/.codex" 2>/dev/null || return 0
    if [ ! -f "$cfg" ]; then
        printf 'daemon_auto_start = false\n' > "$cfg"
        return 0
    fi
    grep -qE '^[[:space:]]*daemon_auto_start' "$cfg" 2>/dev/null \
        || printf '\ndaemon_auto_start = false\n' >> "$cfg"
}

# 固定 version.json 为当前实际版本, 避免假升级循环
pin_version() {
    local v
    v="$(current_version)"
    cat > "$VERSION_FILE" <<EOF
{"latest_version":"$v","last_checked_at":"$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)","dismissed_version":"$v"}
EOF
}

# SELinux context 自愈: 缺 MCS 类别时 untrusted_app 无法 rename → npm EACCES
# 进程是 domain (u:r:...), 文件须用 type (u:object_r:...) + 进程的 :sN 类别
fix_selinux_context() {
    local ctx mcs
    ctx=$(tr -d '\0' < /proc/self/attr/current 2>/dev/null || true)
    [ -n "$ctx" ] || return 0
    mcs=$(printf '%s' "$ctx" | sed -n 's/.*\(:s[0-9][0-9]*.*\)$/\1/p')
    [ -n "$mcs" ] || return 0
    have_root || return 0
    local fixed=0 p fctx target
    for p in /data/data/com.termux/files/usr/bin/codex "$PKG_DIR"; do
        if [ ! -L "$p" ] && [ ! -e "$p" ]; then
            root_exec test -e "$p" 2>/dev/null || continue
        fi
        fctx=$(root_exec stat -c '%C' "$p" 2>/dev/null || true)
        [ -n "$fctx" ] || continue
        target="${fctx%%:s*}${mcs}"
        [ "$fctx" != "$target" ] || continue
        if [ -L "$p" ]; then
            root_exec chcon -h "$target" "$p" 2>/dev/null && fixed=1
        else
            root_exec chcon -R "$target" "$p" 2>/dev/null && fixed=1
        fi
    done
    [ "$fixed" = 1 ] && echo "→ 已修复 SELinux context (MCS 类别对齐)"
    return 0
}

# 完整更新: npm 主包 → 下载对应 linux-arm64 平台二进制 → 解压 vendor。
# 失败返回 1, 不影响旧二进制继续使用。
do_update() {
    echo "→ 更新 @openai/codex (npm 主包)…"
    fix_selinux_context
    local rc=0
    run_with_spinner "更新 @openai/codex (npm)…" npm install -g @openai/codex@latest || rc=$?
    if [ "$rc" -ne 0 ] && grep -q 'EACCES' "$SPIN_LOG" 2>/dev/null; then
        echo "→ npm 报 EACCES, 尝试修复 SELinux context 后重试…"
        fix_selinux_context
        rc=0
        run_with_spinner "更新 @openai/codex (npm)…" npm install -g @openai/codex@latest || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        return 1
    fi
    rm -f "$SPIN_LOG"
    local ver
    ver="$(npm view @openai/codex version --fetch-timeout=10000 --fetch-retries=0 2>/dev/null)" || return 1
    echo "→ 下载 linux-arm64 平台二进制 v${ver} (绕过 npm os 限制)…"
    local work tgz
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/codex-update.XXXXXX") || return 1
    tgz="$work/codex.tgz"
    download_npm_tarball "@openai/codex@${ver}-linux-arm64" "$tgz" || { rm -rf "$work"; return 1; }
    rm -rf "$PKG_DIR/vendor"
    tar xzf "$tgz" -C "$PKG_DIR" --strip-components=1 package/vendor
    rm -rf "$work"
    [ -x "$VENDOR_BIN" ] || return 1
    chmod +x "$VENDOR_BIN"
    pin_version
    echo "✓ 已更新: $(current_version)"
}

case "${1:-}" in
    --update|-u|update|upgrade)
        do_update || { echo "!! 更新失败" >&2; exit 1; }
        ;;
    *)
        # 自动更新: 启动前查一次最新版 (失败静默跳过),
        # 非最新则自动更新; 更新失败不阻塞, 用现有版本启动
        if [ "${CODEX_NO_AUTO_UPDATE:-0}" != "1" ] && command -v npm >/dev/null 2>&1; then
            LATEST="$(latest_version)"
            if [ -n "$LATEST" ]; then
                CURRENT="$(current_version)"
                if [ -z "$CURRENT" ] || ! version_ge "$CURRENT" "$LATEST"; then
                    echo "→ 检测到新版本 v${LATEST} (当前 ${CURRENT:-未知}), 自动更新…"
                    if do_update; then
                        echo "→ 更新完毕, 继续启动 codex…"
                    else
                        echo "!! 自动更新失败, 继续使用现有版本启动" >&2
                    fi
                fi
            fi
        fi
        pin_version
        ensure_no_daemon
        # 交互式 TUI (codex / codex "提示词" / codex resume ...) 会显式要求 app-server daemon,
        # 配置里的 daemon_auto_start=false 只挡得住"自动拉起", 挡不住这个显式要求 → 必须补 --no-daemon。
        # 仅对 ≥0.157 生效 (老版本没有这个 flag, 传了会报 unexpected argument)。
        # 唯一例外是 app-server 子命令本身 (它就是拿来管 daemon 的)。
        cur_v="${CURRENT:-$(current_version)}"
        if [ -n "$cur_v" ] && [ "$(printf '%s\n%s\n' "$cur_v" "0.157.0" | sort -V | tail -n1)" = "$cur_v" ] \
           && [ "${1:-}" != "app-server" ] \
           && ! printf '%s\n' "$@" | grep -qx -- '--no-daemon'; then
            set -- --no-daemon "$@"
        fi
        RESOLV_CONF="${PREFIX:-/data/data/com.termux/files/usr}/etc/resolv.conf"
        # 有 root: 确保本地 DNS 转发器在跑 (见 README "DNS 修复")
        #   有 root.sh → direct/sudo/su 探测 + dns53 心跳判断; dns53 起不来时
        #   用 proot 绑 resolv.conf 兜底, 否则原生执行没有可用 DNS。
        # 无 root: dns-bootstrap 实测校验后 proot 绑定 resolv.conf
        if [ -f "$DNS53_DIR/root.sh" ] && have_root; then
            if ! dns53_alive && [ -f "$DNS53_DIR/dns53.js" ]; then
                mkdir -p "$DNS53_DIR/logs"
                dns53_root_exec nohup node "$DNS53_DIR/dns53.js" >> "$DNS53_DIR/logs/dns53.log" 2>&1 &
                sleep 1
            fi
            if dns53_alive; then
                exec node "$REAL_JS" "$@"
            fi
            # dns53 没起来: 有 proot 就绑 resolv.conf 兜底
            if command -v proot >/dev/null 2>&1; then
                [ -f "$RESOLV_CONF" ] || { echo "缺少 $RESOLV_CONF, 请重跑安装脚本" >&2; exit 1; }
                if [ -f "$DNS53_DIR/dns-bootstrap.js" ]; then
                    node "$DNS53_DIR/dns-bootstrap.js" \
                        || echo "!! 网络 DNS 全部不可用 (UDP 53 被拦截?), 已用公共 DNS 兜底继续启动" >&2
                fi
                exec proot -b "$RESOLV_CONF:/etc/resolv.conf" node "$REAL_JS" "$@"
            fi
            echo "!! dns53 未运行且缺少 proot, 直接启动 (DNS 可能失效)" >&2
            exec node "$REAL_JS" "$@"
        elif [ ! -f "$DNS53_DIR/root.sh" ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            # 旧安装 (无 root.sh): 保持原有 sudo -n 行为
            if ! sudo -n pgrep -f "dns5[3].js" > /dev/null 2>&1 && [ -f "$DNS53_DIR/dns53.js" ]; then
                mkdir -p "$DNS53_DIR/logs"
                sudo -n nohup node "$DNS53_DIR/dns53.js" >> "$DNS53_DIR/logs/dns53.log" 2>&1 &
                sleep 1
            fi
            exec node "$REAL_JS" "$@"
        elif command -v proot >/dev/null 2>&1; then
            [ -f "$RESOLV_CONF" ] || { echo "缺少 $RESOLV_CONF, 请重跑安装脚本" >&2; exit 1; }
            # 常驻校验器没在跑 → 单次实测重写 resolv.conf
            if [ -f "$DNS53_DIR/dns-bootstrap.js" ] && ! pgrep -f "dns-bootstrap[.]js.*daemon" > /dev/null 2>&1; then
                node "$DNS53_DIR/dns-bootstrap.js" \
                    || echo "!! 网络 DNS 全部不可用 (UDP 53 被拦截?), 已用公共 DNS 兜底继续启动" >&2
            fi
            exec proot -b "$RESOLV_CONF:/etc/resolv.conf" node "$REAL_JS" "$@"
        else
            echo "未检测到 root 且缺少 proot, 请先安装: pkg install proot" >&2
            exit 1
        fi
        ;;
esac
WRAPPER_EOF
    chmod +x "$WRAPPER_PATH"

    # 确保 ~/.local/bin 在 PATH 中且优先
    if ! grep -q '\.local/bin' "$HOME_DIR/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.bashrc"
        info "~/.local/bin 已加入 PATH (~/.bashrc)"
    fi
    ok "启动 wrapper 已生成: $WRAPPER_PATH"
}

# ---------- 验证 ----------
verify() {
    local bin="$HOME_DIR/.local/bin/codex"
    local ver
    ver=$(PATH="$HOME_DIR/.local/bin:$PATH" "$bin" --version 2>/dev/null) \
        || ver=$("$PREFIX/bin/node" "$CODEX_PKG_DIR/bin/codex.js" --version 2>/dev/null) \
        || fail "验证失败: codex 无法运行"
    ok "安装成功: $ver"
}

# ---------- 卸载 ----------
uninstall() {
    warn "将卸载 Codex 并移除 wrapper (保留 ~/.codex 配置)…"
    npm uninstall -g @openai/codex >/dev/null 2>&1 || true
    rm -f "$WRAPPER_PATH"
    ok "已卸载。如需删除配置: rm -rf ~/.codex"
    warn "dns53 独立组件已保留 — opencode 等其他 musl 程序可能依赖它"
    warn "如需一并移除: bash ~/.local/share/dns53/install.sh --uninstall"
    exit 0
}

# ---------- 配置指引 ----------
show_guide() {
    echo
    echo "=============================================================="
    echo "  安装完成! 下一步: 配置模型"
    echo "=============================================================="
    echo
    echo "  Codex 只安装不配置, 请参考官方文档配置 DeepSeek 等模型:"
    echo "    $UPSTREAM_DOCS_URL"
    echo
    echo "  DeepSeek 官方提供一键配置脚本 (需要先运行一次 codex):"
    echo "    bash <(curl -fsSL https://cdn.deepseek.com/api-docs/codex-deepseek-setup.sh)"
    echo
    echo "  手动配置要点 (config.toml):"
    echo "    model_catalog_json 必须用绝对路径, 不要用 ~"
    echo "    base_url  = https://api.deepseek.com/"
    echo "    wire_api  = responses"
    echo "=============================================================="
    echo
    echo "  常用命令:"
    echo "    codex                  启动"
    echo "    codex update           更新到最新版"
    echo "    重跑本脚本即更新        (bash <(curl -fsSL …/install.sh))"
    echo "    重跑本脚本 --uninstall 卸载"
}

# ---------- 主流程 ----------
case "${1:-}" in
    --uninstall) uninstall ;;
esac

info "codex-termux 安装脚本 — 仅支持 Termux aarch64"
check_environment
fix_mirror
upgrade_packages
install_dependencies
fix_cert
install_codex
disable_app_server_daemon
write_wrapper
install_dns53
verify
show_guide
