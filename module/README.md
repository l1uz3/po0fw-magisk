# po0fw —— 防火墙白名单自动加白（Magisk / KernelSU / APatch 模块）

切网即时 + 定时兜底，自动 POST 加白接口，把本机公网 IP 加进中转机防火墙白名单。
和 MacroDroid 方案相比：

- **不怕代理 VPN**：请求用 root 绑定当前物理网卡（Wi-Fi / 蜂窝）直连，命中 Android netd 给 root 的
  「oif + uid 0」路由规则，绕过 sing-box / Clash 等 VpnService，服务端看到的一定是真实出口 IP，
  不会加白成代理出口。
- **不怕被杀后台**：开机由 Magisk 拉起的 root 守护进程，没有电池优化 / 自启动限制，不需要常驻 App。
- **省电**：用 `ip monitor` 等内核网络事件，平时阻塞休眠；深度睡眠时不唤醒 CPU，醒来后补做逾期的兜底。

## 触发时机

| 触发 | 说明 |
|---|---|
| 切网 | 默认网络变化（Wi-Fi ⇄ 蜂窝、换 Wi-Fi、DHCP 换 IP、断开重连）→ 网络安静 `SETTLE` 秒后加白 |
| 定时兜底 | 距上次成功满 `INTERVAL` 秒（默认 600）→ 捕捉 Wi-Fi 没断但公网 IP 变了、蜂窝静默换 IP |
| 开机 / 改配置 / 重新启用 | 立即加白一次 |
| 手动 | 管理器里点「操作」，或 `su -c po0fw now` |

失败自动重试：网络类错误按 5 → 15 → 30 → 60 → 120 → 300 秒退避；HTTP 4xx（token 错）按兜底间隔再试，不狂刷。

## 安装与配置

1. 管理器里刷入 zip，重启。
2. 填 token（任选一种，改完**无需重启**，几秒内生效）：
   - 终端：`su -c po0fw token 你的token`（或 `su -c po0fw url 完整URL`）
   - MT 管理器等编辑 `/data/adb/po0fw/config.conf`，把 `URL=` 里的「你的token」换掉
   - KernelSU / APatch（或 MMRL）：模块的 WebUI 里填
   - 刷入前直接用 MT 编辑 zip 里的 `config.conf`，安装时会自动带上
3. 在管理器里点「操作」确认一次：看到 `HTTP 200` 就好了。

模块列表的描述会实时显示状态，例如 `[✅ 09:12 已加白 · Wi-Fi]`、`[❌ 09:12 加白失败：HTTP 403]`。

## 命令（需 root）

```
su -c po0fw status          运行状态、当前网络、上次结果
su -c po0fw now             立即加白一次
su -c po0fw token <token>   设置 token 并立即加白
su -c po0fw url <URL>       设置完整 URL 并立即加白
su -c po0fw set INTERVAL 300   改其他配置项
su -c po0fw log [行数|-f]   查看日志
su -c po0fw cert            查看服务端证书、公钥 PIN
su -c po0fw net             查看识别到的默认网络
su -c po0fw start|stop|restart
```

## 配置项（/data/adb/po0fw/config.conf）

| 项 | 默认 | 说明 |
|---|---|---|
| `URL` | — | 加白接口，可写多行同时加白多个 |
| `INTERVAL` | 600 | 定时兜底间隔（秒） |
| `SETTLE` | 3 | 网络变化后等多少秒安静再加白 |
| `BIND_IFACE` | 1 | 1 = 绑定物理网卡直连；0 = 走系统默认路由（开 VPN 时会走代理） |
| `IFACE` | 空 | 手动指定网卡；空 = 自动识别系统默认网络 |
| `INSECURE` / `PIN` | 0 / 空 | 服务端是自签证书时：`INSECURE=1` + `PIN=sha256//…`（`po0fw cert` 可查） |
| `TIMEOUT` | 10 | 单次请求超时（秒） |
| `IPV` | 4 | 只走 IPv4；6 = 只走 IPv6；空 = 自动 |
| `DNS` | 223.5.5.5 119.29.29.29 | 仅 URL 是域名时用，同样经物理网卡直连解析（避开 fake-ip） |
| `OK_REGEX` | 空 | 响应体须匹配该正则才算成功；空 = 只看 HTTP 2xx |
| `DEBUG` | 0 | 1 = 日志记录每个网络事件 |

## 排查

- 日志：`/data/adb/po0fw/po0fw.log`（token 已打码）。
- `证书校验失败`：先 `su -c po0fw cert`。若确认是服务端自签证书，设 `INSECURE=1` 并填上显示的 `PIN`。
- `HTTP 403`：token 不对，或接口拒绝了请求。
- 用的是 iptables 透明代理类模块（box / akashaProxy 等）而不是 VPN 模式：这类代理可能拦截 root
  自身的流量，请在代理规则里让 `124.221.69.228` 直连，或把 uid 0 排除。
- 纯 IPv6 蜂窝（464XLAT）会自动改绑 `v4-rmnet*` 网卡。

## 其他

- `bin/po0req` 是用纯 Go 标准库写的小工具（源码在 `src/`，`sh src/build.sh` 可自行编译），负责绑定网卡、
  按 Android 系统 CA 校验证书、把 token 从日志和进程命令行里藏起来。
- 卸载模块会一并删除 `/data/adb/po0fw`（配置与日志）。
