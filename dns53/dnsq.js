#!/usr/bin/env node
// dnsq.js — 查询域名 A 记录
// 用法: node dnsq.js <host> [dns-server]
//   默认查 127.0.0.1:53 (dns53 转发器); 无 root 方案下传 resolv.conf 的 nameserver
const { Resolver } = require('dns').promises;
const host = process.argv[2];
const server = process.argv[3] || '127.0.0.1';
if (!host) { console.error('usage: node dnsq.js <host> [server]'); process.exit(2); }
const r = new Resolver({ servers: [server], timeout: 3000, retries: 0 });
const t0 = Date.now();
r.resolve4(host).then((ips) => {
  console.log(`  ${host} @${server} → OK IPs=[${ips.join(',')}] (${Date.now() - t0}ms)`);
  process.exit(0);
}).catch((e) => {
  console.log(`  ${host} @${server} → ★ ${e.code || 'ERR'} (${Date.now() - t0}ms)`);
  process.exit(1);
});
