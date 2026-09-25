#!/system/bin/sh
# 开机完成后启动 po0fw 守护进程
MODDIR=${0%/*}

# KernelSU / APatch：把命令行入口放进 su 的 PATH（不挂载 system，不需要元模块）
if [ -f "$MODDIR/po0fw-cli" ]; then
	for d in /data/adb/ksu/bin /data/adb/ap/bin; do
		[ -d "$d" ] || continue
		cp -f "$MODDIR/po0fw-cli" "$d/po0fw" && chmod 755 "$d/po0fw"
	done
fi

i=0
until [ "$(getprop sys.boot_completed)" = "1" ] || [ $i -ge 120 ]; do
	sleep 2
	i=$((i + 1))
done
sh "$MODDIR/po0fw.sh" start >/dev/null 2>&1
