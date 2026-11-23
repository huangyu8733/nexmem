GO ?= go
PROTOC ?= protoc
BUF ?= buf
BIN ?= bin
PROTOS := $(wildcard core/proto/*.proto)
FFI_EXT ?= dll
FFI_LIB ?= ../bin/nexmem.$(FFI_EXT)
ZIG ?= .toolchain/zig/zig-x86_64-windows-0.17.1/zig.exe

.PHONY: help tidy build lint test fmt clean p0-build proto proto-lint contract contracttest dmtest statetest filetest s3test directory offlinetest grouptest groupfetchtest p3gatetest p2gatetest ffi ffitest linux-shared linux-dist debpacktest webd webdtest webdist keystoretest searchtest backuptest relay relaytest pushtest

help:
	@echo "make tidy      整理依赖"
	@echo "make build     编译 P0 二进制到 bin/"
	@echo "make proto     由 core/proto/*.proto 生成 core/api/v1/*.pb.go"
	@echo "make proto-lint buf lint 校验 proto 规范（buf.yaml）"
	@echo "make contract  由 gateway 注册表生成 core/contract/api.json"
	@echo "make contracttest 同一批 case 驱动 Go gateway 与 Dart 信封编解码（X-03）"
	@echo "make dmtest    单聊直连 1000 条文本收发验收（P1-11）"
	@echo "make statetest 断网 10s 内 degraded、重连 15s 内 online 验收（P1-12）"
	@echo "make filetest  1 GiB 文件分片加密传输与进度节流验收（P2-04）"
	@echo "make s3test    S3 兼容后端 PUT/HEAD/GET/LIST/presign 验收（P3-02）"
	@echo "make directory 构建索引服务二进制到 bin/（P3-04）"
	@echo "make offlinetest 对端离线时票据上传与解密验收（P3-06）"
	@echo "make grouptest  50 人群 GossipSub 在线广播覆盖率验收（P4-01）"
	@echo "make groupfetchtest 真实 S3 下群盘离线补齐率与轮换隔离验收（P4-06/P4 门禁）"
	@echo "make ffi       构建桌面 c-shared 产物到 bin/（P1-09）"
	@echo "make ffitest   加载 DLL 完成请求往返与内存稳定性验收（P1-09，Windows）"
	@echo "make linux-shared 交叉编译 Linux x86-64 c-shared 产物（P1-14，需 zig）"
	@echo "make linux-dist 在 Linux 宿主构建 .deb/AppImage 发行包（P6-09）"
	@echo "make debpacktest .deb 打包结构（ar/control/data）与确定性回归（P6-09）"
	@echo "make android-aar 由 core/mobile 生成 Android AAR（P1-07，需 NDK）"
	@echo "make ios-xcframework 由 core/mobile 生成 iOS XCFramework（P1-08，需 macOS）"
	@echo "make webd      构建自托管 Web 网关到 bin/（P1-15）"
	@echo "make webdtest  WebSocket 通道、令牌门禁与事件广播验收（P1-15）"
	@echo "make webdist   构建 Flutter Web 产物到 app/build/web（P6-10）"
	@echo "make keystoretest Keystore 信封加密与删除条目后无法解密验收（P1-02）"
	@echo "make searchtest 1 万条消息下 FTS5 全文检索 <100ms 验收（P2-07）"
	@echo "make backuptest 加密备份导出与导入全量恢复验收（P6-05）"
	@echo "make relay     构建官方兜底中继节点到 bin/（P5-02）"
	@echo "make relaytest 中继带宽限额、超限拒绝新预约验收（P5-02）"
	@echo "make pushtest  唤醒推送 JWT 鉴权、静默载荷与令牌清理验收（P6-02）"
	@echo "make p2gatetest 链路中断 30s 后消息不丢不重、恢复后自动补发验收（P2 门禁）"
	@echo "make lint      go vet"
	@echo "make test      单元测试"
	@echo "make clean     清理产物"

tidy:
	$(GO) -C core mod tidy

proto:
	$(PROTOC) -I core/proto --go_out=core/api/v1 --go_opt=paths=source_relative $(PROTOS)

proto-lint:
	$(BUF) lint

contract:
	$(GO) -C core run ./cmd/nexmem-contract

contracttest:
	$(GO) -C core test ./contract -v -count=1
	cd app && FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn ../.toolchain/flutter/flutter/bin/flutter test test/contract_test.dart

build: p0-build

p0-build:
	$(GO) -C core build -o ../$(BIN)/nexmem-bootstrap ./cmd/nexmem-bootstrap
	$(GO) -C core build -o ../$(BIN)/spike-nat ./cmd/spike-nat

dmtest:
	$(GO) -C core run ./cmd/nexmem-dmtest -count 1000

statetest:
	$(GO) -C core run ./cmd/nexmem-statetest

filetest:
	$(GO) -C core run ./cmd/nexmem-filetest -size 1073741824

s3test:
	$(GO) -C core run ./cmd/nexmem-s3test -endpoint "$(S3_ENDPOINT)" -region "$(S3_REGION)" -bucket "$(S3_BUCKET)" -access "$(S3_ACCESS_KEY)" -secret "$(S3_SECRET_KEY)" $(S3_ARGS)

directory:
	$(GO) -C core build -o ../$(BIN)/nexmem-directory ./cmd/nexmem-directory

offlinetest:
	$(GO) -C core run ./cmd/nexmem-offlinetest -count 5

grouptest:
	$(GO) -C core test ./internal/group -run TestBroadcastFiftyNodes -v -count=1

groupfetchtest:
	$(GO) -C core test ./internal/coreapp -run TestP4GateGroupOfflineCatchUpLive -v -count=1

p3gatetest:
	$(GO) -C core test ./internal/coreapp -run TestP3GateIndexOutageKeepsOnlineChat -v -count=1

p2gatetest:
	$(GO) -C core test ./internal/coreapp -run TestP2GateLinkOutageKeepsConversationConsistent -v -count=1 -timeout 300s

ffi:
	$(GO) -C core build -buildmode=c-shared -o $(FFI_LIB) ./ffi/capi

ffitest: ffi
	$(GO) -C core run ./ffi/cmd/nexmem-ffitest -dll $(FFI_LIB)

linux-shared:
	CGO_ENABLED=1 GOOS=linux GOARCH=amd64 CC="$(CURDIR)/$(ZIG) cc -target x86_64-linux-gnu" $(GO) -C core build -buildmode=c-shared -o ../$(BIN)/nexmem-linux-amd64.so ./ffi/capi

linux-dist:
	bash deploy/linux/build-linux.sh

debpacktest:
	$(GO) -C core test ./cmd/nexmem-debpack -v -count=1

android-aar:
	cd core && gomobile bind -target=android -androidapi 24 -ldflags="-checklinkname=0" -o ../app/android/app/libs/nexmem.aar ./mobile

ios-xcframework:
	cd core && gomobile bind -target=ios -ldflags="-checklinkname=0" -o ../app/ios/Frameworks/Nexmem.xcframework ./mobile

webd:
	$(GO) -C core build -o ../$(BIN)/nexmem-webd ./cmd/nexmem-webd

webdtest:
	$(GO) -C core test ./server/webd -v -count=1

webdist:
	FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn .toolchain/flutter/flutter/bin/flutter build web --release --project-directory app

keystoretest:
	$(GO) -C core run ./cmd/nexmem-keystoretest

searchtest:
	$(GO) -C core run ./cmd/nexmem-searchtest -count 10000

backuptest:
	$(GO) -C core run ./cmd/nexmem-backuptest

relay:
	$(GO) -C core build -o ../$(BIN)/nexmem-relay ./cmd/nexmem-relay

relaytest:
	$(GO) -C core test ./server/relay -v -count=1
	$(GO) -C core test ./internal/netnode -run 'TestRelayServicePolicyQuotaOptions|TestRelayQuotaRejectsNewReservation' -v -count=1

pushtest:
	$(GO) -C core test ./internal/push ./server/directory -v -count=1

lint:
	$(GO) -C core vet ./...

test:
	$(GO) -C core test ./...

fmt:
	$(GO) -C core fmt ./...

clean:
	$(GO) -C core clean
	rm -rf $(BIN)
