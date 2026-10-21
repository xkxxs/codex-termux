#!/usr/bin/env node
// dns53 — 本地 DNS 转发器 (127.0.0.1:53)
// 背景: musl 程序 (codex/opencode) 解析器读不到 /etc/resolv.conf (Android 没有),
//       回退到默认 127.0.0.1:53, 而手机上没人监听该端口 → DNS 卡死 → 5s 超时。
// 方案: 在 127.0.0.1:53 上监听 UDP, 优先转发到手机当前使用的 DNS (延迟更低),
//       再依次回退到公共 DNS (IPv4: 阿里/腾讯/114; IPv6: 阿里/CNNIC/移动), 回传响应。
// 运行: sudo node dns53.js  (53 是特权端口)
const dgram = require('dgram');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// 公共兜底 DNS (手机 DNS 探测缺失时使用): IPv4 与 IPv6 各自独立
const PUBLIC_DNS4 = [
  ['223.5.5.5', 53],      // 阿里
  ['119.29.29.29', 53],   // 腾讯
  ['114.114.114.114', 53],// 114
];
const PUBLIC_DNS6 = [
  ['2400:3200::1', 53],   // 阿里 IPv6
  ['2402:4e00::', 53],    // 腾讯 DNSPod IPv6
  ['2408:8899::8', 53],   // 移动 IPv6
];
const TIMEOUT_MS = 1500;
// AAAA 屏蔽开关 (默认开启): 屏蔽后客户端只走 IPv4,
// 避免境外 IPv6 不可达导致连接卡死 (如 OpenAI 域名)。
// 境内 IPv6 可用时, 可设 DNS53_DISABLE_AAAA=0 关闭屏蔽。
const DISABLE_AAAA = process.env.DNS53_DISABLE_AAAA !== '0';
// 组件目录 = 本脚本所在目录 (与 agent 目录解耦; sudo 下 HOME 不可靠)
const scriptDir = (() => {
  try { return path.dirname(fs.realpathSync(process.argv[1] || __filename)); }
  catch (_) { return __dirname; }
})();
const DNS_DIR = process.env.DNS53_DIR || scriptDir;
const LOG = process.env.DNS53_LOG || `${DNS_DIR}/logs/dns53.log`;
const log = (m) => {
  try {
    fs.mkdirSync(path.dirname(LOG), { recursive: true });
    fs.appendFileSync(LOG, `${new Date().toISOString()} ${m}\n`);
  } catch (_) {}
};
// 日志轮转: 超过 2MB 截掉前半 (调试期高频查询日志会涨)
function rotateLog() {
  try {
    const st = fs.statSync(LOG);
    if (st.size > 2 * 1024 * 1024) {
      const content = fs.readFileSync(LOG, 'utf8');
      fs.writeFileSync(LOG, content.slice(Math.floor(content.length / 2)));
      log('LOG ROTATED');
    }
  } catch (_) {}
}
setInterval(rotateLog, 60000);

let UPSTREAMS = [...PUBLIC_DNS4, ...PUBLIC_DNS6];

// 探测手机当前 DNS: 同时收集 IPv4 与 IPv6 (优先默认网络)
function discoverPhoneDns() {
  const v4 = [];
  const v6 = [];
  try {
    // 老版本 Android: getprop net.*.dnsN
    const props = execFileSync('/system/bin/getprop', [], { encoding: 'utf8', timeout: 3000 });
    for (const line of props.split('\n')) {
      const m = line.match(/^\[net\.\S+\.dns\d+\]:\s*\[([0-9a-fA-F:.]+)\]/);
      if (m) {
        if (m[1].includes(':')) v6.push(m[1]); else v4.push(m[1]);
      }
    }
  } catch (_) {}
  if (v4.length === 0 && v6.length === 0) {
    try {
      // 现代 Android: dumpsys connectivity 的 DnsAddresses。
      // 优先默认网络 (TRANSPORT_PRIMARY), 再收集所有 INTERNET+VALIDATED 网络,
      // 避免个别机型/网络下主网络块 DnsAddresses 为空时拿不到 DNS。
      const out = execFileSync('/system/bin/dumpsys', ['connectivity'], { encoding: 'utf8', timeout: 5000 });
      const blocks = out.split('NetworkAgentInfo{').slice(1);
      const scored = [];
      for (const b of blocks) {
        const dm = b.match(/DnsAddresses:\s*\[([^\]]*)\]/);
        if (!dm) continue;
        const a4 = [];
        const a6 = [];
        for (const token of dm[1].split(/[\s,]+/)) {
          const ip = token.replace(/^\//, '');
          if (!ip) continue;
          if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(ip)) a4.push(ip);
          else if (/^[0-9a-fA-F:.]+$/.test(ip) && ip.includes(':')) a6.push(ip);
        }
        if (!a4.length && !a6.length) continue;
        const score = (b.includes('TRANSPORT_PRIMARY') ? 0 : 1) + (b.includes('INTERNET') && b.includes('VALIDATED') ? 0 : 2);
        scored.push([score, a4, a6]);
      }
      scored.sort((a, b) => a[0] - b[0]);
      for (const [, a4, a6] of scored) {
        v4.push(...a4);
        v6.push(...a6);
      }
    } catch (_) {}
  }
  return {
    v4: [...new Set(v4)].filter((ip) => ip !== '127.0.0.1' && ip !== '0.0.0.0'),
    v6: [...new Set(v6)].filter((ip) => ip !== '::1' && ip !== '::'),
  };
}

