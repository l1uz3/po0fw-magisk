# 更新日志

## v1.0.1

- KernelSU / APatch 不再需要元模块（metamodule）：模块不带 `system/`，`po0fw` 命令放进 su 自带的 PATH（`/data/adb/ksu/bin`、`/data/adb/ap/bin`），Magisk 照旧用 `system/bin`
- 卸载时一并删除命令行入口

## v1.0.0

- 首个版本：切网即时加白 + 定时兜底（默认 10 分钟）
- root 绑定物理网卡直连，绕过代理 VPN，加白本机真实公网 IP
- 失败退避重试；token 错误（HTTP 4xx）按兜底间隔重试
- 模块列表实时显示状态，管理器「操作」按钮立即加白
- `po0fw` 命令行 + KernelSU / APatch WebUI
- 支持 464XLAT、自签证书公钥固定、多个加白接口
- 管理器内检查更新（`updateJson`）
