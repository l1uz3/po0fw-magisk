# 更新日志

## v1.0.2

- 切网后加白更快：网络安静 1 秒（原 3 秒）就加白，`SETTLE` 默认改为 1
- 更新时，配置里还是旧默认值 `SETTLE=3` 的会自动改成 1；改过的值保持不变

## v1.0.1

- 去掉 `po0fw` 命令（`system/bin/po0fw`）：模块不再挂载任何系统文件，KernelSU / APatch 不需要元模块（metamodule）
- 填 token、看日志、查证书都在 WebUI 里完成；排查时可用完整路径 `su -c sh /data/adb/modules/po0fw/po0fw.sh <命令>`

## v1.0.0

- 首个版本：切网即时加白 + 定时兜底（默认 10 分钟）
- root 绑定物理网卡直连，绕过代理 VPN，加白本机真实公网 IP
- 失败退避重试；token 错误（HTTP 4xx）按兜底间隔重试
- 模块列表实时显示状态，管理器「操作」按钮立即加白
- `po0fw` 命令行 + KernelSU / APatch WebUI
- 支持 464XLAT、自签证书公钥固定、多个加白接口
- 管理器内检查更新（`updateJson`）
