#!/bin/sh
# Builds only the headless x64 D3D12 smoke probe; does not run Wine.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
zig cc -target x86_64-windows-gnu -O2 d3d12test.c -o bin/d3d12test64.exe -ld3d12 -ldxgi