// 刷新上游: 手机 DNS 在前 (v4/v6 各自), 公共 DNS 兜底 (每分钟一次, 网络切换后自动跟随)
function refreshDns() {
  const phone = discoverPhoneDns();
  if (phone.v4.length === 0 && phone.v6.length === 0) return;
  const now = Date.now();
  for (const [h, t] of DEMOTED) if (now - t > DEMOTE_TTL) DEMOTED.delete(h);
  const merged = [];
  const add = (ip) => {
    if (!merged.some((s) => s[0] === ip)) merged.push([ip, 53]);
  };
  for (const ip of [...phone.v4, ...PUBLIC_DNS4.map((s) => s[0])]) add(ip);
  for (const ip of [...phone.v6, ...PUBLIC_DNS6.map((s) => s[0])]) add(ip);
  // 降级过的主机保持置底, 直到 TTL 到期
  // (否则每分钟的 refreshDns 会按手机顺序重建, 把坏上游又排回第一位)
  if (DEMOTED.size) {
    merged.sort((a, b) => (DEMOTED.has(a[0]) ? 1 : 0) - (DEMOTED.has(b[0]) ? 1 : 0));
  }
  if (JSON.stringify(merged) !== JSON.stringify(UPSTREAMS)) {
    UPSTREAMS = merged;
    log(`dns servers: ${merged.map((s) => s[0]).join(', ')}`);
  }
}

// 连续空应答计数: 记录各上游的连续"被过滤"次数, 达到阈值后降级到底部
const strikes = new Map();
const MAX_STRIKES = 3;
// 已降级的主机 (host -> 时间); refreshDns 重建上游列表时保持置底, TTL 后恢复
const DEMOTED = new Map();
const DEMOTE_TTL = 10 * 60 * 1000;

// 判断应答是否有效: 返回 true = 应答异常, 应换下一个上游。
// 覆盖: 报文过短 / SERVFAIL / A 查询 rcode=0 但答案为空 / A 查询只回 CNAME 没给 A
//       (中国 ISP DNS 常见过滤手法: 剥离 CNAME 链末端的地址记录)。
// 注意: AAAA 查询 (qtype=28) 一律放行 —— 域名没有 IPv6 记录时 NOERROR+0 答案、
//       部分上游对 AAAA 返回 NOTIMP 都是正常现象, 应由客户端自行回退 A 记录。
function isBadResponse(resp, qtype) {
  if (resp.length < 12) return true;
  const flags = resp.readUInt16BE(2);
  const rcode = flags & 0x0f;
  if (rcode === 2) return true; // SERVFAIL
  if (qtype === 28) return false; // AAAA: 空/NOTIMP/CNAME-only 均合法, 不判坏
  if (rcode !== 0 && rcode !== 3) return true; // NOTIMP/REFUSED 等 → 判坏换上游
  const qd = resp.readUInt16BE(4);
  const an = resp.readUInt16BE(6);
  if (an === 0) return true; // A 查询 rcode=0 但无任何答案 = 被过滤
  if (qtype !== 1) return false; // 非 A 查询, 只做基本校验
  // 逐条解析答案区, 看是否含有 A 记录
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
    if (type === 1) return false; // 找到 A 记录, 应答有效
  }
  return true; // A 查询答案区只有 CNAME/NS 等, 没有地址记录
}

// 降级: 移到列表末尾并记录, 刷新时保持置底
function demote(host) {
  DEMOTED.set(host, Date.now());
  const idx = UPSTREAMS.findIndex((s) => s[0] === host);
  if (idx >= 0) {
    const [s] = UPSTREAMS.splice(idx, 1);
    UPSTREAMS.push(s);
  }
  log(`demoted bad upstream ${host}`);
}

