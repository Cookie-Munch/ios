#!/usr/bin/env bash
# Typecheck the package against every platform Package.swift declares.
#
# `swift build` on a Mac only compiles for macOS, so for a long time nobody noticed the
# package declared tvOS and watchOS support and compiled for neither. This checks each
# declared platform's SDK directly, which needs only Xcode — no simulator runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
check() {
  local sdk="$1" target="$2"
  local path
  path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  if swiftc -typecheck -sdk "$path" -target "$target" -module-name CookieMunch Sources/CookieMunch/*.swift; then
    echo "ok   $sdk ($target)"
  else
    echo "FAIL $sdk ($target)"; fail=1
  fi
}
check iphoneos   arm64-apple-ios15.0
check appletvos  arm64-apple-tvos15.0
check watchos    arm64-apple-watchos8.0
check macosx     arm64-apple-macos12.0
exit $fail
