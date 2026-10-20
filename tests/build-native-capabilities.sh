#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p bin
zig cc -target x86_64-windows-gnu -O2 -fno-lto native-capabilities.c -o bin/native-capabilities64.exe -ld3d12 -ldxgi