// 从查询报文解析 qtype (跳过问题名, 不受 EDNS 附加区影响)
function queryType(msg) {
  if (msg.length < 16) return 0;
  let off = 12;
  let hops = 0;
  while (off < msg.length && msg[off] !== 0) {
    if ((msg[off] & 0xc0) === 0xc0) return 0; // 压缩指针不出现于查询
    off += msg[off] + 1;
    if (++hops > 32) return 0;
  }
  if (off >= msg.length) return 0;
  off++; // root label
  if (off + 4 > msg.length) return 0;
  return (msg[off] << 8) | msg[off + 1];
}

// 从查询报文解析域名 (与 queryType 共用同一套偏移, 保证一致性)
function queryName(msg) {
  if (msg.length < 12) return null;
  let off = 12;
  let name = '';
  while (off < msg.length && msg[off] !== 0) {
    const len = msg[off++];
    if (off + len > msg.length) return null;
    name += (name ? '.' : '') + msg.slice(off, off + len).toString();
    off += len;
  }
  if (off >= msg.length) return null;
  return name;
}

// IPv6 地址字符串 → 16 字节 (处理 :: 简写与 IPv4 内嵌)
function ipv6ToBytes(ip) {
  const buf = Buffer.alloc(16);
  const v4m = ip.match(/(.*):([0-9.]+)$/);
  let head, tail;
  if (v4m && v4m[2].includes('.')) {
    head = v4m[1]; tail = v4m[2].split('.').map(Number);
  } else {
    head = ip; tail = [];
  }
  const [hs, ts] = head.split('::');
  let h = hs ? hs.split(':').filter(Boolean) : [];
  const t = ts ? ts.split(':').filter(Boolean) : [];
  while (h.length + t.length + (tail.length ? 2 : 0) < 8) h.push('0');
  const all = h.concat(t);
  all.forEach((part, i) => { if (part !== undefined) buf.writeUInt16BE(parseInt(part, 16) || 0, i * 2); });
  if (tail.length) {
    tail.forEach((b, i) => { buf.writeUInt8(b, 12 + i); });
  }
  return buf;
}

// 构造 DNS 应答: 复用客户端查询报文, 填上答案
function buildResponse(msg, answers) {
  const qnameLen = msg.length - 12;
  const resp = Buffer.alloc(12 + qnameLen + answers.length * 16);
  msg.copy(resp, 0, 0, 12 + qnameLen);
  resp[2] |= 0x80; // QR
  resp[3] |= 0x80; // RA
  resp[6] = answers.length >> 8; resp[7] = answers.length & 0xff;
  let off = 12 + qnameLen;
  for (const a of answers) {
    resp.writeUInt16BE(0xc00c, off); off += 2; // 指针 → 问题名
    resp.writeUInt16BE(a.type, off); off += 2;
    resp.writeUInt16BE(1, off); off += 2;      // IN
    resp.writeUInt32BE(60, off); off += 4;     // TTL
    if (a.type === 1) {
      resp.writeUInt16BE(4, off); off += 2;
      for (const b of a.ip.split('.').map(Number)) resp.writeUInt8(b, off++);
    } else {
      resp.writeUInt16BE(16, off); off += 2;
      ipv6ToBytes(a.ip).copy(resp, off); off += 16;
    }
  }
  return resp;
}

const netd = require('dns'); // node 内置解析 (走 bionic/netd, 不受 UDP 53 封锁影响)

// 最后兜底: UDP 上游失败时, 用系统解析 (netd) 回答 (onDone 通知调用方)
function netdFallback(msg, rinfo, qtype, onDone, qid) {
  const host = queryName(msg);
  if (!host || (qtype !== 1 && qtype !== 28)) {
    log(`netd fallback q${qid}: unsupported query (qtype=${qtype})`);
    if (onDone) onDone();
    return;
  }
  const family = qtype === 1 ? 4 : 6;
  const t1 = Date.now();
  netd.lookup(host, { family, timeout: 5000 }, (err, ip) => {
    // onDone 返回 false 表示已有上游先应答, 这里不能再发第二份
    if (onDone && onDone() === false) return;
    if (err) {
      // NXDOMAIN 或解析失败: 回 rcode=3 (合法应答, 客户端正常处理)
      const resp = Buffer.alloc(12 + msg.length - 12);
      msg.copy(resp, 0, 0, msg.length);
      resp[2] |= 0x80; // QR
      resp[3] = (resp[3] & 0x70) | 0x80 | 0x03; // RA + rcode=NXDOMAIN
      server.send(resp, rinfo.port, rinfo.address);
      log(`netd fallback q${qid} ${host} → NXDOMAIN/err ${err.code || err.message} (${Date.now() - t1}ms)`);
      return;
    }
    const resp = buildResponse(msg, [{ type: qtype, ip }]);
    server.send(resp, rinfo.port, rinfo.address);
    log(`netd fallback q${qid} ${host} → ${ip} (${family === 4 ? 'A' : 'AAAA'}) ${Date.now() - t1}ms`);
  });
}

