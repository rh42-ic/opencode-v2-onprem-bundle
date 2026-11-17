# 设计：opencode-v2-onprem-bundle 打包管线

> 证据基础见 `doc/analysis.md`。方针与所有关键决策经用户评审定稿（§10 决策记录）。

## 1. 目标

为 air-gap 内网（级别1：仅本地 LLM；级别2：+ 内网 npm registry 镜像）产出可复现的 opencode v2 离线 bundle，
并在 upstream（anomalyco/opencode）发布新 tag 时以最小维护成本跟随重建。

**成功标准**：内网机上 本地推理 ✓、本地执行工具 ✓、TUI 高亮 ✓、（vendored）插件 ✓；无致命网络依赖。

## 2. 核心方针

1. **源码 patch 是不得已的最后手段**（用户方针）。离线化全部通过 配置 + 环境变量 + 资产种子 实现。
   当前结论：**零 patch**。不设 patches 机制；确需 patch 时先在本文提案（MANIFEST 记理由 + verify 有/无对照测试）再引入。
2. **版本真相从源码提取，不硬编码**：rg 版本号（`ripgrep/binary.ts` 的 VERSION）、tree-sitter URL 列表
   （`parsers-config.ts`，构建期用 bun import 提取）、bun 版本（源码 `packageManager`）、opencode 版本
   （`packages/cli/package.json`）。upstream 升级后脚本自动跟随。
3. **每次构建必须过 verify**（模拟内网级别1），通过才允许产出/发布。

## 3. 总体架构：CI-first，本地可复现

- **CI 主路径**：GitHub Actions `workflow_dispatch`（input `opencode_ref`，默认 upstream 最新 tag）
  → 检出源码 → 同一管线 → verify → 自动创建 GitHub Release。
- **本地路径**：`bun run scripts/build.ts …` 跑同一管线（worktree 临时目录构建，不污染主工作区；
  出口环境由维护者 shell 自行注入，管线不感知）。
- 工程与 opencode 官方 tag 不定期同步发布（用户维护节奏）。

## 4. 管线流程（scripts/build.ts）

```
bun run scripts/build.ts [--ref <tag|branch|sha>] [--platform linux-x64|win32-x64] [--from-source] [--work <dir>]
  1. resolve-ref      无参 = 最新 v* tag（git ls-remote；OPENCODE_REPO 可覆盖为本机检出）
  2. source           git worktree add --detach <work>/src <ref>
  3. binary           默认官方 release（ref 为 tag 才可；SHA256SUMS 核对）；--from-source 或非 tag ref → 源码构建
                      （源码路径：bun install 校验版本与 packageManager 一致 → bun run script/build.ts 平台目标）
  4. assets           rg / tree-sitter / npm 插件 → <work>/assets/；配置 schema → assets/schema/（§6）
  5. pack             bundle 目录 + config 模板注入 plugins + MANIFEST.json（§5）
  产物                linux: out/opencode-v<ver>-onprem-bundle-<platform>.tar.gz；win: 同名 .zip（自包含写入器，固定时间戳）
                      + .sha256 + <work>/build.env
                      verify 由 CI 或维护者单独跑：scripts/verify.sh（§8）
```

环境要求：bun（版本随源码）、git、node 可选（npm CLI 用其解析 vendored 依赖树；CI 自带）。

## 5. bundle 布局

```
opencode-<ver>-onprem/
├── bin/opencode                          # Bun 单二进制（内含 TUI/server/webUI/模型目录快照/全部原生件）
├── bin/rg                                # ripgrep，musl 静态版（glibc/musl 通吃）
├── assets/
│   ├── tree-sitter/languages/*.wasm      # 34 语言，文件名 = URL basename（=opentui 缓存名）
│   ├── tree-sitter/queries/<ft>-<hash>.scm  # 91 URL 全量，hash 复现 opentui hashUrl
│   └── npm/<pkg>@<spec>/node_modules/... # vendored 插件/格式化器完整依赖树
├── config/opencode.airgap.json           # 内网配置模板
├── schema/                               # JSON schema 独立目录（外部 $ref 递归本地化）
│   ├── config.json                       # opencode 配置 schema（$id 已改本地文件名）
│   ├── models.dev-model-schema.json      # config schema 外部引用（models.dev 模型定义）
│   └── oh-my-opencode-slim.json          # omo-slim 插件配置 schema（包内自带）
├── install.sh                            # 目标机安装脚本（自包含，仅做拷贝）
├── env.sh                                # 随包静态环境文件（所有用户 source 同一份）：PATH 自定位 + 离线开关
├── seed.sh                               # per-user 缓存种子（独立脚本，幂等）
└── MANIFEST.json                         # 源 commit、版本、bun、资产清单、sha256
```

