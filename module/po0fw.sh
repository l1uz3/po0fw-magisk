#!/system/bin/sh
# shellcheck shell=dash disable=SC3043,SC3045,SC2034
#
# po0fw —— 防火墙白名单自动加白（Magisk / KernelSU / APatch 模块主脚本）
#
# 切网即时加白 + 定时兜底：用 ip monitor 监听网络变化，另每隔 INTERVAL 秒兜底
# POST 一次加白接口。请求用 root 绑定当前物理网卡直连（SO_BINDTODEVICE），
# 绕过代理 / VPN，服务端看到的就是本机真实公网 IP。
#
# 用法：sh po0fw.sh help（平时用管理器里的 WebUI /「操作」按钮即可）

PO0FW_VER=v1.0.1

# ---- 统一交给 busybox ash（standalone 模式）执行，各 root 方案行为一致 ----
if [ -z "$PO0FW_BB" ]; then
	for _bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
		[ -x "$_bb" ] || continue
		export PO0FW_BB="$_bb" ASH_STANDALONE=1
		exec "$_bb" sh "$0" "$@"
	done
	export PO0FW_BB=none
fi

case "$0" in */*) MODDIR=${0%/*} ;; *) MODDIR=. ;; esac
MODDIR=$(cd "$MODDIR" 2>/dev/null && pwd) || MODDIR=/data/adb/modules/po0fw
SELF="$MODDIR/po0fw.sh"
DATA=${PO0FW_DATA:-/data/adb/po0fw}
CONF="$DATA/config.conf"
LOG="$DATA/po0fw.log"
RUN="$DATA/run"
STATE="$RUN/state"
PIDFILE="$RUN/daemon.pid"
FIFO="$RUN/events"
LOCKDIR="$RUN/lock"
REQ=${PO0FW_REQ:-$MODDIR/bin/po0req}
IPBIN=${PO0FW_IP:-/system/bin/ip}
[ -x "$IPBIN" ] || IPBIN=ip
RT_TABLES=${PO0FW_RT_TABLES:-/data/misc/net/rt_tables}
DEFAULT_API='https://124.221.69.228/api/firewall/pgnfw_%s/add'
PLACEHOLDER='你的token'
BASE_DESC='切网即时 + 定时兜底自动 POST 加白接口；root 绑定物理网卡直连、绕过代理 VPN，加白的是本机真实公网 IP'
CR=$(printf '\r')
BOOT_ID=''
read -r BOOT_ID 2>/dev/null </proc/sys/kernel/random/boot_id
DATE_BIN=/system/bin/date # toybox date：bionic 动态链接，时区与系统一致
[ -x "$DATE_BIN" ] || DATE_BIN=date
umask 077

# ================================================================ 基础工具

now_up() { read -r NOW _ </proc/uptime; NOW=${NOW%%.*}; }

log() {
	[ -d "$DATA" ] || mkdir -p "$DATA"
	printf '%s %s\n' "$("$DATE_BIN" '+%F %T')" "$*" >>"$LOG"
	[ "$ECHO" = 1 ] && printf '%s\n' "$*"
	return 0
}

dbg() { [ "$DEBUG" = 1 ] && log "[debug] $*"; return 0; }

log_rotate() {
	local sz
	[ -f "$LOG" ] || return 0
	sz=$(wc -c 2>/dev/null <"$LOG")
	[ "${sz:-0}" -gt $((LOG_MAX_KB * 1024)) ] || return 0
	tail -n 500 "$LOG" >"$LOG.$$" && mv -f "$LOG.$$" "$LOG"
}

trim() { # → _t
	_t=$1
	_t=${_t#"${_t%%[![:space:]]*}"}
	_t=${_t%"${_t##*[![:space:]]}"}
}

is_uint() { case "$1" in '' | *[!0-9]* | ???????????*) return 1 ;; esac; } # 最多 10 位（够放 epoch 秒）

ago() { # epoch → “N 分钟前”
	local d
	d=$(($(date +%s) - $1))
	if [ $d -lt 60 ]; then
		echo "${d} 秒前"
	elif [ $d -lt 3600 ]; then
		echo "$((d / 60)) 分钟前"
	elif [ $d -lt 86400 ]; then
		echo "$((d / 3600)) 小时前"
	else
		echo "$((d / 86400)) 天前"
	fi
}

# ================================================================ 配置

cfg_defaults() {
	URLS='' INTERVAL=600 SETTLE=3 BIND_IFACE=1 IFACE='' INSECURE=0 PIN=''
	DNS='223.5.5.5 119.29.29.29' TIMEOUT=10 METHOD=POST IPV=4 OK_REGEX='' CA_DIRS=''
	DEBUG=0 LOG_MAX_KB=256
}

# 逐行解析 KEY=VALUE（不 source、不 eval 用户内容）
load_config() {
	local line k v
	cfg_defaults
	[ -r "$CONF" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%"$CR"}
		trim "$line"
		line=$_t
		case "$line" in '' | '#'*) continue ;; *=*) ;; *) continue ;; esac
		trim "${line%%=*}"
		k=$_t
		trim "${line#*=}"
		v=$_t
		case "$v" in
		\"*) v=${v#\"} && v=${v%%\"*} ;;
		\'*) v=${v#\'} && v=${v%%\'*} ;;
		*)
			trim "${v%%[[:space:]]#*}"
			v=$_t
			;;
		esac
		case "$k" in
		URL) [ -n "$v" ] && URLS="${URLS:+$URLS
}$v" ;;
		INTERVAL | SETTLE | TIMEOUT | LOG_MAX_KB) is_uint "$v" && [ ${#v} -le 6 ] && eval "$k=\$v" ;;
		BIND_IFACE | INSECURE | DEBUG) case "$v" in 0 | 1) eval "$k=\$v" ;; esac ;;
		IFACE | PIN | DNS | METHOD | IPV | OK_REGEX | CA_DIRS) eval "$k=\$v" ;;
		esac
	done <"$CONF"
	[ "$INTERVAL" -lt 10 ] && INTERVAL=10
	[ "$INTERVAL" -gt 86400 ] && INTERVAL=86400
	[ "$SETTLE" -lt 1 ] && SETTLE=1
	[ "$SETTLE" -gt 30 ] && SETTLE=30
	[ "$TIMEOUT" -lt 3 ] && TIMEOUT=3
	[ "$TIMEOUT" -gt 60 ] && TIMEOUT=60
	[ "$LOG_MAX_KB" -lt 32 ] && LOG_MAX_KB=32
	[ "$LOG_MAX_KB" -gt 10240 ] && LOG_MAX_KB=10240
	return 0
}

conf_sig() { stat -c '%i:%Y:%s' "$CONF" 2>/dev/null; }

url_ok() {
	case "$1" in
	*"$PLACEHOLDER"* | *'"'* | *"'"* | *' '* | *'	'* | *'\'* | *'<'* | *'>'*) return 1 ;;
	http://?* | https://?*) return 0 ;;
	esac
	return 1
}

urls_ready() {
	local u
	[ -n "$URLS" ] || return 1
	while IFS= read -r u; do
		url_ok "$u" || return 1
	done <<EOF
$URLS
EOF
	return 0
}

url_count() {
	local u n=0
	while IFS= read -r u; do [ -n "$u" ] && n=$((n + 1)); done <<EOF
$URLS
EOF
	echo $n
}

# 打码：URL 里 ≥12 字符的路径段只留头 6 尾 3
mask_url() {
	printf '%s\n' "$1" | awk -F/ 'BEGIN { OFS = "/" } { for (i = 4; i <= NF; i++) if (length($i) >= 12) $i = substr($i, 1, 6) "…" substr($i, length($i) - 2); print }'
}

# ================================================================ 网络识别

is_virtual_if() {
	case "$1" in
	'' | lo | tun* | ppp* | ipsec* | wg* | utun* | dummy* | v4-* | clat* | tap* | p2p* | ifb* | gre* | sit* | ip6tnl* | ip_vti*) return 0 ;;
	esac
	return 1
}

# 路由表（名字或编号）→ 网卡名，结果放 _IF
table_to_if() {
	local id=$1 f ix
	_IF=$1
	case "$id" in '' | *[!0-9]*) return 0 ;; esac
	_IF=''
	[ -r "$RT_TABLES" ] && _IF=$(awk -v id="$id" '$1 == id { print $2; exit }' "$RT_TABLES")
	[ -n "$_IF" ] && return 0
	for f in /sys/class/net/*/ifindex; do # netd：表号 = ifindex + 1000
		read -r ix 2>/dev/null <"$f" || continue
		[ $((ix + 1000)) = "$id" ] || continue
		f=${f%/ifindex}
		_IF=${f##*/}
		return 0
	done
}

