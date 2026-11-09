#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
binary=$(mktemp "$PWD/build/policy.XXXXXXXX")
trap 'rm -f "$binary"' EXIT
/usr/bin/xcrun clang -fobjc-arc -Wall -Wextra -Werror -ISources \
    -framework Foundation -framework CoreGraphics Tests/Policy.m -o "$binary"
"$binary"
