#!/bin/sh
# 打包模块：编译 po0req（arm64-v8a、armeabi-v7a）并生成 dist/po0fw-<版本>.zip
# 需要 Go ≥ 1.21 和 zip：  sh pack.sh
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

VER=$(sed -n 's/^version=//p' module/module.prop)
[ -n "$VER" ] || { echo "module/module.prop 里没有 version" >&2; exit 1; }

STAGE=$ROOT/dist/stage
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a module/. "$STAGE/"
rm -rf "$STAGE/bin"

cd "$STAGE/src/po0req"
for t in arm64:arm64-v8a arm:armeabi-v7a; do
	arch=${t%%:*}; abi=${t#*:}
	mkdir -p "$STAGE/bin/$abi"
	CGO_ENABLED=0 GOOS=linux GOARCH=$arch GOARM=7 \
		go build -trimpath -ldflags "-s -w -buildid= -X main.version=${VER#v}" -o "$STAGE/bin/$abi/po0req" .
	echo "built bin/$abi/po0req"
done

OUT=$ROOT/dist/po0fw-$VER.zip
rm -f "$OUT"
cd "$STAGE"
zip -qr9 -X "$OUT" META-INF module.prop customize.sh service.sh action.sh uninstall.sh \
	po0fw.sh config.conf system bin webroot src README.md
rm -rf "$STAGE"
echo "$OUT"
