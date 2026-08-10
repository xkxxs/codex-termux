#!/usr/bin/env node
// dnsq.js — 经 127.0.0.1:53 (dns53 转发链) 查询域名 A 记录
// 用法: node dnsq.js <host>
const { Resolver } = require('dns').promises;
const host = process.argv[2];
if (!host) { console.error('usage: node dnsq.js <host>'); process.exit(2); }
const r = new Resolver({ servers: ['127.0.0.1'], timeout: 3000, retries: 0 });
const t0 = Date.now();
r.resolve4(host).then((ips) => {
  console.log(`  ${host} → OK IPs=[${ips.join(',')}] (${Date.now() - t0}ms)`);
  process.exit(0);
}).catch((e) => {
  console.log(`  ${host} → ★ ${e.code || 'ERR'} (${Date.now() - t0}ms)`);
  process.exit(1);
});