if_ipv4() { "$IPBIN" -4 -o addr show dev "$1" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "inet") { sub(/\/.*/, "", $(i + 1)); print $(i + 1); exit } }'; }
if_ipv6() { "$IPBIN" -6 -o addr show dev "$1" scope global 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "inet6") { sub(/\/.*/, "", $(i + 1)); print $(i + 1); exit } }'; }

# 识别系统当前默认网络（netd 的 “fwmark 0x0/0xffff” 规则；VPN 不会改它）
# 输出：NET_IF 物理网卡 / NET_BIND 实际绑定的网卡 / NET_IP / NET_GW / NET_FP 指纹
detect_net() {
	NET_IF='' NET_BIND='' NET_IP='' NET_GW='' NET_TB='' NET_HOW='' NET_FP=none _IF=''
	if [ -n "$IFACE" ]; then
		NET_IF=$IFACE NET_TB=$IFACE NET_HOW=手动指定
	else
		# 同一网络可能有多条（如 464XLAT 的 rmnet_data0 + v4-rmnet_data0），取第一个物理网卡
		for NET_TB in $("$IPBIN" -4 rule show 2>/dev/null | awk '/fwmark 0(x0)?\/0xffff( |$)/ && !/uidrange/ { for (i = 1; i < NF; i++) if ($i == "lookup") print $(i + 1) }'); do
			table_to_if "$NET_TB"
			is_virtual_if "$_IF" || break
		done
		NET_IF=$_IF NET_HOW=默认网络规则
		if is_virtual_if "$NET_IF" || [ ! -e "/sys/class/net/$NET_IF" ]; then
			# 兜底：挑一个有 IPv4 默认路由的物理网卡（Wi-Fi 优先）
			NET_IF=$("$IPBIN" -4 route show table all 2>/dev/null | awk '
				$1 == "default" { for (i = 2; i < NF; i++) if ($i == "dev") { d = $(i + 1)
					if (d ~ /^(lo|tun|ppp|ipsec|wg|utun|dummy|v4-|clat|tap|p2p)/) continue
					if (d ~ /^wlan/) { if (!w) w = d } else if (!o) o = d } }
				END { print (w ? w : o) }')
			NET_TB=$NET_IF NET_HOW=默认路由兜底
		fi
	fi
	if [ -z "$NET_IF" ] || [ ! -e "/sys/class/net/$NET_IF" ]; then
		NET_IF=''
		return 1
	fi
	NET_BIND=$NET_IF
	NET_IP=$(if_ipv4 "$NET_IF")
	if [ -z "$NET_IP" ] && [ -e "/sys/class/net/v4-$NET_IF" ]; then
		NET_BIND="v4-$NET_IF" # 纯 IPv6 蜂窝 + 464XLAT：IPv4 走 clat 网卡
		NET_IP=$(if_ipv4 "$NET_BIND")
		NET_GW="clat/$(if_ipv6 "$NET_IF")"
	else
		NET_GW=$("$IPBIN" -4 route show table "$NET_TB" 2>/dev/null | awk '$1 == "default" { for (i = 2; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')
	fi
	if [ -z "$NET_IP" ]; then
		NET_FP="$NET_IF|-|"
		return 1
	fi
	NET_FP="$NET_IF|$NET_IP|$NET_GW"
	return 0
}

net_label() {
	case "$1" in
	wlan* | wifi* | swlan*) echo Wi-Fi ;;
	rmnet* | ccmni* | seth* | pdp* | wwan* | rev_rmnet* | v4-*) echo 蜂窝 ;;
	eth* | usb*) echo 有线 ;;
	*) echo "$1" ;;
	esac
}

