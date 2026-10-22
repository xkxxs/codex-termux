#!/usr/bin/env node
// dns-bootstrap — 无 root 环境下的 DNS 自动校验器
// 背景: musl 程序 (codex/opencode) 解析器读不到 /etc/resolv.conf (Android 没有)。
//       有 root 时 dns53.js 监听 127.0.0.1:53 转发解析; 无 root 绑不了特权端口,
//       只能让 musl 直接查 resolv.conf 里的公网 DNS。
//       本脚本解决后者: 实际探测当前网络 → 逐个实测公网 DNS 应答质量
//       (SERVFAIL/空应答/CNAME-only 全判废) → 只把"实测通过"的写进 resolv.conf,
//       再交给 proot 绑定。网络被拦截时给出明确报错, 不再静默卡 5 秒。
// 用法:
//   node dns-bootstrap.js            # 单次校验并重写 resolv.conf (wrapper 启动前用)
//   node dns-bootstrap.js --daemon   # 常驻: 每 60s 重测重写 (开机/打开终端时拉起)
const dgram = require('dgram');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const PUBLIC_DNS = ['223.5.5.5', '119.29.29.29', '114.114.114.114', '2400:3200::1', '2402:4e00::'];
// 测速用域名: 主测 API 域名; 若主域名本身被网络过滤, 回退测国内域名判断网络是否可用
const PROBE_DOMAINS = ['api.deepseek.com', 'www.baidu.com'];
const TIMEOUT_MS = 2500;
const RESOLV = process.env.DNS_RESOLV_CONF ||
  `${process.env.PREFIX || '/data/data/com.termux/files/usr'}/etc/resolv.conf`;
const scriptDir = (() => {
  try { return path.dirname(fs.realpathSync(process.argv[1] || __filename)); }
  catch (_) { return __dirname; }
})();
const DNS_DIR = process.env.DNS53_DIR || scriptDir;
const LOG = process.env.DNS_BOOTSTRAP_LOG || `${DNS_DIR}/logs/dns-bootstrap.log`;
const log = (m) => {
  try {
    fs.mkdirSync(path.dirname(LOG), { recursive: true });
    fs.appendFileSync(LOG, `${new Date().toISOString()} ${m}\n`);
  } catch (_) {}
};

// 探测手机当前网络 DNS (与 dns53 同一套逻辑, 无 root 也能跑 dumpsys)
function discoverPhoneDns() {
  const servers = [];
  // 首选 bionic/netd 的当前服务器: 无子进程、无阻塞 (getprop/dumpsys 会卡 3-5s)。
  try {
    for (const ip of require('dns').getServers()) {
      if (ip && !ip.includes(':')) servers.push(ip);
    }
  } catch (_) {}
  if (servers.length) {
    return [...new Set(servers)].filter((ip) => ip !== '127.0.0.1' && ip !== '0.0.0.0');
  }
  try {
    const props = execFileSync('/system/bin/getprop', [], { encoding: 'utf8', timeout: 3000 });
    for (const line of props.split('\n')) {
      const m = line.match(/^\[net\.\S+\.dns\d+\]:\s*\[([0-9.]+)\]/);
      if (m) servers.push(m[1]);
    }
  } catch (_) {}
  if (servers.length === 0) {
    try {
      const out = execFileSync('/system/bin/dumpsys', ['connectivity'], { encoding: 'utf8', timeout: 5000 });
      const blocks = out.split('NetworkAgentInfo{').slice(1);
      const scored = [];
      for (const b of blocks) {
        const dm = b.match(/DnsAddresses:\s*\[([^\]]*)\]/);
        if (!dm) continue;
        const ips = [];
        let hit;
        const re = /(\d{1,3}(?:\.\d{1,3}){3})/g;
        while ((hit = re.exec(dm[1]))) ips.push(hit[1]);
        if (!ips.length) continue;
        const score = (b.includes('TRANSPORT_PRIMARY') ? 0 : 1) + (b.includes('INTERNET') && b.includes('VALIDATED') ? 0 : 2);
        scored.push([score, ips]);
      }
      scored.sort((a, b) => a[0] - b[0]);
      for (const [, ips] of scored) servers.push(...ips);
    } catch (_) {}
  }
  return [...new Set(servers)].filter((ip) => ip !== '127.0.0.1' && ip !== '0.0.0.0');
}

