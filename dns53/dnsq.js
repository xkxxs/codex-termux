#!/usr/bin/env node
// dnsq.js — 用原始 UDP 查询域名 A 记录
// 用法: node dnsq.js <host> [dns-server]
//   默认查 127.0.0.1:53 (dns53 转发器); 无 root 方案下传 resolv.conf 的 nameserver
//
// 注意: 不能用 require('dns').Resolver({servers}) —— 在 Termux (bionic) 上
// 它可能忽略自定义 server, 一律交给 netd, 导致 "没有监听也能解析成功" 的假象。
const dgram = require('dgram');
const host = process.argv[2];
const server = process.argv[3] || '127.0.0.1';
if (!host) {
  console.error('usage: node dnsq.js <host> [server]');
  process.exit(2);
}

const t0 = Date.now();
const id = (Math.random() * 65536) | 0;

function buildQuery() {
  const labels = host.split('.').filter(Boolean);
  const size = 12 + labels.reduce((n, l) => n + 1 + l.length, 0) + 5;
  const b = Buffer.alloc(size);
  b.writeUInt16BE(id, 0);
  b.writeUInt16BE(0x0100, 2); // RD
  b.writeUInt16BE(1, 4); // QDCOUNT
  let o = 12;
  for (const l of labels) {
    b[o++] = l.length;
    b.write(l, o, 'ascii');
    o += l.length;
  }
  b[o++] = 0;
  b.writeUInt16BE(1, o); // A
  b.writeUInt16BE(1, o + 2); // IN
  return b;
}

function skipName(buf, o) {
  while (o < buf.length) {
    const l = buf[o];
    if (l === 0) return o + 1;
    if ((l & 0xc0) === 0xc0) return o + 2;
    o += l + 1;
  }
  return o;
}

function done(line, code) {
  console.log(line);
  try { sock.close(); } catch (_) {}
  process.exit(code);
}

const sock = dgram.createSocket(server.includes(':') ? 'udp6' : 'udp4');
const timer = setTimeout(() => done(`  ${host} @${server} → ★ TIMEOUT (${Date.now() - t0}ms)`, 1), 3000);

sock.on('error', (e) => done(`  ${host} @${server} → ★ ${e.code || e.message} (${Date.now() - t0}ms)`, 1));
sock.on('message', (resp) => {
  clearTimeout(timer);
  const ms = Date.now() - t0;
  if (resp.length < 12 || resp.readUInt16BE(0) !== id) {
    return done(`  ${host} @${server} → ★ 响应不匹配 (${ms}ms)`, 1);
  }
  const rcode = resp.readUInt16BE(2) & 0xf;
  const ancount = resp.readUInt16BE(6);
  const ips = [];
  try {
    let o = skipName(resp, 12) + 4; // 跳过问题 (name + type + class)
    for (let i = 0; i < ancount && o + 10 <= resp.length; i++) {
      o = skipName(resp, o);
      if (o + 10 > resp.length) break;
      const type = resp.readUInt16BE(o);
      const rdlen = resp.readUInt16BE(o + 8);
      o += 10;
      if (type === 1 && rdlen === 4) ips.push(`${resp[o]}.${resp[o + 1]}.${resp[o + 2]}.${resp[o + 3]}`);
      o += rdlen;
    }
  } catch (_) {}
  if (ips.length) return done(`  ${host} @${server} → OK IPs=[${ips.join(',')}] (${ms}ms)`, 0);
  const why = rcode === 3 ? 'NXDOMAIN' : rcode !== 0 ? `rcode=${rcode}` : 'NO-A';
  done(`  ${host} @${server} → ★ ${why} (${ms}ms)`, 1);
});

const q = buildQuery();
sock.send(q, 0, q.length, 53, server, (err) => {
  if (err) done(`  ${host} @${server} → ★ ${err.code || err.message} (${Date.now() - t0}ms)`, 1);
});