## 6. 资产提取与下载（build.ts 内联）

| 资产 | 版本真相来源 | 下载 | 落位 |
|---|---|---|---|
| rg | `packages/core/src/ripgrep/binary.ts` 的 VERSION + 平台表（linux=x64-linux / win=x64-win32） | GitHub release（musl x64 / msvc zip，sha256 与源码常量核对） | `bin/rg(.exe)` |
| tree-sitter | bun import `packages/tui/src/parsers-config.ts` | 全部 wasm + queries URL（遵循出口环境变量，.dl-cache 幂等） | `assets/tree-sitter/{languages,queries}/`（命名规则见 analysis §9） |
| npm 插件 | manifest `plugins[]`（spec/git_ref/description） | registry：临时项目 npm install → 抽取 node_modules 子树；git：clone（SHA 钉定零网络）→ 就地装包内依赖 | `assets/npm/<key>/node_modules/<真实包名>/`（键规则见下） |
| 配置 schema | `https://opencode.ai/config.json`（v2 发布形态，兼容 v1 键） | 每次构建现取；递归爬取外部 `$ref`（当前仅 `models.dev/model-schema.json`）并改写为本地文件名（`$id` 同步改本地，否则相对 `$ref` 按远程 base URI 解析）；omo-slim 包内 schema 一并拷入 | `schema/config.json` + 外部引用文件 + `schema/oh-my-opencode-slim.json`；模板 `"$schema": "./schema/config.json"` |

npm 种子键规则（复现 `npm.ts:84`）：config 写 `pkg` → 键 `<pkg>@latest`；写 `pkg@stable` → 键 `<pkg>@stable`。
**README 与 install.sh 输出的"准确 config 写法"必须与种子键一致**，否则运行时不命中缓存。

初始插件目录（**以 verify 实际加载为准**，声称兼容的插件必须实测）：

| 插件 | spec 写法 | default | 实测 |
|---|---|---|---|
| oh-my-opencode-slim | `oh-my-opencode-slim` | on | ✅ 加载成功（2.3.0） |
| billion-context | `billion-context` | on | ✅ 0.1.213 加载成功（opencode-native 入口；acp 的 v2 继任者） |
| opencode-acp | `opencode-acp@stable` | ❌ 移出目录 | 1.18.1 在 2.2.7 与 2.3.0 均加载失败（v1 形状）；v2 由 billion-context 取代 |
| superpowers | `superpowers` | ❌ 移出目录 | 0.0.2 同上 |

移出者记录在 manifest `plugins_unverified`（含复查方法），upstream 发布 v2 API 版本后可移回。

## 7. 目标机安装布局（不写 /usr/local/bin）

```
sudo ./install.sh [--prefix /opt/opencode]     # 管理员侧，默认 /opt/opencode；只做拷贝
/opt/opencode/
├── bin/opencode                                # 二进制（拷贝，无壳）
├── bin/rg                                      # rg（用户把 env.sh source 后，rg 经 PATH 命中）
├── assets/...                                  # 种子源（per-user 复制用）
├── env.sh                                      # 随包静态文件原样拷贝：PATH 自定位 + 三个离线开关；网络配置用户自填
├── seed.sh                                     # per-user 缓存种子（独立脚本，幂等）
├── config/opencode.airgap.json                 # 配置模板（用户手工复制）
└── schema/                                     # JSON schema 目录（config + 外部引用 + omo-slim）

用户侧（source env.sh 后）：
  ./seed.sh                                     # 铺 per-user 缓存（幂等）：
                                                #   ${XDG_DATA_HOME:-~/.local/share}/opentui/tree-sitter/{languages,queries}/
                                                #   ~/.cache/opencode/npm/<key>/<now_ms>/node_modules（全部 vendored 插件原样拷贝，键=npm.ts 规则）
                                                #   rg 不拷贝：已随 PREFIX/bin 进 PATH
配置：模板与 schema/ 仅供参照，用户手工复制为 ~/.config/opencode/opencode.jsonc（不做自动迁移/合并）
```

## 8. verify.sh（CI 与本地同一套）

模拟内网级别1：断网仿真 env（死端口） + 全新 HOME（mktemp）+ 本地 mock 端点（tests/mock-llm.py:8902、mock-ollama.py:11434）。
用**刚 pack 出的 bundle** 安装到临时 PREFIX + seed 后跑断言：