// DNS 查询 (UDP 53, 非特权端口即可发起)
function queryDNS(server, host, timeout = TIMEOUT_MS) {
  return new Promise((resolve) => {
    const sock = dgram.createSocket(server.includes(':') ? 'udp6' : 'udp4');
    const id = Buffer.from([Math.floor(Math.random() * 256), Math.floor(Math.random() * 256)]);
    const q = Buffer.alloc(12 + 2 + host.length + 4);
    id.copy(q, 0);
    q[2] = 0x01; // RD (flags 低字节)
    q[5] = 1;    // QDCOUNT
    let off = 12;
    for (const part of host.split('.')) { q[off++] = part.length; q.write(part, off); off += part.length; }
    q[off++] = 0; q[off++] = 0; q[off++] = 1; q[off++] = 0; q[off++] = 1; // A IN
    const t0 = Date.now();
    const timer = setTimeout(() => { try { sock.close(); } catch (_) {} resolve({ ok: false, reason: 'timeout', ms: Date.now() - t0 }); }, timeout);
    sock.on('message', (resp) => {
      clearTimeout(timer);
      resolve({ ok: !badAnswer(resp), ms: Date.now() - t0, raw: resp });
      try { sock.close(); } catch (_) {}
    });
    sock.on('error', () => { clearTimeout(timer); try { sock.close(); } catch (_) {} resolve({ ok: false, reason: 'error', ms: Date.now() - t0 }); });
    sock.send(q, 53, server);
  });
}

// 应答校验: 返回 true = 应答有问题 (与 dns53 的 isBadResponse 同套标准)
// 坏应答: 报文过短 / SERVFAIL / rcode=0 无答案 / 查 A 却只回 CNAME 不附地址 (ISP 过滤)
function badAnswer(resp) {
  if (resp.length < 12) return true;
  const rcode = resp.readUInt16BE(2) & 0x0f;
  if (rcode === 2) return true;
  if (rcode !== 0 && rcode !== 3) return true; // 只放行 NOERROR / NXDOMAIN
  const qd = resp.readUInt16BE(4);
  const an = resp.readUInt16BE(6);
  if (an === 0) return rcode === 0; // NOERROR 无答案 = 被过滤; NXDOMAIN 合法
  let off = 12;
  const skipName = (p) => {
    let hops = 0;
    while (off < p.length && p[off] !== 0) {
      if ((p[off] & 0xc0) === 0xc0) { off += 2; return; }
      off += p[off] + 1;
      if (++hops > 32) break;
    }
    off++;
  };
  for (let i = 0; i < qd && off < resp.length; i++) { skipName(resp); off += 4; }
  for (let i = 0; i < an && off + 10 <= resp.length; i++) {
    skipName(resp);
    const type = resp.readUInt16BE(off);
    const len = resp.readUInt16BE(off + 8);
    off += 10 + len;
    if (type === 1 || type === 28) return false; // 有 A/AAAA 记录
  }
  return true; // 只有 CNAME/NS 等 → 过滤特征
}

// 对单个服务器实测: 主域名失败再试备域名, 任一通过即为可用
async function probe(server) {
  for (const host of PROBE_DOMAINS) {
    const r = await queryDNS(server, host);
    if (r.ok) return { ip: server, ms: r.ms, host, ok: true };
  }
  return { ip: server, ms: Infinity, ok: false };
}

async function runOnce() {
  const phone = discoverPhoneDns();
  const candidates = [...phone, ...PUBLIC_DNS];
  const uniq = [];
  for (const ip of candidates) if (!uniq.includes(ip)) uniq.push(ip);
  if (uniq.length === 0) uniq.push(...PUBLIC_DNS);

  const results = await Promise.all(uniq.map((ip) => probe(ip)));
  const good = results.filter((r) => r.ok).sort((a, b) => a.ms - b.ms);

  for (const r of results) {
    log(`probe ${r.ip}: ${r.ok ? `OK ${r.ms}ms via ${r.host}` : 'FAILED'}`);
  }

  const comment = [];
  if (phone.length) comment.push(`# phone dns: ${phone.join(', ')}`);
  const top = good.slice(0, 3);
  const body = top.length
    ? top.map((r) => `nameserver ${r.ip}`).join('\n') + '\n'
    : 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 2400:3200::1\nnameserver 2402:4e00::\n';

  fs.mkdirSync(path.dirname(RESOLV), { recursive: true });
  fs.writeFileSync(RESOLV, `${comment.join('\n')}\n# auto-written by dns-bootstrap.js @ ${new Date().toISOString()}\n${body}`);
  log(`resolv.conf updated: ${top.map((r) => r.ip).join(', ') || 'NONE (fallback public)'}`);

  return good.length;
}

async function main() {
  const daemon = process.argv.includes('--daemon');
  const doOnce = async () => {
    try {
      const n = await runOnce();
      if (n === 0) log('ALL upstreams failed — network DNS likely blocked');
    } catch (e) {
      log(`error: ${e.message}`);
      process.exitCode = 1;
    }
  };
  if (daemon) {
    await doOnce();
    log('daemon started (poll every 60s)');
    setInterval(() => { doOnce(); }, 60000);
  } else {
    await doOnce();
  }
}

main();