fp_desc() { # "wlan0|1.2.3.4|gw" → "Wi-Fi wlan0 1.2.3.4"
	local IFS='|'
	set -f
	# shellcheck disable=SC2086
	set -- $1
	set +f
	if [ -z "$1" ] || [ "$1" = none ]; then
		echo 无网络
		return
	fi
	[ "$2" = - ] && set -- "$1" 无IPv4
	echo "$(net_label "$1") $1 $2"
}

# ================================================================ 状态 / 锁 / 描述

state_load() {
	local l k v
	S_BOOT='' S_OK_UP=0 S_OK_TS=0 S_OK_FP='' S_TRY_TS=0 S_RESULT='' S_FAILS=0 S_CODE=''
	[ -r "$STATE" ] || return 0
	while IFS= read -r l; do
		k=${l%%=*}
		v=${l#*=}
		case "$k" in
		BOOT) S_BOOT=$v ;;
		OK_UP) S_OK_UP=$v ;;
		OK_TS) S_OK_TS=$v ;;
		OK_FP) S_OK_FP=$v ;;
		TRY_TS) S_TRY_TS=$v ;;
		RESULT) S_RESULT=$v ;;
		FAILS) S_FAILS=$v ;;
		CODE) S_CODE=$v ;;
		esac
	done <"$STATE"
	# 重启后 uptime 归零，本次开机之前的时间戳作废
	[ "$S_BOOT" = "$BOOT_ID" ] || S_OK_UP=0 S_OK_FP=''
	is_uint "$S_OK_UP" || S_OK_UP=0
	is_uint "$S_OK_TS" || S_OK_TS=0
	is_uint "$S_FAILS" || S_FAILS=0
}

state_save() {
	mkdir -p "$RUN"
	printf 'BOOT=%s\nOK_UP=%s\nOK_TS=%s\nOK_FP=%s\nTRY_TS=%s\nRESULT=%s\nFAILS=%s\nCODE=%s\n' \
		"$BOOT_ID" "$S_OK_UP" "$S_OK_TS" "$S_OK_FP" "$S_TRY_TS" "$S_RESULT" "$S_FAILS" "$S_CODE" >"$STATE.$$" &&
		mv -f "$STATE.$$" "$STATE"
}

lock() {
	local i=0 p b
	mkdir -p "$RUN"
	while ! mkdir "$LOCKDIR" 2>/dev/null; do
		p='' b=''
		read -r p b 2>/dev/null <"$LOCKDIR/owner"
		# 持锁进程已不在 / 是上次开机留下的 → 清掉
		if { [ -n "$p" ] && ! alive "$p"; } || { [ -n "$b" ] && [ "$b" != "$BOOT_ID" ]; }; then
			rm -rf "$LOCKDIR"
			continue
		fi
		i=$((i + 1))
		[ $i -eq 30 ] && [ -z "$p" ] && rm -rf "$LOCKDIR"
		[ $i -gt 60 ] && return 1
		sleep 1
	done
	echo "$$ $BOOT_ID" >"$LOCKDIR/owner"
}

unlock() { rm -rf "$LOCKDIR"; }

# 在 Magisk / KernelSU 模块列表里显示状态
set_desc() {
	local p="$MODDIR/module.prop" d
	[ -f "$p" ] || return 0
	d="description=[$1] $BASE_DESC"
	grep -qxF -- "$d" "$p" 2>/dev/null && return 0
	awk -v d="$d" '/^description=/ { print d; next } { print }' "$p" >"$p.$$" &&
		chmod 644 "$p.$$" && mv -f "$p.$$" "$p"
}

# ================================================================ 加白请求

