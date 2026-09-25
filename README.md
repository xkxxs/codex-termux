# codex-termux

在 Termux (Android ARM64) 上一键安装**官方** Codex CLI 最新版，**无需 proot、无需安装 Ubuntu 等完整 Linux 系统**。

> 直接运行 OpenAI 官方 musl 静态二进制（逐字节原样，零修改），
> 只是手动绕过 npm 的 `os: linux` 平台检查。不用社区适配包、不用虚拟机。

## 前置要求

- Termux + aarch64 (ARM64)
- 以下二选一（脚本自动检测，无需手动选择）：
  - **有 root（Magisk 已授权 Termux）**：推荐。原生直跑 + dns53 转发器，性能最佳
  - **无 root**：自动改用 dns-bootstrap 校验器 + proot 兜底，性能略有损耗

> 为什么 DNS 需要特殊处理：Codex 是 musl 静态二进制，解析器读不到 Android 的
> `/etc/resolv.conf`（该文件不存在），会回退 `127.0.0.1:53`。有 root 时由 dns53
> 监听该端口，并**自动探测手机当前 DNS（运营商下发）优先转发**，公共 DNS 兜底；没有 root 时无法绑定特权端口 53，改用 `dns-bootstrap.js`
> 实测校验器：逐个探测候选 DNS 的应答质量，只把真实可用的写进 `resolv.conf`，再交给 proot 绑定给 musl 读取。
> dns53 / dns-bootstrap 都会**校验上游应答**：SERVFAIL / 无答案 / 只回 CNAME 不给 A 记录（国内 ISP 常见过滤手法）都会自动跳过换下一个上游，连续异常的上游自动降级（dns-bootstrap 每 60 秒重测重写）——在外切换 WiFi/基站也不用管。
> dns53 的最终防线是 **netd 兜底**：当所有 UDP 上游都被当前网络拦截（运营商封锁 UDP 53 时常见）时，自动改用系统级解析（bionic → netd）应答，保证 API 域名始终可解析。
> dns53 会**屏蔽 AAAA 应答**（`DNS53_DISABLE_AAAA=0` 可关闭）：家庭宽带 IPv6 常见"黑洞"（光猫拿到 240e 前缀但出站无路由，光猫诊断页 ping6 公网 100% 丢包），Go/musl 客户端拿到 AAAA 后会优先尝试 IPv6 连接并卡死超时——屏蔽后客户端自动纯走 IPv4，规避 IPv6 黑洞。
> 诊断工具：`bash ~/.check_dns.sh` 一键判断"DNS 问题 vs 网络问题 vs 服务器问题"（dns53 状态 + 各域名解析 + HTTPS 连通性 + 最近日志）；`node ~/.local/bin/dnsq.js <host>` 单点查询（可自定义域名）。
> 注意：无 root 时若网络禁止普通 App 直连公网 DNS 53 端口，dns-bootstrap 会明确报错提示（不再静默卡 5 秒），此时仍需 root 方案。

## 为什么选这个方案？

**在其他 Android 上跑 codex，主流路线是 proot-distro 装个 Ubuntu**——完整系统环境，听起来稳妥，但代价巨大：

| 对比项 | **本方案（原生直跑）** | proot + Ubuntu | 社区 fork 编译的 npm 包 | 二进制打补丁脚本 |
|---|---|---|---|---|
| 系统环境 | ✅ 只需 Termux 本体 | ❌ 额外装 ~5GB Ubuntu | ✅ 只需 Termux | ✅ 只需 Termux |
| 运行方式 | ✅ 官方二进制**零修改** | proot 转译，性能损耗 ~30% | 非官方源码 fork 重编译 | 需对二进制打补丁，更新后重打 |
| 上游同步 | ✅ 官方发布即用，永远最新 | ✅ 但 **codex ≥0.43 直接崩溃**（[#6757](https://github.com/openai/codex/issues/6757)：`prctl(PR_SET_DUMPABLE, 0) failed`，只能钉 0.42） | ⚠️ 慢半拍，维护者停更即死路 | ⚠️ 上游每更一次都要重 patch |
| 存储占用 | ✅ 几十 MB | ❌ ~5GB+ | ✅ | ✅ |
| 稳定性 | ✅ 官方二进制 + wrapper 防假升级 | ❌ proot 边界情况多 | ⚠️ 依赖第三方维护 | ⚠️ 依赖 patch 脚本维护 |

**一句话**：手机上跑 codex 不需要一台"完整的 Ubuntu"——codex 官方本来就发布 musl 静态二进制，把它从 npm 里"请"出来直接跑就行。本方案是唯一一个**官方二进制 + 原生直跑 + 零修改**的组合。

> 无 root 时脚本会自动用 proot 做 DNS 兜底（仅 syscall 转译，仍然直跑官方二进制、不装 Ubuntu），性能损耗远小于 proot-distro 整机方案。

## 一行命令安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/codex-termux/main/install.sh)
```

国内网络拉不动 `raw.githubusercontent.com` 时,改用镜像:

```bash
# jsDelivr CDN
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/xkxxs/codex-termux@main/install.sh)

