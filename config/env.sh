# opencode v2 onprem bundle —— 随包静态环境文件（所有用户 source 同一份，无 per-user 生成）
# 自定位：无论安装在哪个 PREFIX，PATH 即获得本目录 bin/；离线开关随包内置。
export PATH="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/bin" && pwd):$PATH"
# 关闭外网行为（内网预期；v2.3.0 源码仅此三个开关，无 config 等价物）
export OPENCODE_DISABLE_AUTOUPDATE=1
export OPENCODE_DISABLE_MODELS_FETCH=1
export OPENCODE_DISABLE_FREE_MODELS=1
# 级别2（内网 npm registry 镜像）等网络配置由用户自行设置，此处不做预设
