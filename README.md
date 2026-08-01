# codex-termux

在 Termux (Android ARM64) 上一键安装**官方** Codex CLI 最新版。

> 不用社区适配包（停更/假升级循环），直接用 OpenAI 官方 musl 静态二进制，
> 只是手动绕过 npm 的 `os: linux` 平台检查。

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
| 安装 Codex | `npm install -g @openai/codex@latest` + 手动解压 `-linux-arm64` tarball 到 vendor |
| 生成 wrapper | `~/.local/bin/codex`：固定 `version.json` 防假升级循环、注入证书、`codex update` 完整升级流程 |
| 验证 | `codex --version` |

## 使用

```bash
codex                     # 启动
codex update              # 更新到最新版
bash <(curl -fsSL …/install.sh)              # 重跑即更新（幂等）
bash <(curl -fsSL …/install.sh) --uninstall  # 卸载
```

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
