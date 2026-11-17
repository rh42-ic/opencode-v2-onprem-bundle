# 内网机使用说明（bundle 随附）

## 安装（管理员）

```bash
sudo ./install.sh                     # 默认 /opt/opencode
sudo ./install.sh --prefix /your/dir  # 自定义
```

## 用户侧

```bash
source /opt/opencode/env.sh           # PATH + 关闭联网检查等环境
/opt/opencode/seed.sh                 # 铺 TUI 语法高亮 + 全部 vendored 插件缓存（幂等，可重复）
```

## 配置与 schema

- 配置模板 `config/opencode.airgap.json`（build 时已注入 vendored 插件清单）：复制为 `~/.config/opencode/opencode.jsonc` 后填写 provider。
- JSON schema 独立目录 `schema/`（外部 `$ref` 已递归本地化，编辑器离线可用）：
  - `schema/config.json` — opencode 配置；如需本地补全，把 `schema/` 复制到 `~/.config/opencode/schema/`，配置 `"$schema": "./schema/config.json"`
  - `schema/models.dev-model-schema.json` — config schema 引用的 models.dev 模型定义（本地改写）
  - `schema/oh-my-opencode-slim.json` — omo-slim 插件配置用；其配置 `~/.config/opencode/oh-my-opencode-slim.json` 的 `"$schema"` 可写 `./schema/oh-my-opencode-slim.json`
- v1 旧配置：手工迁移 `plugin`（v1 键）→ `plugins`（v2 键）；`opencode-acp@…` → `billion-context`（acp 在 v2 加载失败会阻塞 model.list）。

## 本地 LLM

- Ollama（127.0.0.1:11434）/ vLLM（127.0.0.1:8000）：**零配置**，启动后 ~30s 自动发现。
- LiteLLM 等 OpenAI 兼容网关：参考 `config/opencode.airgap.json` 内注释模板填写
  （`provider` + `npm: "@opencode/ai/providers/openai-compatible"` + `options.baseURL`）。

## 注意事项

- `opencode --version` 确认安装；`rg --version` 确认 rg 可用（与 opencode 同在 bin/，经 env.sh 进 PATH）。
- `$TMPDIR` 必须可写且**可执行**（二进制解压内嵌原生件）；若 /tmp noexec，`export TMPDIR=…`。
- 无外网属预期：更新检查/云端目录已关闭；websearch/webfetch/remote MCP/升级不可用；LSP 为 v2 未实现。
- 额外 npm 插件：级别2 机器可用 `.npmrc`/`NPM_CONFIG_REGISTRY` 指向内网镜像后 `opencode plugin add <pkg>`。
- Windows 包为 zip：资源管理器直接解压即可。