# post_one URL → R_CODE R_MS R_LOCAL R_TLS R_BODY R_ERR R_LOC R_CLASS
post_one() {
	local url=$1 out l
	R_CODE=0 R_MS='' R_LOCAL='' R_TLS='' R_BODY='' R_ERR='' R_LOC=''
	set -- -method "$METHOD" -timeout "${TIMEOUT}s" -max 200 -dns "$DNS"
	[ "$BIND_IFACE" = 1 ] && [ -n "$NET_BIND" ] && set -- "$@" -iface "$NET_BIND"
	[ "$INSECURE" = 1 ] && set -- "$@" -insecure
	[ -n "$PIN" ] && set -- "$@" -pin "$PIN"
	[ -n "$CA_DIRS" ] && set -- "$@" -cadir "$CA_DIRS"
	case "$IPV" in 4) set -- "$@" -4 ;; 6) set -- "$@" -6 ;; esac
	# URL（含 token）走环境变量，不出现在进程命令行里
	out=$(PO0REQ_URL=$url "$REQ" "$@" </dev/null 2>&1)
	R_EXIT=$?
	while IFS= read -r l; do
		case "$l" in
		code=*) R_CODE=${l#code=} ;;
		ms=*) R_MS=${l#ms=} ;;
		local=*) R_LOCAL=${l#local=} ;;
		tls=*) R_TLS=${l#tls=} ;;
		location=*) R_LOC=${l#location=} ;;
		body=*) R_BODY=${l#body=} ;;
		err=*) R_ERR=${l#err=} ;;
		?*) R_ERR="${R_ERR:+$R_ERR; }$l" ;;
		esac
	done <<EOF
$out
EOF
	case $R_EXIT in
	0) R_CLASS=ok ;;
	1) R_CLASS=arg ;;
	2) R_CLASS=net ;;
	3) R_CLASS=tls ;;
	4) R_CLASS=4xx ;;
	5) R_CLASS=http ;;
	*)
		R_CLASS='exec'
		R_ERR="po0req 无法运行（退出码 $R_EXIT）${R_ERR:+：$R_ERR}"
		;;
	esac
	if [ $R_CLASS = ok ] && [ -n "$OK_REGEX" ] && ! printf '%s\n' "$R_BODY" | grep -Eq -- "$OK_REGEX"; then
		R_CLASS=body
	fi
}

result_text() {
	case $R_CLASS in
	ok) echo "HTTP $R_CODE · ${R_MS}ms${R_BODY:+ · $R_BODY}" ;;
	4xx) echo "HTTP $R_CODE（token 不对 / 无权限？）${R_BODY:+ · $R_BODY}" ;;
	http) echo "HTTP $R_CODE${R_LOC:+ → $R_LOC}${R_BODY:+ · $R_BODY}" ;;
	body) echo "HTTP $R_CODE 但响应不匹配 OK_REGEX · $R_BODY" ;;
	tls) echo "TLS 失败：$R_ERR（自签证书：WebUI 点「证书信息」查看后配置 INSECURE + PIN）" ;;
	net) echo "网络错误：$R_ERR" ;;
	*) echo "$R_ERR" ;;
	esac
}

result_short() {
	case $R_CLASS in
	ok) echo "HTTP $R_CODE" ;;
	4xx | http | body) echo "HTTP $R_CODE" ;;
	tls) echo "证书校验失败" ;;
	net) echo "网络错误" ;;
	arg) echo "参数错误" ;;
	*) echo "po0req 异常" ;;
	esac
}

# fire 原因 → 0 成功 / 1 失败（R_CLASS 为首个失败类型）/ 2 未配置或无网络
fire() {
	local reason=$1 u ok=1 cls='' n=0 total tag short
	load_config
	if ! urls_ready; then
		set_desc "⚠️ 未配置加白 URL"
		log "[$reason] 未配置加白 URL：在 WebUI 里填 token，或编辑 $CONF"
		return 2
	fi
	if [ ! -x "$REQ" ]; then
		set_desc "❌ 缺少 po0req"
		log "[$reason] 找不到可执行的 $REQ，请重新刷入模块"
		R_CLASS='exec'
		return 1
	fi
	lock || {
		log "[$reason] 等锁超时，跳过本次"
		R_CLASS=lock
		return 1
	}
	detect_net
	if [ -z "$NET_IP" ]; then
		unlock
		log "[$reason] 没有可用的 IPv4 网络（$(fp_desc "$NET_FP")），等网络连上再加白"
		set_desc "… 等待网络"
		return 2
	fi
	state_load
	total=$(url_count)
	while IFS= read -r u; do
		[ -n "$u" ] || continue
		n=$((n + 1))
		post_one "$u"
		tag=''
		[ "$total" -gt 1 ] && tag=" ($n/$total $(mask_url "$u"))"
		log "[$reason]$tag $(net_label "$NET_IF") $NET_BIND${R_LOCAL:+ ${R_LOCAL%:*}} → $(result_text)"
		if [ $R_CLASS != ok ]; then
			ok=0
			[ -n "$cls" ] || { cls=$R_CLASS && short=$(result_short); }
		fi
	done <<EOF
$URLS
EOF
	now_up
	S_TRY_TS=$(date +%s)
	S_CODE=$R_CODE
	if [ $ok = 1 ]; then
		S_OK_UP=$NOW S_OK_TS=$S_TRY_TS S_OK_FP=$NET_FP S_FAILS=0 S_RESULT=ok
	else
		S_FAILS=$((S_FAILS + 1)) S_RESULT=$short
	fi
	state_save
	unlock
	if [ $ok = 1 ]; then
		set_desc "✅ $("$DATE_BIN" '+%H:%M') 已加白 · $(net_label "$NET_IF")"
	else
		set_desc "❌ $("$DATE_BIN" '+%H:%M') 加白失败：$short"
	fi
	log_rotate
	[ $ok = 1 ] && return 0
	R_CLASS=$cls
	return 1
}

