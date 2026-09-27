# po0fw-magisk

po0fw 防火墙白名单自动加白模块，支持 Magisk / KernelSU / APatch。

切网后约 1 秒加白，另每 10 分钟兜底一次。请求用 root 绑定物理网卡直连，开着代理 VPN 也能加白本机真实公网 IP。

## 和 MacroDroid 比

| | MacroDroid | po0fw-magisk |
|---|---|---|
| 开着代理 VPN | 可能加白成代理出口 IP | 绑定物理网卡，一定是真实 IP |
| 后台存活 | 可能被系统杀掉 | root 守护进程，不依赖 App |
| 切网检测 | 系统广播 | 内核网络事件，约 1 秒 |
| 需要 root | 不需要 | 需要 |

## 安装

1. 从 [Releases](https://github.com/l1uz3/po0fw-magisk/releases) 下载 zip，在管理器里刷入，重启
2. 打开模块的 WebUI 填 token，点「保存并加白」
3. 看到 `HTTP 200` 即成功，之后全自动

- 没有 WebUI 的话（Magisk 需要借助 MMRL 等应用才能打开 WebUI），也可以用 MT 管理器编辑 `/data/adb/po0fw/config.conf`，然后在管理器里点「操作」
- 支持 arm64-v8a / armeabi-v7a；Magisk ≥ 20.4（「操作」按钮需 ≥ 28）
- 不挂载系统文件，KernelSU / APatch 不需要元模块
- 发新版后管理器里会提示更新

## 配置

`/data/adb/po0fw/config.conf`，改完几秒内生效，更新模块不会覆盖。

| 项 | 默认 | 说明 |
|---|---|---|
| `URL` | — | 加白接口，可写多行 |
| `INTERVAL` | `600` | 兜底间隔（秒） |
| `SETTLE` | `1` | 网络变化后等几秒再加白 |
| `BIND_IFACE` | `1` | `0` 走系统默认路由（开 VPN 时会走代理） |
| `INSECURE` / `PIN` | `0` / 空 | 自签证书用，PIN 在 WebUI「证书信息」里查 |

其他项（`IFACE`、`TIMEOUT`、`IPV`、`DNS`、`OK_REGEX`、`DEBUG`）见配置文件里的注释。

## 排查

- 日志：WebUI「查看日志」，或 `/data/adb/po0fw/po0fw.log`
- **HTTP 403**：token 不对
- **证书校验失败**：服务端是自签证书时，设 `INSECURE=1` 并填 `PIN`
- **iptables 透明代理**（box / akashaProxy 等）：让加白接口的 IP 走直连，或排除 uid 0
- 命令行：`su -c sh /data/adb/modules/po0fw/po0fw.sh help`

## 原理

读 netd 的默认网络规则找到物理网卡（VPN 不改这条），再用 `SO_BINDTODEVICE` 绑定该网卡发请求，命中 netd 给 root 留的 `oif` 规则，绕过 VPN。`ip monitor` 监听网络变化；token 不进日志，也不出现在进程命令行里。

## 开发

- 构建：`sh pack.sh`，产物在 `dist/`，需要 Go ≥ 1.21 和 zip
- 发版：
  1. 更新 `module/module.prop`、`module/po0fw.sh`（`PO0FW_VER`）、`update.json` 里的版本号
  2. 在 `CHANGELOG.md` 里加一节
  3. 合并到 `main` 后执行：
     ```
     git fetch origin && git tag vX.Y.Z origin/main && git push origin vX.Y.Z
     ```
     Actions 会自动打包并发布 Release。

## 许可

[MIT](LICENSE)
