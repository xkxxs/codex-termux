#!/usr/bin/env bash
# check_dns.sh — 一键判断"DNS 问题 vs 网络/服务器问题"
# 用法: bash ~/.check_dns.sh [域名...]
DNSQ=/data/data/com.termux/files/home/.local/bin/dnsq.js
LOG=/data/data/com.termux/files/home/.codex/dns53.log
HOSTS=(api.deepseek.com integrate.api.nvidia.com opencode.ai www.baidu.com)
[ $# -gt 0 ] && HOSTS=("$@")

echo "═══ 诊断 $(date '+%F %T') ═══"

echo "── dns53 状态 ──"
if sudo -n ss -ulnp 2>/dev/null | grep -q "127.0.0.1:53"; then
  echo "运行中"
else
  echo "★ 未运行! 请重开终端或手动: sudo nohup node ~/.local/bin/dns53.js &"
fi
grep 'dns servers:' "$LOG" 2>/dev/null | tail -1 || echo "(无日志)"

echo "── 域名解析 (经 127.0.0.1:53 / dns53 转发) ──"
for h in "${HOSTS[@]}"; do
  timeout 6 node "$DNSQ" "$h" || true
done

echo "── HTTPS 连通性 ──"
for u in https://api.deepseek.com/v1 https://integrate.api.nvidia.com/v1 https://opencode.ai https://www.baidu.com; do
  printf "  %s → " "$u"
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" --max-time 8 "$u" || echo "★ 超时/失败"
done

echo "── 最近 12 条 dns53 日志 ──"
tail -12 "$LOG" 2>/dev/null || echo "无日志文件"