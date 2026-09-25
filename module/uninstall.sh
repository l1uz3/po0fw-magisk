#!/system/bin/sh
# 卸载时清理配置与日志
MODDIR=${0%/*}
sh "$MODDIR/po0fw.sh" stop >/dev/null 2>&1
rm -rf /data/adb/po0fw
