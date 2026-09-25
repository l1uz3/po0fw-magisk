# shellcheck shell=ash disable=SC2034
# po0fw 安装脚本（由 Magisk / KernelSU / APatch 的安装器 source 执行）
SKIPUNZIP=0
DATADIR=/data/adb/po0fw
PLACEHOLDER='你的token'

case "$ARCH" in
arm64) ABIDIR=arm64-v8a ;;
arm) ABIDIR=armeabi-v7a ;;
x64) ABIDIR=x86_64 ;;
x86) ABIDIR=x86 ;;
*) abort "! 不支持的架构：$ARCH" ;;
esac

ui_print "- 架构：$ARCH（$ABIDIR）"
[ -f "$MODPATH/bin/$ABIDIR/po0req" ] ||
	abort "! 模块包里没有 $ABIDIR 的 po0req，可用 src/build.sh 自行编译后重新打包"
mv -f "$MODPATH/bin/$ABIDIR/po0req" "$MODPATH/bin/po0req"
for d in "$MODPATH"/bin/*/; do rm -rf "$d"; done
rm -rf "$MODPATH/src"

# 命令行入口 po0fw：
#   Magisk 自带 systemless 挂载 → 放在 system/bin
#   KernelSU / APatch 挂载要靠元模块 → 不带 system/，开机时由 service.sh
#   放进 su 自带的 PATH（/data/adb/ksu/bin 或 /data/adb/ap/bin），不需要元模块
if [ "$KSU" = true ] || [ "$APATCH" = true ]; then
	mv -f "$MODPATH/system/bin/po0fw" "$MODPATH/po0fw-cli"
	rm -rf "$MODPATH/system"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/po0req" 0 0 0755
set_perm "$MODPATH/po0fw.sh" 0 0 0755
if [ -f "$MODPATH/po0fw-cli" ]; then
	set_perm "$MODPATH/po0fw-cli" 0 0 0755
else
	set_perm "$MODPATH/system/bin/po0fw" 0 2000 0755
fi

if ! "$MODPATH/bin/po0req" -version >/dev/null 2>&1; then
	abort "! po0req 无法在本机运行"
fi
ui_print "- $("$MODPATH/bin/po0req" -version)"

# ---- 配置：放在 /data/adb/po0fw，更新模块不会覆盖
mkdir -p "$DATADIR"
pkg_url=$(sed -n 's/^[[:space:]]*URL[[:space:]]*=[[:space:]]*//p' "$MODPATH/config.conf" | head -n 1)
if [ -f "$DATADIR/config.conf" ]; then
	case "$pkg_url" in
	*"$PLACEHOLDER"*)
		ui_print "- 保留已有配置：$DATADIR/config.conf"
		;;
	*)
		# 刷入前在 zip 里改过 config.conf（填了 token）→ 用包里的，旧的备份
		cp -f "$DATADIR/config.conf" "$DATADIR/config.conf.bak"
		cp -f "$MODPATH/config.conf" "$DATADIR/config.conf"
		ui_print "- 已使用包内配置（旧配置备份为 config.conf.bak）"
		;;
	esac
else
	cp -f "$MODPATH/config.conf" "$DATADIR/config.conf"
	ui_print "- 已生成配置：$DATADIR/config.conf"
fi
chmod 700 "$DATADIR"
chmod 600 "$DATADIR/config.conf"

if grep -q "$PLACEHOLDER" "$DATADIR/config.conf"; then
	ui_print " "
	ui_print "! 还没填 token。重启后任选一种方式："
	ui_print "  ① MT 管理器编辑 $DATADIR/config.conf"
	ui_print "     把「你的token」换成自己的"
	ui_print "  ② 终端执行：su -c po0fw token 你的token"
	ui_print "  改完即生效，无需再重启"
else
	ui_print "- 加白 URL 已配置"
fi
ui_print " "
ui_print "- 重启后生效：切网即时加白 + 每 10 分钟兜底"
ui_print "- 管理器里点「操作」可立即加白并查看结果"