| # | 断言 |
|---|---|
| 1 | `opencode --standalone models` 只列本地 provider（无 opencode-go/deepseek） |
| 2 | `opencode run` 推理成功（mock OpenAI 端点，PONG） |
| 3 | shell 工具闭环：mock 模型发 `shell` 调用 → 本地执行 → 结果回传 → 最终答复 |
| 4 | rg 命中本地（仅 PREFIX/bin 经 PATH；用户缓存无多余拷贝），日志无 `Downloading from URL: github.com/BurntSushi` |
| 5 | TUI 高亮：prompt 返回代码块 → 日志无 "No parser available" 刷屏、无 GitHub 下载尝试 |
| 6 | 启动日志无致命错误 |
| 7 | 零配置 Ollama 自动发现 + 推理 |
| 8 | vendored 插件离线加载（种子缓存 + config 插件 → 加载成功、无网络安装尝试） |
| A9 | 配置 schema：独立 schema/ 目录随包、外部 $ref 递归本地化（无远程 $ref 残留 + models.dev 文件存在）、模板 $schema 本地、omo-slim schema 随包 |

## 9. CI / Release

- workflow：`.github/workflows/build.yml`，`workflow_dispatch`（inputs: `opencode_ref`、`platform`、`skip_verify`、`build_from_source`）；steps = checkout → bun 环境对应源码 packageManager → `bun run scripts/build.ts` → `scripts/verify.sh`（`--skip-verify` 可跳）→ Release（tag `bundle-v<ver>`，notes 含源 commit/platform/binary source）。
- **脚本极简终态（m01362）**：scripts/ 仅 build.ts（唯一管线入口）+ install.sh + verify.sh；tests/ 仅 mock-llm.py + mock-ollama.py。
- runner 自带外网（资产下载无需任何出口预设）；verify 用死端口断网仿真。
- Release：tag 名 `bundle-v<opencode版本>`，附件 = 平台归档（linux `.tar.gz` / win `.zip`，Windows 解压友好）+ `.sha256`；release notes 含源 commit、平台、binary source。
- **首次 CI 绿灯实证（run 43585634372）**：ubuntu runner 全流程（worktree 检出 dev → 构建 → 资产 → 打包 → 离线验收）通过并发布 `bundle-v2.3.0`。
  踩坑记录：workflow 注册需 boolean input 用布尔默认值；runner 预设 XDG_* 必须全程 unset（否则 opencode 读错 config 目录，config provider 永不注册）；
  冷 FS 下插件激活需 provider 就绪轮询。
- 已知限制：tar.gz 因 MANIFEST `built_at` 与文件 mtime 不做字节级可复现（内容等价；如需可加确定性打包选项）。
- 维护手册（upstream 同步）：新 tag → `gh workflow run build.yml -f opencode_ref=vX.Y.Z`（默认官方件；需要 patch 时加 `-f build_from_source=true`，非 tag ref 亦然）→ 若 build/verify 因 upstream 行为变化失败，
  按 analysis.md 定位 → 优先找新的 config/env/种子解法 → 确无解时先在本文提案、再考虑引入 patch 机制 → Release。

**版本漂移风险点**（维护时重点核对）：`parsers-config.ts` URL/结构变化（提取器与 hash 命名）；
`npm.ts` 缓存键/GC 语义变化；`ripgrep/binary.ts` 解析顺序或版本常量变化；`provider.ts` builtins 表
（若 `openai-compatible` 被移出内置表则 LiteLLM 路径需重新评估）；config 键迁移（`update`/`models.fetch`/`disabled_providers`）。

## 10. 决策记录（ADR）

| # | 决策 | 理由 |
|---|---|---|
| D1 | LSP 不做 | v2 无 LSP 运行时（官方明示）；用户裁定"v2 不做就不加" |
| D2 | 零 patch 方针 | patch 可致 bug 且随 upstream 失效；全部需求 config/env/种子可达 |
| D3 | 本地 LLM 走 openai-compatible 内置包 | LiteLLM 网关即此路径（实测 E2）；Ollama/vLLM 另有零配置内置发现 |
| D4 | provider 配置由内网用户自填 | bundle 只给模板与准确写法 |
| D5 | linux-x64 default（glibc, AVX2）变体 | 用户裁定；不做 baseline/musl |
| D6 | 不做 docker 形态 | 用户裁定 |
| D7 | CI-first + Release 发布 | 用户裁定；与官方 tag 同步发布 |
| D8 | /opt/opencode + 用户 source env.sh；不写 /usr/local/bin | 用户裁定；无 root 场景由管理员指定 --prefix |
| D9 | rg 无 patch：PATH + per-user 缓存双保险 | patch last-resort 方针 |
| D10 | tree-sitter 无 patch：预下载 + 复现缓存命名 per-user 种子 | 缓存命中即零网络（analysis §9）；v1 的 patch 方案不再需要 |
| D11 | vendored npm 层 + 插件目录；目录以 verify 实际加载为准（仅 oh-my-opencode-slim 通过） | npm 短路语义已验证（analysis §8）；acp/superpowers 实测为 v1 形状插件（2.2.7 与 2.3.0 均加载失败，软 WARN 静默），移入 plugins_unverified 待复查 |
| D12 | git worktree 构建，不动主工作区 | 用户授权自行判断 |
| D13 | 产物命名带平台：`opencode-v<ver>-onprem-bundle-<platform>.tar.gz|.zip`；管线以 platform 参数化（linux-x64 全量验证；win32-x64 发布标注 unverified） | 用户要求标平台，未来发 win 版；同一 opencode 版本多平台合入同一 Release（assets 追加） |
| D14 | 二进制默认取官方 release（SHA256SUMS 核对，MANIFEST 记 `binary_source`），自编译降级为 `build_from_source` fallback；非 tag ref（branch/commit）必须走自编译 | 用户确认：零 patch 方针下自编译非必要；官方件变体更全（avx2/baseline、glibc/musl、win 原生件），CI 与上游构建链解耦更稳；官方件已实测通过同套 16 项验收 |

