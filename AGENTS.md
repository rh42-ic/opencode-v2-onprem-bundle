# AGENTS.md — 维护规则（给后续 agent / 维护者）

## 每次推送前：更新 git 插件的版本钉定（必做）

manifest.json 中所有 `git+https://…` 形式的插件 spec 都**钉 commit SHA**。
不钉（或钉 tag/分支名）的 spec 是 mutable，opencode 运行时每次加载都会尝试联网 update，
离线机（本 bundle 的目标环境）上会加载失败，并可能阻塞 model.list。

推送前执行：

```bash
# 1) 查上游 main 最新 commit
git ls-remote https://github.com/obra/superpowers.git refs/heads/main
git ls-remote https://github.com/yuseferi/opencode-litellm.git refs/heads/main

# 2) 把输出的 40 位 SHA 更新进 manifest.json 对应 spec 的 #fragment，
#    顺带核对 description 中的版本说明是否仍准确

# 3) 有更新时顺带看一眼上游 changelog/release，确认插件形态没有破坏性变化
```

规则来源与原理见 doc/design.md（插件目录表）与 doc/analysis.md（npm.ts 缓存键/mutable 判定）。

## 其他不变式

- **verify.sh 是发布门禁**：CI 绿灯才会发 Release；verify 失败不许绕过（`--skip-verify` 仅限明确标注 unverified 的场景）。
- **零源码 patch**：问题优先用 config / 环境变量 / 资产种子解决；确实需要动源码时先提案再引入。
- **声称兼容的插件必须实测**：进 manifest 前要在 opencode 上实测加载成功，软失败（WARN）不算数。
- manifest 里 `default: "on"` 的插件才会注入配置模板默认启用；`off` 只打包（`seed.sh` 照种缓存，用户改 config 即启用）。
- **bundle 内不许有构建相关内容**：安装脚本只做拷贝；用户环境文件（env.sh）是随包静态文件，不生成 per-user 内容。
- 仓库内不得出现任何代理/出口地址等维护者本机环境信息。
