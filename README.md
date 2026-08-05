# codex-termux

在 Termux (Android ARM64) 上一键安装**官方** Codex CLI 最新版，**无需 proot、无需安装 Ubuntu 等完整 Linux 系统**。

> 直接运行 OpenAI 官方 musl 静态二进制（逐字节原样，零修改），
> 只是手动绕过 npm 的 `os: linux` 平台检查。不用社区适配包、不用虚拟机。

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

## 一行命令安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/codex-termux/main/install.sh)
```

## 脚本做了什么

| 步骤 | 说明 |
|---|---|
| 环境检查 | 仅支持 Termux + aarch64 |
| 依赖安装 | `pkg install nodejs-lts patchelf`（已装则跳过） |
| 证书修复 | `SSL_CERT_FILE` 写入 `~/.bashrc`（musl 二进制不认识 Android CA 路径，否则 API 请求报 `stream disconnected`） |
| **DNS 修复** | `dns53.js` 本地 DNS 转发器 + `.bashrc` 常驻。**Android 没有 `/etc/resolv.conf`**，musl 解析器回退 `127.0.0.1:53`（无人监听）→ 每次请求卡满 5s 超时，报 `error sending request`。转发器把查询转到阿里/腾讯/电信 DNS |
| 安装 Codex | `npm install -g @openai/codex@latest` + 手动解压 `-linux-arm64` tarball 到 vendor |
| 生成 wrapper | `~/.local/bin/codex`：固定 `version.json` 防假升级循环、注入证书、自动拉起 dns53、`codex update` 完整升级流程 |
| 验证 | `codex --version` |

## 使用

```bash
codex                     # 启动
codex update              # 更新到最新版
bash <(curl -fsSL …/install.sh)              # 重跑即更新（幂等）
bash <(curl -fsSL …/install.sh) --uninstall  # 卸载
```

## 常见问题

**报 `error sending request for url (...)`？** 两种原因，症状几乎相同，本脚本都已自动处理：

| 原因 | 特征 | 处理 |
|---|---|---|
| DNS 卡死 | 每次请求**恰好卡 5 秒**后失败（重试 5 次共 ~36s） | 本脚本已装 dns53 转发器并写入 `.bashrc` 常驻。**打开新终端即生效** |
| 证书缺失 | curl 正常但 codex 失败 | 本脚本已设置 `SSL_CERT_FILE` |

dns53 需要 root 绑定特权端口 53，要求手机已 root 且 Termux 的 `sudo` 可用（脚本会自动 `pkg install sudo`）。没有 sudo 的话，可手动启动：`sudo node ~/.local/bin/dns53.js`。

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
| 启动提示升级且无限循环 | `version.json` 的版本号与本地二进制不一致 | wrapper 已自动固定；不要用社区适配包 |

## 许可证

MIT