# ================================================================ 守护进程

alive() { # pid 存在且不是僵尸
	local s
	read -r s 2>/dev/null <"/proc/$1/stat" || return 1
	s=${s##*) }
	case "$s" in Z* | X*) return 1 ;; esac
	return 0
}

daemon_pid() {
	local p='' b='' c
	read -r p b 2>/dev/null <"$PIDFILE" || return 1
	[ -n "$p" ] && [ "$b" = "$BOOT_ID" ] && alive "$p" || return 1
	c=$(tr '\0' ' ' 2>/dev/null <"/proc/$p/cmdline")
	case "$c" in *po0fw.sh*daemon*) echo "$p" ;; *) return 1 ;; esac
}

# 结束上一个守护进程组里残留的子进程（主循环被 kill -9 时 watcher 等会成孤儿）
kill_stale_group() {
	local pg=$1 f l r c n=0
	[ -n "$pg" ] || return 0
	for f in /proc/[0-9]*/stat; do
		read -r l 2>/dev/null <"$f" || continue
		r=${l##*) }
		# shellcheck disable=SC2086
		set -- $r
		[ "$3" = "$pg" ] || continue
		f=${f%/stat}
		c=$(tr '\0' ' ' 2>/dev/null <"$f/cmdline")
		case "$c" in *po0fw.sh* | *" monitor"* | *inotifyd*)
			kill -KILL "${f#/proc/}" 2>/dev/null && n=$((n + 1)) ;;
		esac
	done
	[ $n -gt 0 ] && log "清理了上次残留的 $n 个进程"
	return 0
}

is_group_leader() {
	local s
	read -r s <"/proc/$$/stat" || return 1
	s=${s##*) }
	# shellcheck disable=SC2086
	set -- $s
	[ "$3" = "$$" ]
}

# 网络事件监听：ip monitor 的输出 → 事件管道（fd 3）
mon_parse() {
	local l
	while IFS= read -r l; do
		case "$l" in
		*lladdr* | *REACHABLE* | *STALE* | *DELAY* | *PROBE* | *FAILED* | *INCOMPLETE* | *NOARP* | *PERMANENT*) continue ;;
		Deleted*) echo net ;;
		[0-9]*": "*" inet "*)
			# shellcheck disable=SC2086
			set -- $l
			echo "addr $2"
			;;
		*) echo net ;;
		esac
	done
}

mon_run() {
	case $1 in
	1) set -- -4 -o monitor address route rule ;;
	2) set -- -4 -o monitor address route ;;
	*) set -- -4 -o monitor ;;
	esac
	"$IPBIN" "$@" 2>/dev/null </dev/null | mon_parse >&3
}

watcher() {
	local v=1 t0
	set -f
	while :; do
		now_up
		t0=$NOW
		echo "ok v$v" >"$RUN/watcher"
		mon_run $v
		now_up
		if [ $((NOW - t0)) -ge 10 ]; then
			sleep 2 # 正常跑了一阵后退出：原样重启
		else
			v=$((v + 1)) # 秒退：换一种参数组合
			if [ $v -gt 3 ]; then
				echo down >"$RUN/watcher"
				log "ip monitor 不可用，改为每 5 秒轮询网络状态"
				sleep 600
				v=1
			fi
		fi
	done
}

# 配置文件 / 模块开关（disable、remove）变化 → 立即唤醒主循环（busybox inotifyd）
# 没有 inotifyd 时秒退，改由主循环每分钟检查一次
fswatcher() {
	local t0
	while :; do
		now_up
		t0=$NOW
		inotifyd - "$DATA:wymnd" "$MODDIR:nymd" 2>/dev/null </dev/null | while IFS= read -r l; do
			case "$l" in *"	config.conf" | *"	disable" | *"	remove") echo cfg ;; esac
		done >&3
		now_up
		[ $((NOW - t0)) -ge 10 ] || return 0
		sleep 2
	done
}

# 等事件（最多 $1 秒）；收到事件后去抖：直到 SETTLE 秒内再无新事件（最多 15 秒）
wait_event() {
	local msg t0
	IFS= read -r -t "$1" msg <&3 || return 0
	now_up
	t0=$NOW
	handle_msg "$msg"
	while IFS= read -r -t "$SETTLE" msg <&3; do
		handle_msg "$msg"
		now_up
		[ $((NOW - t0)) -ge 15 ] && break
	done
	return 0
}

handle_msg() {
	case "$1" in addr\ *) FORCE_IF="$FORCE_IF ${1#addr }" ;; esac
	dbg "事件：$1"
}

calc_timeout() {
	local t w='' d
	read -r w 2>/dev/null <"$RUN/watcher"
	case "$w" in ok*) t=60 ;; *) t=5 ;; esac
	if [ "$CONFIGURED" = 1 ] && [ -n "$NET_IP" ]; then
		if [ "$PENDING" = 1 ]; then
			d=$((NEXT_TRY - NOW))
		else
			d=$((S_OK_UP + INTERVAL - NOW))
		fi
		[ $d -lt $t ] && t=$d
	fi
	[ $t -lt 1 ] && t=1
	echo $t
}

