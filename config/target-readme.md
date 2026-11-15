# 内网机使用说明（bundle 随附）

## 安装（管理员）

```bash
sudo ./install.sh                     # 默认 /opt/opencode
sudo ./install.sh --prefix /your/dir  # 自定义
```

## 用户侧

```bash
source /opt/opencode/env.sh           # PATH + 关闭联网检查等环境
/opt/opencode/install.sh --seed       # 铺 rg + TUI 语法高亮缓存（幂等，可重复）
/opt/opencode/install.sh --plugins default   # 可选：离线启用 vendored 插件（all/none/名字列表）
/opt/opencode/install.sh --config     # 可选：把配置模板复制到 ~/.config/opencode/
```

## 本地 LLM

- Ollama（127.0.0.1:11434）/ vLLM（127.0.0.1:8000）：**零配置**，启动后 ~30s 自动发现。
- LiteLLM 等 OpenAI 兼容网关：参考 `config/opencode.airgap.json` 内注释模板填写
  （`provider` + `npm: "@opencode/ai/providers/openai-compatible"` + `options.baseURL`）。

## 注意事项

- `opencode --version` 确认安装；`rg --version` 确认 rg 可用（PATH 或缓存）。
- `$TMPDIR` 必须可写且**可执行**（二进制解压内嵌原生件）；若 /tmp noexec，`export TMPDIR=…`。
- 无外网属预期：更新检查/云端目录已关闭；websearch/webfetch/remote MCP/升级不可用；LSP 为 v2 未实现。
- 额外 npm 插件：级别2 机器可用 `.npmrc`/`NPM_CONFIG_REGISTRY` 指向内网镜像后 `opencode plugin add <pkg>`。
