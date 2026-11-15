# 分析报告：opencode v2 在 air-gap 内网的可用性

> 研究对象：anomalyco/opencode v2（本仓库 dev @ f6e0c2d，版本 2.3.0；本机安装版 2.2.7 用于实测）。
> 方法：5 个并行源码分析车道 + 本机受控实验（死外网模拟 + 干净机模拟 + mock 端点）。
> 本文所有结论均有 file:line 或实验记录支撑；设计见 `doc/design.md`。

## 1. 环境假设

| 级别 | 能力 | 缺失 |
|---|---|---|
| 级别1 | 本地 LLM（OpenAI 兼容网关/Ollama/vLLM 等，localhost 或内网） | 无任何外网、无 npm registry |
| 级别2 | 级别1 + 完整内网 npm registry 镜像 | 无 opencode.dev / github.com / models.dev |

## 2. 实测记录（决定性证据）

本机 v2.2.7 二进制，以 `HTTPS_PROXY/HTTP_PROXY=http://127.0.0.1:9`（死端口）+ `NO_PROXY=127.0.0.1,localhost` 模拟外网不可达：

| # | 实验 | 结果 |
|---|---|---|
| E1 | 自定义 provider（opencode.json，`options.baseURL` 指向本地 mock OpenAI 端点），**不带** `npm` 字段 | `opencode models` 列出 ✓；`opencode run` 执行报 `Unsupported package for localtest/mock-7b: `（空包名）❌ |
| E2 | 同上 + `"npm": "@opencode/ai/providers/openai-compatible"` | 列模型 ✓、推理 ✓（"PONG from mock local model"）。该包是**编译进二进制的内置包**（provider.ts:31-196 静态 import 表） |
| E3 | 零配置 Ollama：mock Ollama API on 127.0.0.1:11434（/api/tags + /api/show capabilities=[completion,tools]） | ~30s 后自动发现 `ollama/qwen3:8b` 并出现在 `opencode models`；`opencode run -m ollama/qwen3:8b` 推理 ✓ |
| E4 | 全新 `HOME`（无 auth.json、空配置、空缓存）+ 死外网 + `--standalone models` | 只列出 `localtest/mock-7b` 与 `ollama/qwen3:8b`（`OPENCODE_DISABLE_FREE_MODELS=1` 生效），运行时目录自动创建，无网络依赖 |
| E5 | 工具闭环：mock 模型首轮回 `tool_calls=[{name:"shell", arguments:{command:"echo hello-from-local-tool"}}]` | opencode 解析调用 → 本地 bash 执行（`--auto` 通过权限）→ 结果回传 → 模型最终答复 ✓ |
| E6 | TUI 启动（script pty + 死外网） | 正常渲染，无致命联网阻塞 |

## 3. 启动与后台网络触点（全量清单结论）

干净启动仅有 2 个外呼，**均非致命**（超时 10s + 仅记日志）：

1. 更新检查 `opencode.ai/update/api/...`（TUI 启动即查 + 每 10 分钟，`packages/cli/src/commands/handlers/default.ts:69-86`、`packages/cli/src/services/updater.ts:315-371,607-620`）。关闭：`OPENCODE_DISABLE_AUTOUPDATE=1` 或 config `update:"disable"`。
2. 模型目录刷新 `https://models.opencode.ai/experimental/v2.0/api.json`（server 启动即查 + 每 5 分钟，`packages/core/src/models-dev.ts:505-508,701-704`；10s 超时 + 2 次瞬态重试）。关闭：`OPENCODE_DISABLE_MODELS_FETCH=1` 或 config `models.fetch:false`。

**明确不存在的触点**：无遥测/分析上报；`$schema`（opencode.ai/v2/cli.json）只写入配置文件从不拉取；v2 未实现 share 功能；OTLP 仅在显式设置 `OTEL_EXPORTER_OTLP_ENDPOINT` 时启用。

**显式动作才联网**：`opencode upgrade`、`opencode plugin add/update/check`、`opencode auth login`（OAuth/设备码）、remote MCP、websearch/webfetch、URL 型 skills/instructions、remote tunnel。全部可避开或按需失败。

**致命陷阱**：
- **ripgrep 未内嵌**（`packages/core/src/ripgrep/binary.ts:121-148`）：grep/glob 工具解析顺序 系统 `rg` → `<XDG_CACHE_HOME>/opencode/bin/rg` → 从 GitHub 下载 15.1.0（**无超时**，会挂起）。内网必须提供 rg。
- **云端免费 `opencode` provider**（`packages/core/src/plugin/provider/opencode.ts:193,475-488`）：未登录也启用（公共 key），选中即连 opencode.ai 失败。用 `OPENCODE_DISABLE_FREE_MODELS=1` + config `disabled_providers:["opencode","opencode-go"]` 隐藏。
- **TUI 高亮**：仅 markdown/js/ts/zig 内嵌，其余 34 语言运行时从 GitHub 拉 wasm/queries（`packages/tui/src/parsers-config.ts`，34 filetype / 91 URL）。失败降级纯文本 + 错误日志（v1 经验：会刷屏）。可预置缓存解决（见 design §7）。

