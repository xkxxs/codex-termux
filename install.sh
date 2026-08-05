#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# codex-termux — 在 Termux (Android aarch64) 上一键安装官方 Codex CLI
#
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<USER>/codex-termux/main/install.sh)
#   bash <(curl -fsSL https://raw.githubusercontent.com/<USER>/codex-termux/main/install.sh) --update
#   bash <(curl -fsSL https://raw.githubusercontent.com/<USER>/codex-termux/main/install.sh) --uninstall
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
CERT_FILE="$PREFIX/etc/tls/cert.pem"
UPSTREAM_DOCS_URL="https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/codex"

# ---------- 颜色 ----------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[1;36m'; NC='\033[0m'
ok()   { echo -e "${GRN}✓${NC} $*"; }
info() { echo -e "${BLU}▸${NC} $*"; }
warn() { echo -e "${YEL}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

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
    command -v node >/dev/null || need+=(nodejs-lts)
    command -v npm >/dev/null || need+=(nodejs-lts)
    command -v patchelf >/dev/null || need+=(patchelf)
    command -v sudo >/dev/null || need+=(sudo)  # dns53 绑定特权端口 53 需要 root
    if [ ${#need[@]} -gt 0 ]; then
        info "安装依赖: ${need[*]}"
        pkg install -y "${need[@]}" || fail "依赖安装失败, 请先手动执行 pkg update && pkg upgrade"
    else
        ok "依赖已就绪 (node $(node --version), patchelf)"
    fi
}

# ---------- 镜像源适配 ----------
# 刚装的 Termux 默认官方源 (packages.termux.dev) 在国内经常连不上/极慢,
# 连依赖都装不上。检测到官方源不可达时, 自动切换阿里云镜像 (幂等)。
fix_mirror() {
    local files=()
    [ -f "$PREFIX/etc/apt/sources.list" ] && files+=("$PREFIX/etc/apt/sources.list")
    for f in "$PREFIX"/etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] && files+=("$f")
    done
    [ ${#files[@]} -eq 0 ] && { warn "未找到 apt 源文件, 跳过镜像适配"; return; }

    # 已用国内镜像 → 跳过
    if grep -qE 'mirrors\.(aliyun|tuna|ustc|tencent|huaweicloud|bfsu)\.' "${files[@]}" 2>/dev/null; then
        ok "已使用国内镜像源, 无需切换"
        return
    fi

    # 官方源 → 测连通性
    if grep -qE 'packages\.termux\.dev|termux\.net' "${files[@]}" 2>/dev/null; then
        info "检测到官方源 (packages.termux.dev), 测试连通性…"
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 \
            https://packages.termux.dev/apt/termux-main/dists/stable/Release 2>/dev/null || echo 000)
        if [ "$code" = "200" ] || [ "$code" = "301" ]; then
            ok "官方源可达 (HTTP $code), 保持默认"
            return
        fi
        warn "官方源不可达 (HTTP $code), 切换为阿里云镜像…"
        local f
        for f in "${files[@]}"; do
            if grep -qE 'packages\.termux\.dev|termux\.net' "$f"; then
                cp "$f" "$f.bak.$(date +%s)"
                sed -i 's#https://packages\.termux\.dev#https://mirrors.aliyun.com/termux#g; s#https://termux\.net#https://mirrors.aliyun.com/termux#g' "$f"
                info "已切换: $f (原配置已备份)"
            fi
        done
        if apt update -y >/dev/null 2>&1; then
            ok "apt update 成功 (阿里云镜像)"
        else
            warn "apt update 失败, 请手动检查: pkg change-repo"
        fi
    else
        warn "未识别源格式, 跳过 (如遇源问题可手动: pkg change-repo)"
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

# ---------- DNS 修复 ----------
# musl 解析器读不到 /etc/resolv.conf (Android 没有), 回退 127.0.0.1:53
# 而手机无人监听该端口 → 每次 API 请求卡满 5s 超时 (报错与 SSL 证书问题
# 几乎相同: "error sending request for url")。方案: 本地转发器 + .bashrc 常驻。
fix_dns() {
    local dns53="$HOME_DIR/.local/bin/dns53.js"
    mkdir -p "$HOME_DIR/.local/bin"

    if [ ! -f "$dns53" ]; then
        cat > "$dns53" << 'DNS53_EOF'
#!/usr/bin/env node
// dns53 — 本地 DNS 转发器 (127.0.0.1:53)
// 背景: musl 程序 (codex/opencode) 解析器读不到 /etc/resolv.conf (Android 没有),
//       回退到默认 127.0.0.1:53, 而手机无人监听 → DNS 卡死 5s 超时。
// 方案: 在 127.0.0.1:53 监听 UDP, 原样转发到上游 DNS (阿里→腾讯→电信), 回传响应。
const dgram = require('dgram');
const fs = require('fs');

const UPSTREAMS = [
  ['223.5.5.5', 53],      // 阿里
  ['119.29.29.29', 53],   // 腾讯
  ['218.85.152.99', 53],  // 电信(可换成本地运营商DNS)
];
const TIMEOUT_MS = 2000;
const LOG = process.env.DNS53_LOG || process.env.HOME + '/.codex/dns53.log';
const log = (m) => { try { fs.appendFileSync(LOG, `${new Date().toISOString()} ${m}\n`); } catch (_) {} };

const server = dgram.createSocket('udp4');

server.on('message', (msg, rinfo) => {
  let i = 0;
  const tryNext = () => {
    if (i >= UPSTREAMS.length) return; // 全部失败, 静默丢弃
    const [host, port] = UPSTREAMS[i++];
    const sock = dgram.createSocket('udp4');
    let done = false;
    const timer = setTimeout(() => {
      if (!done) { done = true; sock.close(); log(`timeout ${host}, retry`); tryNext(); }
    }, TIMEOUT_MS);
    sock.on('message', (resp) => {
      if (done) return;
      done = true; clearTimeout(timer); sock.close();
      server.send(resp, rinfo.port, rinfo.address);
    });
    sock.on('error', (e) => {
      if (!done) { done = true; clearTimeout(timer); sock.close(); log(`error ${host}: ${e.message}`); tryNext(); }
    });
    sock.send(msg, port, host, (e) => {
      if (e && !done) { done = true; clearTimeout(timer); sock.close(); tryNext(); }
    });
  };
  tryNext();
});

server.on('error', (e) => log(`server error: ${e.message}`));
server.bind(53, '127.0.0.1', () => {
  log('dns53 listening on 127.0.0.1:53');
  console.log('dns53 listening on 127.0.0.1:53');
});
DNS53_EOF
        chmod +x "$dns53"
        info "dns53.js 已生成: $dns53"
    fi

    # 写入 .bashrc 常驻 (幂等)
    if ! grep -q 'dns53' "$HOME_DIR/.bashrc" 2>/dev/null; then
        cat >> "$HOME_DIR/.bashrc" << 'BASHRC_EOF'

# ===== DNS 转发器常驻 (dns53) =====
# 背景: musl 程序 (codex/opencode) 的解析器读不到 /etc/resolv.conf (Android 没有),
#       回退到 127.0.0.1:53, 而手机无人监听 → DNS 卡死 5s 超时。
# dns53.js 在本机 53 端口监听, 转发到阿里/腾讯/电信 DNS, 是这些程序的唯一出路。
# 每次打开 Termux 终端检查一次, 没在跑就拉起 (root 绑定特权端口)。
if ! pgrep -f "dns5[3].js" > /dev/null 2>&1; then
    sudo nohup node "$HOME/.local/bin/dns53.js" > "$HOME/.codex/dns53.log" 2>&1 &
    sleep 1
fi
BASHRC_EOF
        info "dns53 常驻逻辑已写入 ~/.bashrc"
    fi

    # 立即启动
    if command -v sudo >/dev/null 2>&1; then
        if ! pgrep -f "dns5[3].js" > /dev/null 2>&1; then
            sudo nohup node "$dns53" > "$HOME_DIR/.codex/dns53.log" 2>&1 &
            sleep 1
            ok "DNS 转发器已启动 (127.0.0.1:53)"
        else
            ok "DNS 转发器已在运行"
        fi
    else
        warn "未检测到 sudo, 请手动启动: sudo node ~/.local/bin/dns53.js"
    fi
}

# ---------- 安装官方 Codex ----------
install_codex() {
    info "安装官方 @openai/codex (npm)…"
    npm install -g @openai/codex@latest >/dev/null 2>&1 || fail "npm 安装失败"

    local version
    version=$(npm view @openai/codex version) || fail "无法获取版本号"
    info "下载 linux-arm64 平台二进制 v$version (绕过 npm os 限制)…"

    # npm 会因 os=linux vs android 拒绝安装平台包, 手动解压 tarball
    local tarball
    tarball=$(npm pack "@openai/codex@${version}-linux-arm64" --silent) || fail "平台包下载失败"
    mkdir -p "$CODEX_PKG_DIR"
    tar xzf "$tarball" -C "$CODEX_PKG_DIR" --strip-components=1 package/vendor
    rm -f "$tarball"

    [ -x "$VENDOR_BIN" ] || fail "二进制未就位: $VENDOR_BIN"
    chmod +x "$VENDOR_BIN"
    ok "Codex $version 二进制已安装"
}

# ---------- 启动 wrapper ----------
write_wrapper() {
    mkdir -p "$HOME_DIR/.local/bin"
    cat > "$WRAPPER_PATH" << 'WRAPPER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# musl 二进制不认识 Android 的 CA 路径, 必须指定
export SSL_CERT_FILE="${SSL_CERT_FILE:-/data/data/com.termux/files/usr/etc/tls/cert.pem}"

REAL_JS="/data/data/com.termux/files/usr/lib/node_modules/@openai/codex/bin/codex.js"
VERSION_FILE="$HOME/.codex/version.json"

detect_version() {
    node "$REAL_JS" --version 2>/dev/null | sed 's/.*cli //'
}

INSTALLED_VERSION="$(detect_version)"

# 固定 version.json, 避免上游版本号与本地二进制不一致导致假升级循环
pin_version() {
    cat > "$VERSION_FILE" <<EOF
{"latest_version":"$INSTALLED_VERSION","last_checked_at":"$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)","dismissed_version":"$INSTALLED_VERSION"}
EOF
}

case "${1:-}" in
    --update|-u|update|upgrade)
        echo "→ Updating @openai/codex …"
        npm install -g @openai/codex@latest
        NEWVER=$(npm view @openai/codex version)
        echo "→ Downloading platform binary v${NEWVER} …"
        TARBALL=$(npm pack "@openai/codex@${NEWVER}-linux-arm64" --silent)
        tar xzf "$TARBALL" -C /data/data/com.termux/files/usr/lib/node_modules/@openai/codex/ --strip-components=1 package/vendor
        rm -f "$TARBALL"
        INSTALLED_VERSION="$(detect_version)"
        pin_version
        echo "✓ Updated to $INSTALLED_VERSION"
        ;;
    *)
        pin_version
        # musl 解析器读不到 /etc/resolv.conf, 回退 127.0.0.1:53 无人监听
        # → DNS 卡死 5s 超时。确保本地 DNS 转发器在跑 (见 README "DNS 修复")。
        if ! pgrep -f "dns5[3].js" > /dev/null; then
            sudo nohup node "$HOME/.local/bin/dns53.js" > "$HOME/.codex/dns53.log" 2>&1 &
            sleep 1
        fi
        exec node "$REAL_JS" "$@"
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
    warn "DNS 转发器 (dns53) 已保留 — opencode 等其他 musl 程序可能依赖它"
    warn "如需一并移除: rm ~/.local/bin/dns53.js 并删除 ~/.bashrc 中的 dns53 常驻块"
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
install_dependencies
fix_cert
install_codex
write_wrapper
fix_dns
verify
show_guide