# 或 gh-proxy
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/xkxxs/codex-termux/main/install.sh)
```

> 有 root / 无 root 都能装：有 root 走 dns53 原生直跑，无 root 自动用 proot 兜底（见[前置要求](#前置要求)）。

## 脚本做了什么

| 步骤 | 说明 |
|---|---|
| 环境检查 | 仅支持 Termux + aarch64 |
| 镜像源适配 | 对官方源 + 国内主流镜像（阿里/清华/中科大/腾讯/华为云）**逐个测速**，自动切换最快者（幂等，已最快则不动） |
| 全量升级 | 换好源后 `pkg upgrade -y` 把所有软件包升到最新 |
| 依赖安装 | `pkg install nodejs-lts patchelf sudo/proot`：有 root 装 sudo，无 root 自动装 proot（已装则跳过） |
| 证书修复 | `SSL_CERT_FILE` 写入 `~/.bashrc`（musl 二进制不认识 Android CA 路径，否则 API 请求报 `stream disconnected`） |
| **DNS 修复** | 有 root：`dns53.js` 本地 DNS 转发器 + `.bashrc` 常驻（**自动优先手机当前 DNS，IPv4/IPv6 独立探测、缺失时公共 DNS 兜底；AAAA 默认屏蔽防境外 IPv6 卡死，境内 IPv6 可用时设 `DNS53_DISABLE_AAAA=0` 放开**）；无 root：`dns-bootstrap.js` 启动时实测校验候选 DNS 后写入 `resolv.conf` + proot 绑定。**Android 没有 `/etc/resolv.conf`**，musl 解析器回退 `127.0.0.1:53`（无人监听）→ 每次请求卡满 5s 超时，报 `error sending request`。两套方案都会校验应答质量并跳过被过滤的上游 |
| 安装 Codex | `npm install -g @openai/codex@latest` + 手动解压 `-linux-arm64` tarball 到 vendor |
| 生成 wrapper | `~/.local/bin/codex`：**启动前自动检查最新版，非最新自动更新再启动**（可 `CODEX_NO_AUTO_UPDATE=1` 跳过）、固定 `version.json` 防假升级循环、注入证书、自动拉起 dns53、`codex update` 手动强制升级流程 |
| 验证 | `codex --version` |

## 使用

```bash
codex                     # 启动：先检查最新版，非最新自动更新再启动（已最新直接启动）
codex update              # 手动强制更新到最新版
bash ~/.check_dns.sh      # DNS 一键诊断（解析 + 连通性 + 日志，见"常见问题"）
node ~/.local/bin/dnsq.js api.deepseek.com   # 单点解析测试
bash <(curl -fsSL …/install.sh)              # 重跑即更新（幂等）
bash <(curl -fsSL …/install.sh) --uninstall  # 卸载
```

> **自动更新说明**：每次执行 `codex` 时，wrapper 会先查一次 npm 上的最新版
> （10 秒内快速失败，网络差时静默跳过），与本地版本比较（`sort -V`）：
> - 有新版 → 自动执行完整更新（npm 主包 → 重新解压 linux-arm64 二进制到 vendor → 固定 version.json），完成后继续启动
> - 更新失败（如网络中断）→ 不阻塞，直接用现有版本启动
> - 已是最新 → 直接启动，零额外等待
> - 临时跳过检查：`CODEX_NO_AUTO_UPDATE=1 codex ...`

## 常见问题

**报 `error sending request for url (...)`？** 两种原因，症状几乎相同，本脚本都已自动处理：

| 原因 | 特征 | 处理 |
|---|---|---|
| DNS 卡死 | 每次请求**恰好卡 5 秒**后失败（重试 5 次共 ~36s） | 有 root：已装 dns53 转发器；无 root：已装 dns-bootstrap 校验器，均写入 `.bashrc` 常驻。**打开新终端即生效** |
| 证书缺失 | curl 正常但 codex 失败 | 本脚本已设置 `SSL_CERT_FILE` |

有 root 时走 dns53 原生方案（需要手机已 root/Magisk 且 Termux 的 `sudo` 可用，脚本自动 `pkg install sudo`）；没有 root 时脚本自动改用 dns-bootstrap + proot 兜底（自动 `pkg install proot`），无需 root 也能正常解析。dns53 会自动探测并优先使用手机当前下发的 DNS（运营商 DNS），IPv4/IPv6 缺失时分别用公共 DNS 兜底；AAAA 默认屏蔽（强制客户端走 IPv4，避免境外 IPv6 卡死），境内 IPv6 可用时可设 `DNS53_DISABLE_AAAA=0` 放开（或 `dns53-aaaa off` 一键切换）。dns-bootstrap 每次启动前实测公网候选 DNS 应答质量（SERVFAIL/空应答/CNAME-only 判废），只把可用的写进 `resolv.conf`，每次无 root 启动前实测重写，切 WiFi/基站后下次启动自动跟随；若当前网络禁止直连公网 DNS 53 端口，它会明确报错而不是静默卡 5 秒。

**API 时好时坏 / 切换网络后连不上？** 先跑 `bash ~/.check_dns.sh` 三秒定位：

| 结果 | 结论 |
|---|---|
| 解析 OK + HTTPS 有响应（401/404/200） | 网络、DNS、服务器全正常 → 是旧进程持有切网络前的 DNS 缓存，重开 codex/opencode |
| 解析 ★ 失败/TIMEOUT | DNS 链挂了 → 看 `~/.codex/dns53.log` 尾部 + 重开终端（自动拉起 dns53） |
| 解析 OK 但 HTTPS ★ 超时 | 出站被网络挡了（切 WiFi/基站，或运营商干扰特定站点） |
| HTTPS 5xx/∞ | 服务器侧问题 |

## 配置模型（DeepSeek 等）

本脚本**只负责安装**。模型配置请参考官方文档：

**DeepSeek × Codex**：https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/codex

先运行一次 `codex`（生成 `~/.codex` 目录），然后任选：

```bash
# 方式一：DeepSeek 官方一键配置脚本（推荐）
bash <(curl -fsSL https://cdn.deepseek.com/api-docs/codex-deepseek-setup.sh)

# 方式二：手动编辑 ~/.codex/config.toml
```

要点：

- `model_catalog_json` 必须用**绝对路径**（不要用 `~`）
- `base_url = "https://api.deepseek.com/"`，`wire_api = "responses"`
- 新版 Codex (≥0.144) 的推理档位支持 `max`，旧版 (≤0.121) 只到 `xhigh`

## 原理

- 官方 `@openai/codex` 的 `aarch64-unknown-linux-musl` 二进制是 **musl 静态链接**，不依赖 glibc，可直接跑在 Android Bionic 上
- OpenAI 官方 JS 入口（`codex.js`）已显式支持 `android` 平台映射到 linux-musl
- 唯一障碍是 npm 包元数据 `os: linux`，脚本用 `npm pack` + `tar xzf` 绕过

## 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/codex-termux/main/install.sh) --uninstall
# 如需删除配置: rm -rf ~/.codex
```

## 常见问题

| 症状 | 原因 | 解决 |
|---|---|---|
| `stream disconnected before completion: error sending request` | musl 二进制找不到 CA 证书 | 脚本已自动处理；手动: `export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem` |
| `unknown variant 'max'` | models.json 用了新版档位，Codex ≤0.121 | 把 `max` 改成 `xhigh`，或升级 Codex |
| 启动提示升级且无限循环 | `version.json` 的版本号与本地二进制不一致 | wrapper 已自动固定且**启动前自动更新**，不会出现假升级；不要用社区适配包 |
| 没有 root | 无法绑定 53 端口，dns53 方案不可用 | 脚本自动改用 dns-bootstrap 实测校验 + proot 兜底（自动 `pkg install proot`），无需 root；网络禁止公网 53 时给出明确报错 |

## 许可证

MIT
