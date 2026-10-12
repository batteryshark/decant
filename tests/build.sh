#!/bin/sh
# Cross-compiles the test programs for 64- and 32-bit Windows with zig.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
for arch in x86_64 x86; do
  bits=$([ "$arch" = x86_64 ] && echo 64 || echo 32)
  zig cc -target "$arch-windows-gnu" -O2 sysinfo.c -o "bin/sysinfo$bits.exe"
  zig cc -target "$arch-windows-gnu" -O2 d3d11test.c -o "bin/d3d11test$bits.exe" -ld3d11 -ldxgi -luser32 -lgdi32
done
rm -f bin/*.pdb