backoff() {
	local b
	case "$R_CLASS" in
	4xx | arg | body) b=$INTERVAL ;; # 配置类错误：别狂刷，按兜底间隔再试（切网会立刻重试）
	*) case $DFAILS in 1) b=5 ;; 2) b=15 ;; 3) b=30 ;; 4) b=60 ;; 5) b=120 ;; *) b=300 ;; esac ;;
	esac
	[ "$b" -gt "$INTERVAL" ] && b=$INTERVAL
	echo "$b"
}

set_pending() {
	PENDING=1 P_REASON=$1 NEXT_TRY=0 PSINCE=$NOW
}

check_ready() {
	if [ ! -x "$REQ" ]; then
		CONFIGURED=0
		set_desc "❌ 缺少 po0req"
		log "找不到可执行的 $REQ，请重新刷入模块"
	elif urls_ready; then
		CONFIGURED=1
	else
		CONFIGURED=0
		set_desc "⚠️ 未配置加白 URL"
		log "未配置加白 URL：在 WebUI 里填 token，或编辑 $CONF（改完自动生效）"
	fi
}

daemon_exit() {
	trap - EXIT TERM INT HUP
	rm -f "$PIDFILE" "$FIFO" "$RUN/watcher"
	is_group_leader && kill -TERM 0 2>/dev/null # 连带结束 watcher / ip monitor
}

daemon_main() {
	local p rc b
	if p=$(daemon_pid) && [ "$p" != "$$" ]; then
		echo "已有守护进程在运行（pid $p）"
		exit 0
	fi
	mkdir -p "$RUN" || exit 1
	p='' b=''
	read -r p b 2>/dev/null <"$PIDFILE"
	[ -n "$p" ] && [ "$p" != "$$" ] && [ "$b" = "$BOOT_ID" ] && kill_stale_group "$p"
	echo "$$ $BOOT_ID" >"$PIDFILE"
	rm -rf "$LOCKDIR"
	trap daemon_exit EXIT
	trap 'exit 0' TERM INT HUP
	rm -f "$FIFO"
	mkfifo "$FIFO" || {
		log "创建事件管道失败，守护进程退出"
		exit 1
	}
	exec 3<>"$FIFO"
	load_config
	CONF_SIG=$(conf_sig)
	log "守护进程启动 $PO0FW_VER（pid $$）：切网即时加白 + 每 ${INTERVAL}s 兜底，绑定物理网卡=$BIND_IFACE"
	check_ready
	watcher &
	fswatcher &
	now_up
	PENDING=0 SEEN_FP='' FORCE_IF='' PAUSED=0 DFAILS=0
	set_pending 开机
	while :; do
		now_up
		# ---- 模块在管理器里被移除 / 停用
		if [ -e "$MODDIR/remove" ]; then
			log "模块已标记为移除，守护进程退出"
			exit 0
		fi
		if [ -e "$MODDIR/disable" ]; then
			if [ $PAUSED = 0 ]; then
				PAUSED=1
				log "模块已停用，暂停加白"
				set_desc "⏸ 已停用"
			fi
			wait_event 30
			continue
		fi
		if [ $PAUSED = 1 ]; then
			PAUSED=0
			log "模块已重新启用"
			set_pending 启用
		fi
		# ---- 配置文件变化（改完即生效）
		p=$(conf_sig)
		if [ "$p" != "$CONF_SIG" ]; then
			CONF_SIG=$p
			load_config
			check_ready
			log "配置已更新"
			set_pending 配置
			DFAILS=0
		fi
		# ---- 网络变化
		detect_net
		if [ "$NET_FP" != "$SEEN_FP" ]; then
			[ -n "$SEEN_FP" ] && log "网络变化：$(fp_desc "$SEEN_FP") → $(fp_desc "$NET_FP")"
			SEEN_FP=$NET_FP
			[ -z "$NET_IP" ] && [ "$CONFIGURED" = 1 ] && set_desc "… 等待网络"
			if [ -n "$NET_IP" ]; then
				[ "$P_REASON" = 开机 ] && [ $PENDING = 1 ] || set_pending 切网
				DFAILS=0
			fi
		elif [ -n "$FORCE_IF" ] && [ -n "$NET_IP" ]; then
			case " $FORCE_IF " in *" $NET_IF "* | *" $NET_BIND "*)
				dbg "默认网卡 $NET_IF 重新获取了地址"
				set_pending 切网
				DFAILS=0
				;;
			esac
		fi
		FORCE_IF=''
		# ---- 定时兜底；手动「立即加白」已加白过当前网络则不重复
		state_load
		if [ $PENDING = 1 ] && [ "$S_OK_FP" = "$NET_FP" ] && [ "$S_OK_UP" -gt "$PSINCE" ]; then
			PENDING=0
		fi
		if [ $PENDING = 0 ] && [ -n "$NET_IP" ] && [ $((NOW - S_OK_UP)) -ge "$INTERVAL" ]; then
			set_pending 定时
		fi
		# ---- 执行
		if [ $PENDING = 1 ] && [ "$CONFIGURED" = 1 ] && [ -n "$NET_IP" ] && [ "$NOW" -ge "$NEXT_TRY" ]; then
			fire "$P_REASON"
			rc=$?
			now_up
			case $rc in
			0)
				PENDING=0
				DFAILS=0
				;;
			1)
				DFAILS=$((DFAILS + 1))
				b=$(backoff)
				NEXT_TRY=$((NOW + b))
				P_REASON=重试
				log "  → ${b} 秒后重试"
				;;
			*) NEXT_TRY=$((NOW + 60)) ;;
			esac
			state_load
		fi
		wait_event "$(calc_timeout)"
	done
}