## 11. 离线行为速查（v2.3.0 证据基础）

| 行为 | 离线表现 | 保障手段 |
|---|---|---|
| 本地 LLM（openai-compatible/Ollama/vLLM） | ✅ 全功能 | config `provider.*.npm = "@opencode/ai/providers/openai-compatible"`（内置包）；Ollama/vLLM 零配置自动发现 |
| 文件/编辑/shell 工具 | ✅ | 内置；rg 由 bundle 提供 |
| TUI 高亮（34 语言） | ✅（种子后） | `seed.sh` 铺 opentui 缓存（命名可复现） |
| 模型目录 | ✅ | 二进制内嵌 8.2MB 快照；`OPENCODE_MODELS_PATH` 可换本地文件 |
| npm 插件/格式化器 | ✅（种子后；slim+billion-context 实测可加载） | `~/.cache/opencode/npm/<pkg>@<spec>/<ts>/node_modules` 命中即短路（GC 永远保留最新代） |
| 更新检查 / models.dev 刷新 | 静默失败（log） | env.sh 关闭 |
| 云端 opencode 免费模型 | 不可用 | 已隐藏（disabled_providers + OPENCODE_DISABLE_FREE_MODELS） |
| LSP | ❌ v2 未实现 | 官方明示；配置被接受但不生效 |
| websearch/webfetch/remote MCP | ❌/按需失败 | 内网无外网，属预期 |

## 12. 环境角色划分

三类角色，环境需求互不交叉；**管线代码不含任何网络环境预设**——用什么出口是各角色自己的事。

| 角色 | 网络环境 | 需要 source/设置什么 | 来源 |
|---|---|---|---|
| **user 运行**（内网目标机） | 内网 | `source $PREFIX/env.sh`（随包静态文件，PATH 自定位 + `OPENCODE_DISABLE_AUTOUPDATE/MODELS_FETCH/FREE_MODELS=1`）；LLM 端点填 config 模板；级别2 的 npm registry 由用户自行设置 | bundle 根 `env.sh`（install.sh 原样拷贝） |
| **Action 构建**（CI） | 公网直连 | 无——只要工具链（bun/git/curl/unzip/python3），行为由 workflow input（ref/platform/build_from_source）决定 | `.github/workflows/build.yml` |
| **维护者本机**（本地调试） | 视本机网络 | 无——需要出口就自己在 shell `export`，管线不感知 | `bun run scripts/build.ts`（可选） |

verify.sh 内部的 死端口断网仿真(127.0.0.1:9) + `NO_PROXY=localhost` + `unset XDG_*` 是**内网仿真的实现**（测试装置），三类角色都无需关心。
| D15 | win32-x64 归档用 zip（自包含 deflate 写入器，零外部命令、固定时间戳） | 用户：tar.gz 在 Windows 解压困难；CI 与本地均不依赖 zip/7z 工具 |
| D16 | 配置 schema 独立 `schema/` 目录随包（build 时取 opencode.ai/config.json，递归爬取外部 `$ref`（models.dev）改写为本地文件名，`$id` 同步改本地；omo-slim 包内 schema 一并随包），模板/迁移配置 `"$schema": "./schema/config.json"` | 用户：schema 要单独目录、外部引用也要遍历；内网编辑器离线可补全/校验 |
| D17 | install.sh 极简：只做拷贝（无 --user/--seed/--config）；种子拆到独立 seed.sh；配置不做自动迁移，用户手工复制模板 | 用户 m01833 要求简化 install；自动迁移既可能误伤用户 provider 设置，又引入 jq 依赖 |
| D18 | rg 只保留一份（PREFIX/bin，经 env.sh 进 PATH），seed.sh 不再拷贝到 ~/.cache/opencode/bin | 用户：rg 与 opencode 同处 bin 已足够，没必要复制到用户 home |
