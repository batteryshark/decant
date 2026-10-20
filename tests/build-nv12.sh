#!/bin/sh
# Compile only. Runtime execution requires separately authorized isolated fixture.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
x86_64-w64-mingw32-gcc -O2 -fno-strict-aliasing -Wl,--no-insert-timestamp nv12test.c -o bin/nv12test64.exe -ld3d12 -luuid -ldxguid