const server = dgram.createSocket('udp4');

server.on('message', (msg, rinfo) => {
  const qtype = queryType(msg);
  const qid = msg.readUInt16BE(0).toString(16);
  const qhost = queryName(msg) || '?';
  const t0 = Date.now();
  log(`>> q${qid} ${qhost} type=${qtype === 1 ? 'A' : qtype === 28 ? 'AAAA' : qtype} from ${rinfo.address}`);
  // AAAA 屏蔽: 直接回 NOERROR+0 答案 (合法"无 IPv6 记录"), 不走上游
  if (qtype === 28 && DISABLE_AAAA) {
    const resp = Buffer.alloc(msg.length);
    msg.copy(resp, 0, 0, msg.length);
    resp[2] |= 0x80; // QR
    resp[3] |= 0x80; // RA
    server.send(resp, rinfo.port, rinfo.address);
    log(`<< q${qid} ${qhost} AAAA suppressed (IPv6 disabled) ${Date.now() - t0}ms`);
    return;
  }
  let done = false;
  let netdStarted = false;
  // 任一上游失败 → 并行启动 netd 兜底 (先回先赢; onDone 返回 false = 已有应答, 不再发)
  const startNetd = () => {
    if (netdStarted || done) return;
    netdStarted = true;
    log(`>> q${qid} netd fallback started (${Date.now() - t0}ms in)`);
    netdFallback(msg, rinfo, qtype, () => {
      if (done) return false;
      done = true;
      return true;
    }, qid);
  };
  // 快照本次查询的上游列表: demote/refreshDns 会改 UPSTREAMS, 迭代中不能用活引用
  const upstreams = UPSTREAMS.slice();
  let i = 0;
  // 依次尝试上游; 失败的那个计 strike (超时也算), 达到阈值降级,
  // 然后继续试下一个上游 —— 同时并行启动 netd 兜底, 避免串行等待过长。
  const tryNext = () => {
    if (done) return;
    if (i >= upstreams.length) { startNetd(); return; }
    const [host, port] = upstreams[i++];
    const t1 = Date.now();
    const tag = `q${qid}->${host}`;
    const sock = dgram.createSocket(host.includes(':') ? 'udp6' : 'udp4');
    let doneHere = false;
    const finish = (fn) => {
      if (doneHere) return;
      doneHere = true;
      clearTimeout(timer);
      sock.close();
      fn();
    };
    const fail = (why) => {
      if (done) { finish(() => {}); return; }  // 其他上游/netd 已应答, 别再计 strike
      finish(() => {
        const n = (strikes.get(host) || 0) + 1;
        strikes.set(host, n);
        if (n >= MAX_STRIKES) { strikes.delete(host); demote(host); }
        log(`${why} ${tag} (${Date.now() - t1}ms, strike ${n}/${MAX_STRIKES})`);
        startNetd();
        tryNext();
      });
    };
    const timer = setTimeout(() => fail('timeout'), TIMEOUT_MS);
    sock.on('message', (resp) => {
      if (doneHere) return;
      if (done) { finish(() => {}); return; }  // 防双发: 已有人先回过了
      if (isBadResponse(resp, qtype)) { fail('bad response'); return; }
      finish(() => {
        if (strikes.has(host)) strikes.delete(host);
        done = true;
        server.send(resp, rinfo.port, rinfo.address);
        log(`<< q${qid} ${qhost} OK via ${host} (${Date.now() - t1}ms, total ${Date.now() - t0}ms)`);
      });
    });
    sock.on('error', (e) => fail(`error: ${e.message}`));
    sock.send(msg, port, host, (e) => {
      if (e) fail(`send error: ${e.message}`);
    });
  };
  tryNext();
});

server.on('error', (e) => {
  log(`server error: ${e.message}`);
  if (process.stderr.isTTY) console.error(`dns53 server error: ${e.message}`);
  // 端口被占等致命错误: 占着没意义, 直接退出 (避免僵尸进程)
  process.exit(1);
});
server.bind(53, '127.0.0.1', () => {
  refreshDns();
  log('dns53 listening on 127.0.0.1:53');
  if (process.stdout.isTTY) console.log('dns53 listening on 127.0.0.1:53');
  setInterval(refreshDns, 60000);
});

