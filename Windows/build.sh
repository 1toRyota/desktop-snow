#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
compiler="${ZIG:-zig}"
for arch in "$@"; do
    case "$arch" in
        x64) target=x86_64-windows-gnu ;;
        arm64) target=aarch64-windows-gnu ;;
        *) printf 'Unknown Windows architecture: %s\n' "$arch" >&2; exit 2 ;;
    esac
    output="../dist/windows/$arch"
    mkdir -p "$output"
    "$compiler" c++ -target "$target" -std=c++20 -O2 -s -Wl,--subsystem,windows main.cpp \
        -o "$output/DesktopSnow.exe" -luser32 -lgdi32 -lshell32 -ladvapi32 -ldwmapi
done
