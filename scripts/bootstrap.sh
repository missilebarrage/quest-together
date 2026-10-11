#!/usr/bin/env bash
# Installs the pinned development toolchain into .tools/ (git-ignored):
#   Lua 5.1.5 (built from source), StyLua and luacheck (official release binaries).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
BIN="$TOOLS/bin"
mkdir -p "$BIN"

LUA_VERSION="5.1.5"
LUA_SHA256="2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333"
STYLUA_VERSION="2.5.2"
STYLUA_SHA256="bcb0d855e91f102f28a370e850f8566b3b44b79e6274d806ea5246837c0fd5ab"
LUACHECK_VERSION="1.2.0"
LUACHECK_SHA256="d68da17fca0697d9e2fb04201f3884abd259fa558b3a449bccaed47f1390defc"  # pinned on first download; release ships no digest

download() { # url, destination, sha256
	curl -fsSL --retry 3 "$1" -o "$2"
	if ! echo "$3  $2" | sha256sum --check --status; then
		echo "Checksum mismatch for $1" >&2
		echo "  expected $3" >&2
		echo "  actual   $(sha256sum "$2" | cut -d' ' -f1)" >&2
		exit 1
	fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ ! -x "$BIN/lua" ]]; then
	echo "Building Lua $LUA_VERSION..."
	download "https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz" "$work/lua.tar.gz" "$LUA_SHA256"
	tar -xzf "$work/lua.tar.gz" -C "$work"
	make -s -C "$work/lua-$LUA_VERSION" posix >/dev/null
	install -m 755 "$work/lua-$LUA_VERSION/src/lua" "$BIN/lua"
	install -m 755 "$work/lua-$LUA_VERSION/src/luac" "$BIN/luac"
fi

if [[ ! -x "$BIN/stylua" ]]; then
	echo "Installing StyLua $STYLUA_VERSION..."
	download "https://github.com/JohnnyMorganz/StyLua/releases/download/v$STYLUA_VERSION/stylua-linux-x86_64.zip" \
		"$work/stylua.zip" "$STYLUA_SHA256"
	python3 -m zipfile -e "$work/stylua.zip" "$work/stylua"
	install -m 755 "$work/stylua/stylua" "$BIN/stylua"
fi

if [[ ! -x "$BIN/luacheck" ]]; then
	echo "Installing luacheck $LUACHECK_VERSION..."
	download "https://github.com/lunarmodules/luacheck/releases/download/v$LUACHECK_VERSION/luacheck" \
		"$work/luacheck" "$LUACHECK_SHA256"
	install -m 755 "$work/luacheck" "$BIN/luacheck"
fi

echo "Toolchain ready in $BIN:"
"$BIN/lua" -v
"$BIN/stylua" --version
"$BIN/luacheck" --version | head -1
