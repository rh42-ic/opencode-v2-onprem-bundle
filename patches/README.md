# patches/

**方针：源码 patch 是不得已的最后手段**（可能引入 bug，且随 upstream 升级失效）。

规则：
1. 一切离线需求优先用 配置 + 环境变量 + 资产种子 解决（见 `doc/design.md` §2）。
2. 只有 verify 证明无替代解法时才允许 patch。
3. patch 文件按文件名顺序 `git apply`，命名 `NNN-<描述>.patch`。
4. 每个 patch 必须在 MANIFEST.json 的 `patches` 数组记录：目标文件、理由、引入时间。
5. 引入 patch 后，`verify.sh` 需提供有/无 patch 对照（或至少论证 patch 为空操作时行为不变）。

当前：**空**（v2 bundle 全部需求零 patch 达成）。
