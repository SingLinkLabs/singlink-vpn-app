# Builds libsinglink for every 星連VPN platform from ../../singlink-protocol
# (see the replace directive in go.mod) plus the TUN bridge in ./tunnel.
#
#   make macos    build/macos/libsinglink.dylib       universal, loaded by Flutter FFI
#   make android  build/android/<abi>/libsinglink.so  needs the Android NDK (ANDROID_NDK_HOME)
#   make ios      build/apple/Singlink.xcframework    static; iOS device, iOS simulator, macOS
#   make windows  build/windows/singlink.dll          needs a Windows C compiler (WIN_CC)
GO ?= go
LDF = -s -w
export MACOSX_DEPLOYMENT_TARGET ?= 13.0
IOS_MIN ?= 15.0
unexport IPHONEOS_DEPLOYMENT_TARGET
ANDROID_NDK_HOME ?= $(HOME)/Library/Android/sdk/ndk/28.2.13676358
NDK_BIN = $(ANDROID_NDK_HOME)/toolchains/llvm/prebuilt/darwin-x86_64/bin
ANDROID_API = 24
WIN_CC ?= zig cc -target x86_64-windows-gnu
APPLE = build/apple

.PHONY: test macos android ios windows

test:
	$(GO) vet ./...
	$(GO) test -race ./...

macos:
	mkdir -p build/macos
	CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 CC="clang -arch arm64" $(GO) build -trimpath -buildmode=c-shared -ldflags='$(LDF) -extldflags=-Wl,-install_name,@rpath/libsinglink.dylib' -o build/macos/arm64.dylib ./ffi
	CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 CC="clang -arch x86_64" $(GO) build -trimpath -buildmode=c-shared -ldflags='$(LDF) -extldflags=-Wl,-install_name,@rpath/libsinglink.dylib' -o build/macos/amd64.dylib ./ffi
	lipo -create -output build/macos/libsinglink.dylib build/macos/arm64.dylib build/macos/amd64.dylib
	mv -f build/macos/arm64.h build/macos/libsinglink.h
	cd build/macos && $(RM) arm64.dylib amd64.dylib amd64.h

android:
	for t in arm64-v8a:arm64:aarch64-linux-android armeabi-v7a:arm:armv7a-linux-androideabi x86_64:amd64:x86_64-linux-android; do \
	  abi=$${t%%:*}; rest=$${t#*:}; arch=$${rest%%:*}; triple=$${rest#*:}; \
	  mkdir -p build/android/$$abi; \
	  CGO_ENABLED=1 GOOS=android GOARCH=$$arch GOARM=7 CC=$(NDK_BIN)/$${triple}$(ANDROID_API)-clang \
	    $(GO) build -trimpath -buildmode=c-shared -ldflags='$(LDF) -extldflags=-Wl,-soname,libsinglink.so,-z,max-page-size=16384' -o build/android/$$abi/libsinglink.so ./ffi || exit 1; \
	  $(RM) build/android/$$abi/libsinglink.h; \
	done

ios:
	mkdir -p $(APPLE)/ios-arm64/include $(APPLE)/ios-sim-arm64/include $(APPLE)/macos-arm64/include
	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$$(xcrun -sdk iphoneos -f clang) -arch arm64 -isysroot $$(xcrun -sdk iphoneos --show-sdk-path) -miphoneos-version-min=$(IOS_MIN)" \
	  $(GO) build -trimpath -buildmode=c-archive -ldflags='$(LDF)' -o $(APPLE)/ios-arm64/libsinglink.a ./ffi
	CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$$(xcrun -sdk iphonesimulator -f clang) -arch arm64 -isysroot $$(xcrun -sdk iphonesimulator --show-sdk-path) -mios-simulator-version-min=$(IOS_MIN)" \
	  $(GO) build -trimpath -buildmode=c-archive -ldflags='$(LDF)' -o $(APPLE)/ios-sim-arm64/libsinglink.a ./ffi
	CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 CC="clang -arch arm64" \
	  $(GO) build -trimpath -buildmode=c-archive -ldflags='$(LDF)' -o $(APPLE)/macos-arm64/libsinglink.a ./ffi
	for d in ios-arm64 ios-sim-arm64 macos-arm64; do mv -f $(APPLE)/$$d/libsinglink.h $(APPLE)/$$d/include/; done
	test ! -e $(APPLE)/Singlink.xcframework || mv $(APPLE)/Singlink.xcframework $(APPLE)/Singlink.old.$$$$.xcframework
	xcodebuild -create-xcframework \
	  -library $(APPLE)/ios-arm64/libsinglink.a -headers $(APPLE)/ios-arm64/include \
	  -library $(APPLE)/ios-sim-arm64/libsinglink.a -headers $(APPLE)/ios-sim-arm64/include \
	  -library $(APPLE)/macos-arm64/libsinglink.a -headers $(APPLE)/macos-arm64/include \
	  -output $(APPLE)/Singlink.xcframework

windows:
	mkdir -p build/windows
	CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC="$(WIN_CC)" $(GO) build -trimpath -buildmode=c-shared -ldflags='$(LDF)' -o build/windows/singlink.dll ./ffi
