#!/bin/sh
# 重新编译 po0req（纯 Go 标准库、静态、无 cgo），产物放到 ../bin/<abi>/po0req
# 需要 Go ≥ 1.21：  sh build.sh [版本号]
set -e
cd "$(dirname "$0")/po0req"
VER=${1:-1.0.0}
for t in arm64:arm64-v8a arm:armeabi-v7a amd64:x86_64 386:x86; do
	arch=${t%%:*}; abi=${t#*:}
	mkdir -p "../../bin/$abi"
	CGO_ENABLED=0 GOOS=linux GOARCH=$arch GOARM=7 \
		go build -trimpath -ldflags "-s -w -buildid= -X main.version=$VER" -o "../../bin/$abi/po0req" .
	echo "built bin/$abi/po0req"
done
