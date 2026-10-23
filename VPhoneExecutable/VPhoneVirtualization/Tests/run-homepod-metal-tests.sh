#!/bin/zsh
set -euo pipefail

tests="${0:a:h}"
repo="${tests:h:h:h}"
output="${1:-$repo/.build/homepod-metal-tests}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-homepod-metal.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT
/bin/mkdir -p "$output"

# This probe uses the actual renderer and shader source. It compiles no .metal
# file and invokes neither metal nor metallib, just like the product build.
/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$temporary/ModuleCache" -emit-library -emit-module \
    -module-name VPhoneCoreKit -emit-module-path "$temporary/VPhoneCoreKit.swiftmodule" \
    "$repo/VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneHomePodDisplay.swift" \
    -Xlinker -install_name -Xlinker '@rpath/libVPhoneCoreKit.dylib' \
    -o "$temporary/libVPhoneCoreKit.dylib"
/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$temporary/ModuleCache" -I "$temporary" -L "$temporary" -lVPhoneCoreKit \
    -Xlinker -rpath -Xlinker "$temporary" \
    "$tests/HomePodMetalProbe.swift" \
    "$tests:h/UI/UserInterface/HomePod/VPhoneHomePodMetalRenderer.swift" \
    "$tests:h/UI/UserInterface/HomePod/VPhoneHomePodShader.swift" \
    -o "$temporary/HomePodMetalProbe"
"$temporary/HomePodMetalProbe" "$output"