## 4. Provider 包解析链（本地 LLM 的核心机制）

`packages/core/src/provider.ts:199-230 loadPackage(specifier)`：

1. **builtins 表**（:31-196）：全部 `@opencode/ai/providers/*` 静态 `import()` 编译进二进制 —— 含 `openai-compatible`（及 `/decisions` `/images` 等）。零网络。
2. `file://` 或 `@opencode/ai/` 前缀 → 本地解析。
3. `import.meta.resolve(specifier)` → 已装包直接用。
4. 否则 `npm.add(root)` 运行时安装（需 registry）。

**config 中 provider 的包名来源**：
- config 显式字段（legacy `provider.<id>.npm` → 迁移为 `package`，`packages/core/src/v1/config/migrate.ts:115-139`；裸 npm 名会被加 `aisdk:` 前缀，`@opencode/ai/` 开头的原生名原样保留）
- models.dev 目录（`api.<protocol>.sdk.opencodeai` 优先，其次 `aisdk`；`packages/core/src/models-dev.ts:252-289`）

**Ollama/vLLM 内置插件**（`packages/core/src/plugin/provider/ollama.ts`、`local.ts:79`）：强制使用内置 `@opencode/ai/providers/openai-compatible` 包，origin `http://127.0.0.1:11434` / `127.0.0.1:8000`，后台发现（15s 超时/30s 间隔），失败不阻塞启动。**LiteLLM 网关即 openai-compatible：用 E2 配置路径。**

**模型目录兜底**：填充顺序 `OPENCODE_MODELS_PATH` 本地文件 → KV 缓存 → **二进制内嵌 snapshot.txt（8.2MB，v2 格式）** → 网络（`models-dev.ts:649-665`）。离线目录完整可用；`OPENCODE_MODELS_PATH` 可整体替换（v1/v2 格式均可）。

## 5. LSP 现状（v2 硬伤，已决策放弃）

- v2 **没有任何 LSP 运行时**：config schema 接受并保存 `lsp`（`packages/schema/src/config/lsp.ts`），normalizer 仅校验转存（`packages/core/src/config/normalize.ts:500-509`）；`lsp.updated` 事件已定义但无发射者；无 server 启动、无诊断、无 lsp 工具（`packages/core/src/file-mutation.ts:138` 等 3 处 TODO）。
- 官方迁移文档明示（`services/site/src/docs/content/migrate-v1.mdx:454-455`）："V2 ... does not run language servers, expose LSP tools, or produce LSP diagnostics."
- v1 的 LSP 依赖 GitHub 自动下载，air-gap 下同样不可用。**决策：跟随 v2 官方路线，bundle 不补 LSP。**

## 6. 插件 / MCP / 工具（lane E）

- **插件加载**（`packages/core/src/plugin/module.ts:107-119`、`source.ts:104-150`）：绝对路径/`file://`/`./`/`../` = 本地目录插件（内嵌 Bun 加载器，TS 热重载，零 npm）；其余 spec → `npm.add`。**本地路径插件是离线正道。**
- **插件兼容性实测**（vendored 加载验证，软失败会静默不生效——声称兼容必须实测）：
  oh-my-opencode-slim@3.0.7 ✅；billion-context@0.1.213 ✅（opencode-native 入口，acp 的 v2 继任者）；
  opencode-acp@1.18.1 ❌（"Plugin must export a default definition..."，2.2.7 与 2.3.0 一致；已被 billion-context 取代）；superpowers@0.0.2 ❌ 同因（peer 依赖 v1 API 包名 `@opencode-ai/plugin`）。
- **内置插件编译进二进制**（`packages/core/src/plugin/internal.ts:247-332`）：providers、websearch、tools、MCP defaults、格式化、skills 等。打电话家的只有 models-dev 目录（§3）与 Console（仅登录后）。
- **MCP**：stdio 本地型完全离线（spawn 本地命令，`mcp/stdio.ts:47-110`）；remote 型需网络。无默认注入 server。
- **工具**：文件/编辑/shell/todo/skill/subagent 等纯内置；**唯一下载二进制的是 rg**（§3）。JS 格式化器（prettier/biome/oxfmt）仅在项目声明时运行时 npm 解析。
- **skills/agents/commands**：本地目录加载；URL 型 skills 离线降级跳过。

## 7. 打包与分发（lane D）

