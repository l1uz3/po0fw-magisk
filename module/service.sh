#!/system/bin/sh
# 开机完成后启动 po0fw 守护进程
MODDIR=${0%/*}
i=0
until [ "$(getprop sys.boot_completed)" = "1" ] || [ $i -ge 120 ]; do
	sleep 2
	i=$((i + 1))
done
sh "$MODDIR/po0fw.sh" start >/dev/null 2>&1
