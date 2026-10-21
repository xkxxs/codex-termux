#!/usr/bin/env bash
# check_dns.sh — 一键判断"DNS 问题 vs 网络/服务器问题"
# 用法: bash ~/.local/share/dns53/check_dns.sh [域名...]
DNS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DNSQ="$DNS_DIR/dnsq.js"
LOG="$DNS_DIR/logs/dns53.log"
RESOLV="${PREFIX:-/data/data/com.termux/files/usr}/etc/resolv.conf"
HOSTS=(api.deepseek.com api.anthropic.com opencode.ai www.baidu.com)
[ $# -gt 0 ] && HOSTS=("$@")

echo "═══ 诊断 $(date '+%F %T') ═══"

echo "── 模式 ──"
if sudo -n true 2>/dev/null; then
  echo "root: 可用 (dns53 方案)"
  if sudo -n pgrep -f 'dns5[3]\.js' >/dev/null 2>&1; then
    echo "dns53: 运行中"
  else
    echo "dns53: ★ 未运行 (重开终端或: sudo nohup node $DNS_DIR/dns53.js &)"
  fi
  SRV=127.0.0.1
else
  echo "root: 不可用 (dns-bootstrap + proot 方案)"
  SRV=$(awk '/^nameserver/{print $2; exit}' "$RESOLV" 2>/dev/null)
  [ -n "$SRV" ] || SRV=127.0.0.1
  echo "resolv.conf: $(grep -c '^nameserver' "$RESOLV" 2>/dev/null || echo 0) 个 nameserver, 使用 $SRV"
fi
grep 'dns servers:' "$LOG" 2>/dev/null | tail -1 || true

runq() {
  if command -v timeout >/dev/null 2>&1; then timeout 6 node "$DNSQ" "$1" "$SRV"
  else node "$DNSQ" "$1" "$SRV"; fi
}

echo "── 域名解析 (@$SRV) ──"
for h in "${HOSTS[@]}"; do runq "$h" || true; done

echo "── HTTPS 连通性 ──"
for u in https://api.deepseek.com/v1 https://api.anthropic.com/v1 https://opencode.ai https://www.baidu.com; do
  printf "  %s → " "$u"
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" --max-time 8 "$u" || echo "★ 超时/失败"
done

echo "── 最近 12 条 dns53 日志 ──"
tail -12 "$LOG" 2>/dev/null || echo "(无日志文件)"
