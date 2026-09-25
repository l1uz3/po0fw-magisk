#!/system/bin/sh
# 卸载时清理配置、日志和命令行入口
MODDIR=${0%/*}
sh "$MODDIR/po0fw.sh" stop >/dev/null 2>&1
rm -rf /data/adb/po0fw
for f in /data/adb/ksu/bin/po0fw /data/adb/ap/bin/po0fw; do
	grep -q '/data/adb/modules/po0fw/po0fw.sh' "$f" 2>/dev/null && rm -f "$f"
done