- 产物 = **每平台一个 Bun 编译单二进制**（`packages/cli/script/build.ts:168-219`，12 目标；linux-x64 有 glibc/musl 与 AVX2/baseline 变体）。JS、TUI（SolidJS 编译）、HTTP server、web UI（brotli 归档）、DB migration、models.dev 快照、tree-sitter 引擎与内嵌语法、PTY 助手、fff 原生库、photon wasm 全部内嵌。
- 运行时**不需要** node_modules/Node/Bun；唯一外置解析物是 rg（§3）与 34 语言高亮缓存（§3）。
- 原生件处理：`@opencode/pty` 助手以 `type:"file"` 资产内嵌、首用释放到 `<cache>/opencode/bin/opencode-pty/`（校验和）；`@parcel/watcher-linux-x64-glibc`、opentui 原生库、libfff_c.so、photon wasm 构建期内嵌。`$TMPDIR` 需可写**且可执行**（Bun 解压内嵌原生对象；noexec 会降级）。
- 目录（`packages/util/src/global-roots.ts`）：`~/.config/opencode`、`~/.local/share/opencode`（含 DB）、`~/.cache/opencode`（bin/npm）、`~/.local/state/opencode`、`$TMPDIR/opencode`。
- 构建要求：bun 版本被源码 `packageManager: bun@1.4.4` 钉死；`bun install` 全量 npm 依赖（无 git/tarball 依赖，19 个本地 patch 包）；`build.ts` 额外 `bun install --os=* --cpu=* --libc=* @opentui/core @opencode/pty`（除非 `--skip-install`）；设 `OPENCODE_VERSION` 避免生成 preview 版本号。
- 官方 docker 产物（`pack:docker`，Alpine musl + ripgrep）本次不用（决策 D6）。

## 8. npm 种子语义（vendored 包的离线生效机制）

`packages/util/src/npm.ts`：

1. **短路**（:263-268）：`install()` 先取缓存代目录 `current(dir)`；若 `!update` 且 `node_modules/<name>` 存在 → 直接返回元数据，**零网络**。
2. **缓存键**（:84,148）：`<XDG_CACHE_HOME>/opencode/npm/<name>@<spec>`；裸包名 → `@latest`，`pkg@stable` → `@stable`。
3. **代目录**（:149-161）：`<key>/<纯数字时间戳>/`，`current()` = 数值最大者；安装经 `.staging-*` 原子 rename 落地。
4. **GC**（:331-350）：永远保留**最新 2 个**完整代目录（`keep = completed.slice(-2)`），其余纯数字目录 7 天过期、`.staging-*` 1 小时过期。⇒ 离线机种子代永远是最新代，**永不过期**；联网机被新安装顶替后 7 天自然回收。
5. 插件 supervisor 的 update 检查（`plugin/supervisor.ts:172-183`）仅对包型插件跑、离线失败软降级为"未过期"。

⇒ **结论**：bundle 携带 `<pkg>@<spec>/node_modules/<完整依赖树>`，install.sh 拷贝为 `~/.cache/opencode/npm/<key>/<now_ms>/node_modules/...` 即可离线生效，且与未来联网安装自然共存。

## 9. tree-sitter 种子语义（TUI 高亮的离线生效机制）

`@opentui/core` 0.8.4（parser.worker.js / chunk-bun-83k2gdpc.js）：

1. `DownloadUtils.downloadOrLoad`（:3231）：URL 源先查缓存文件，命中即返回**零网络**；非 URL 源直接 `readFile` 本地路径。
2. **wasm 缓存名**：调用处 `useHashForCache=false`（:3875）→ `path.basename(URL)`，落在 `<dataPath>/tree-sitter/languages/<basename>.wasm`。
3. **query 缓存名**：`useHashForCache=true`（:104）→ `<filetype>-<hash(url)>.scm`，落在 `<dataPath>/tree-sitter/queries/`。`hashUrl`（:3237-3242）是 5 行确定性算法（int32 溢出累积，`Math.abs().toString(16)`），可在打包脚本中精确复现。
4. **dataPath**：`$XDG_DATA_HOME/opentui`（默认 `~/.local/share/opentui`；appName 固定 "opentui"，:7412-7425）。**不能**全局改 `XDG_DATA_HOME` 重定位（会连带搬走 opencode 自身数据目录），故采用 install.sh per-user 种子。

⇒ **结论**：预下载 91 个 URL、按上述命名铺缓存 → TUI 高亮 34 语言全离线，缓存命中日志可见（`Loaded from cache: ...`），错误刷屏消失。

## 10. 环境级别结论

| 能力 | 级别1（仅本地LLM） | 级别2（+内网npm） |
|---|---|---|
| 本地推理（openai-compatible/Ollama/vLLM） | ✅ 实测 | ✅ |
| 本地执行工具（含权限/工具循环） | ✅ 实测 | ✅ |
| TUI 高亮 | ✅（种子后） | ✅ |
| 模型目录/列表 | ✅（内嵌快照） | ✅ |
| npm 插件 / JS 格式化器 | slim+billion-context ✅ vendored 实测；acp/superpowers ❌（已被 billion-context 取代/v1 形状） | ✅（`.npmrc` 指内网镜像） |
| LSP | ❌ v2 未实现 | ❌ |
| websearch/webfetch/remote MCP/升级 | ❌ | ❌（属预期） |