# ================================================================ 命令

cmd_start() {
	local p
	if p=$(daemon_pid); then
		echo "守护进程已在运行（pid $p）"
		return 0
	fi
	mkdir -p "$RUN"
	if [ "$PO0FW_BB" != none ]; then
		setsid "$PO0FW_BB" sh "$SELF" daemon </dev/null >/dev/null 2>"$RUN/daemon.err" &
	else
		setsid sh "$SELF" daemon </dev/null >/dev/null 2>"$RUN/daemon.err" &
	fi
	sleep 1
	if p=$(daemon_pid); then
		echo "守护进程已启动（pid $p）"
	else
		echo "守护进程启动失败：$(tail -n 3 "$RUN/daemon.err" 2>/dev/null)"
		return 1
	fi
}

cmd_stop() {
	local p b i=0
	if ! p=$(daemon_pid); then
		p='' b=''
		read -r p b 2>/dev/null <"$PIDFILE"
		[ "$b" = "$BOOT_ID" ] && kill_stale_group "$p"
		echo "守护进程未运行"
		rm -f "$PIDFILE"
		return 0
	fi
	kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
	while alive "$p" && [ $i -lt 5 ]; do
		sleep 1
		i=$((i + 1))
	done
	kill -KILL "-$p" 2>/dev/null
	rm -f "$PIDFILE" "$RUN/watcher"
	set_desc "⏹ 守护进程已停止"
	echo "守护进程已停止"
}

cmd_status() {
	local p w='' u
	load_config
	state_load
	detect_net
	echo "po0fw $PO0FW_VER"
	if p=$(daemon_pid); then
		read -r w 2>/dev/null <"$RUN/watcher"
		case "$w" in ok*) w="事件监听正常" ;; down) w="ip monitor 不可用，轮询中" ;; *) w="启动中" ;; esac
		echo "守护进程：运行中（pid $p，$w）"
	else
		echo "守护进程：未运行（点「操作」或重启手机即可启动）"
	fi
	[ -e "$MODDIR/disable" ] && echo "模块状态：已在管理器中停用，暂停加白"
	if urls_ready; then
		echo "加白接口："
		while IFS= read -r u; do echo "  $(mask_url "$u")"; done <<EOF
$URLS
EOF
	else
		echo "加白接口：⚠️ 未配置 —— 在 WebUI 里填 token，或编辑 $CONF"
	fi
	if [ -n "$NET_IP" ]; then
		echo "当前网络：$(fp_desc "$NET_FP")${NET_GW:+，网关 $NET_GW}（$NET_HOW）"
	else
		echo "当前网络：$(fp_desc "$NET_FP")"
	fi
	if [ "$BIND_IFACE" = 1 ]; then
		[ -n "$NET_BIND" ] && echo "请求出口：绑定 $NET_BIND 直连（绕过代理 / VPN）"
	else
		echo "请求出口：走系统默认路由（BIND_IFACE=0，开着 VPN 时可能加白成代理出口 IP）"
	fi
	if [ "$S_OK_TS" -gt 0 ]; then
		echo "上次成功：$("$DATE_BIN" -d "@$S_OK_TS" '+%F %T' 2>/dev/null)（$(ago "$S_OK_TS")）"
	else
		echo "上次成功：暂无"
	fi
	[ "$S_FAILS" -gt 0 ] && echo "最近失败：连续 $S_FAILS 次（$S_RESULT），详见日志 $LOG"
	echo "触发方式：网络变化后约 ${SETTLE} 秒加白 + 每 ${INTERVAL} 秒兜底"
	return 0
}

cmd_now() {
	local rc
	ECHO=1
	fire 手动
	rc=$?
	daemon_pid >/dev/null || cmd_start >/dev/null
	return $rc
}

cmd_set_url() {
	local u=$1
	if ! url_ok "$u"; then
		echo "URL 不对：需以 http(s):// 开头，不能含空格 / 引号，并且已替换「你的token」"
		return 1
	fi
	mkdir -p "$DATA"
	[ -f "$CONF" ] || cp "$MODDIR/config.conf" "$CONF"
	awk -v u="$u" '
		/^[[:space:]]*URL[[:space:]]*=/ { if (!done) { print "URL=\"" u "\""; done = 1 } next }
		{ print }
		END { if (!done) print "URL=\"" u "\"" }' "$CONF" >"$CONF.$$" &&
		mv -f "$CONF.$$" "$CONF" && chmod 600 "$CONF"
	echo "已保存：$(mask_url "$u")"
	cmd_now
}

cmd_token() {
	local t=${1#pgnfw_}
	case "$t" in '' | *[!A-Za-z0-9_-]*)
		echo "用法：po0fw.sh token <你的token>（只能含字母、数字、_、-）"
		return 1
		;;
	esac
	# shellcheck disable=SC2059
	cmd_set_url "$(printf "$DEFAULT_API" "$t")"
}

