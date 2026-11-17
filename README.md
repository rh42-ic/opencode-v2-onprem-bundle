# opencode v2 内网离线 bundle

为 air-gap 内网环境打包的 [opencode](https://github.com/anomalyco/opencode) v2 离线整合包：
单二进制 + 全部离线依赖，装好即用，运行时不需要任何外网访问。

## 下载

GitHub [Releases](../../releases) —— 每个 opencode 上游版本一个 `bundle-vX.Y.Z` Release：

| 附件 | 说明 |
|---|---|
| `opencode-vX.Y.Z-onprem-bundle-linux-x64.tar.gz` | Linux x64（glibc/AVX2），全量离线验收全绿 |
| `opencode-vX.Y.Z-onprem-bundle-win32-x64.zip` | Windows x64（官方原生二进制；zip 解压友好，发布标注 unverified） |
| `*.sha256` | 对应校验和 |

## 安装（内网目标机）

```bash
# Linux
tar xzf opencode-v*-onprem-bundle-linux-x64.tar.gz
# Windows：解压 opencode-v*-onprem-bundle-win32-x64.zip
cd opencode-v*-onprem-<platform>
sudo ./install.sh                 # 默认装到 /opt/opencode；无 root 用 --user（~/.local）
source /opt/opencode/env.sh       # PATH + 离线开关（随包静态文件）
./install.sh --seed               # 铺 per-user 缓存：语法高亮 + 全部 vendored 插件（幂等）
./install.sh --config             # 新装复制模板（+本地 schema）；已有配置则 jq 迁移，不覆盖
```

然后编辑 `~/.config/opencode/opencode.jsonc` 填入内网 LLM 端点（LiteLLM/openai-compatible 示例已内置）。
Ollama(11434) / vLLM(8000) 零配置自动发现。

已有 v1 配置的机器直接跑 `--config`：`plugin`→`plugins`、`opencode-acp`→`billion-context`、失效键清理、`$schema` 指向本地，
原文件自动备份；注释会丢弃（迁移结果为标准 JSON）。

## 包里有什么

```
opencode-<ver>-onprem-<platform>/
├── bin/opencode(.exe)              # opencode 二进制（官方 release 件，官方 SHA256SUMS 核对）
├── bin/rg(.exe)                    # ripgrep（linux = musl 静态版；win = msvc 版）
├── assets/tree-sitter/…            # TUI 语法高亮：34 语言 wasm + 查询文件（离线种子）
├── assets/npm/…                    # vendored 插件完整依赖树（离线种子）
├── config/opencode.airgap.json     # 内网配置模板
├── schema/…                        # JSON schema 目录（opencode config / models.dev / omo-slim，外部引用已本地化）
├── env.sh                          # 随包静态文件：PATH + 离线开关（所有用户 source 同一份）
├── install.sh                      # 安装脚本（纯拷贝 + --seed/--config）
├── README.md                       # 目标机版使用说明
└── MANIFEST.json                   # 版本/平台/来源/资产清单/sha256
```

## 能力与限制（v2.3.0 实测）

✅ 本地 LLM 推理（openai-compatible / Ollama / vLLM）、文件与 shell 工具、TUI 高亮、vendored 插件离线加载
❌ 云端模型（已隐藏）、自动更新与目录刷新（已关闭）、websearch / remote MCP（内网预期不可用）

完整行为表与验收项见 `doc/design.md`。

## 维护者

构建全部在 GitHub Actions 完成（`workflow_dispatch`，绿灯自动发 Release）：

```
gh workflow run build.yml                                      # 默认：upstream 最新 tag + linux-x64
gh workflow run build.yml -f opencode_ref=vX.Y.Z -f platform=win32-x64
```

管线设计与决策记录：`doc/design.md`；opencode 离线行为源码证据：`doc/analysis.md`。
核心方针：**零源码 patch**——离线化全部通过配置 + 环境变量 + 资产种子实现。