cmd_set() {
	local k=$1 v=$2
	case "$k" in
	INTERVAL | SETTLE | TIMEOUT) is_uint "$v" && [ ${#v} -le 6 ] || {
		echo "$k 需要是整数（秒）"
		return 1
	} ;;
	BIND_IFACE | INSECURE | DEBUG) case "$v" in 0 | 1) ;; *)
		echo "$k 只能是 0 或 1"
		return 1
		;;
	esac ;;
	IFACE | PIN | IPV | DNS) case "$v" in *'"'* | *"'"* | *'\'* | *'`'* | *'$'*)
		echo "值里不能有引号、反斜杠、\$ 或反引号"
		return 1
		;;
	esac ;;
	*)
		echo "可设置：INTERVAL SETTLE TIMEOUT BIND_IFACE INSECURE PIN IFACE IPV DNS DEBUG（URL 用 po0fw.sh url / token）"
		return 1
		;;
	esac
	mkdir -p "$DATA"
	[ -f "$CONF" ] || cp "$MODDIR/config.conf" "$CONF"
	awk -v k="$k" -v v="$v" '
		BEGIN { re = "^[[:space:]]*" k "[[:space:]]*=" }
		$0 ~ re { if (!done) { print k "=\"" v "\""; done = 1 } next }
		{ print }
		END { if (!done) print k "=\"" v "\"" }' "$CONF" >"$CONF.$$" &&
		mv -f "$CONF.$$" "$CONF" && chmod 600 "$CONF"
	echo "已设置 $k=$v，守护进程几秒内生效"
}

cmd_cert() {
	local u
	load_config
	if ! urls_ready; then
		echo "未配置加白 URL"
		return 1
	fi
	detect_net
	u=${URLS%%
*}
	set -- -cert -timeout "${TIMEOUT}s" -dns "$DNS"
	[ "$BIND_IFACE" = 1 ] && [ -n "$NET_BIND" ] && set -- "$@" -iface "$NET_BIND"
	[ -n "$CA_DIRS" ] && set -- "$@" -cadir "$CA_DIRS"
	case "$IPV" in 4) set -- "$@" -4 ;; 6) set -- "$@" -6 ;; esac
	echo "服务端：$(mask_url "$u")"
	PO0REQ_URL=$u "$REQ" "$@" </dev/null
}

cmd_net() {
	load_config
	detect_net
	echo "识别方式：$NET_HOW（路由表 ${NET_TB:-?}）"
	echo "物理网卡：${NET_IF:-无}  绑定：${NET_BIND:-无}  IPv4：${NET_IP:-无}  网关：${NET_GW:-无}"
	echo "指纹：$NET_FP"
	echo "---- ip rule（默认网络 / VPN 相关）"
	"$IPBIN" -4 rule show 2>/dev/null | grep -E 'fwmark 0(x0)?/0xffff|uidrange|unreachable' | head -n 20
	echo "---- 各表默认路由"
	"$IPBIN" -4 route show table all 2>/dev/null | grep '^default' | head -n 20
}

cmd_action() {
	local p
	ECHO=1
	echo "━━━━ po0fw 防火墙自动加白 $PO0FW_VER ━━━━"
	load_config
	if ! urls_ready; then
		cat <<EOF
⚠️ 还没配置加白 URL，任选一种方式：
 ① 打开本模块的 WebUI，填 token 后点「保存并加白」
 ② 用 MT 管理器等打开
    $CONF
    把 URL= 里的「你的token」换成自己的，保存
改完不用重启：守护进程 1 分钟内自动生效，或再点一次「操作」。
EOF
		daemon_pid >/dev/null || cmd_start
		return 0
	fi
	detect_net
	echo "网络：$(fp_desc "$NET_FP")"
	echo ""
	echo "▶ 立即加白……"
	fire 手动
	echo ""
	if p=$(daemon_pid); then
		echo "守护进程运行中（pid $p）：切网即时 + 每 ${INTERVAL}s 兜底"
	else
		cmd_start
	fi
	echo ""
	echo "最近记录（WebUI 里点「查看日志」看更多）："
	tail -n 6 "$LOG" 2>/dev/null | cut -c 12-
}

cmd_help() {
	cat <<EOF
po0fw $PO0FW_VER —— 防火墙白名单自动加白
平时用管理器里的 WebUI 或「操作」按钮即可；以下命令供排查用（需 root）：
  su -c sh $SELF <命令>

  status                运行状态、当前网络、上次结果
  now                   立即加白一次
  token <token>         设置 token（自动拼成默认加白 URL）并立即加白
  url <URL>             设置完整加白 URL 并立即加白
  log [行数|-f]         查看日志（默认 30 行，-f 持续跟踪）
  set <项> <值>          改其他配置，如 set INTERVAL 300
  cert                  查看服务端证书与公钥 PIN（排查 TLS 问题）
  net                   查看识别到的默认网络（排查用）
  start|stop|restart

配置：$CONF（改完保存即可，1 分钟内自动生效）
EOF
}

# ================================================================ 入口

[ "$(id -u)" = 0 ] || {
	echo "需要 root：su -c sh $SELF $*"
	exit 1
}
mkdir -p "$DATA"

case "$1" in
daemon) daemon_main ;;
start) cmd_start ;;
stop) cmd_stop ;;
restart)
	cmd_stop >/dev/null
	cmd_start
	;;
status | '') cmd_status ;;
now) cmd_now ;;
url) cmd_set_url "$2" ;;
token) cmd_token "$2" ;;
set) cmd_set "$2" "$3" ;;
cert) cmd_cert ;;
net) cmd_net ;;
action) cmd_action ;;
log)
	case "$2" in
	-f) tail -n 20 -f "$LOG" ;;
	*) tail -n "${2:-30}" "$LOG" 2>/dev/null || echo "暂无日志" ;;
	esac
	;;
help | -h | --help) cmd_help ;;
*)
	cmd_help
	exit 1
	;;
esac
