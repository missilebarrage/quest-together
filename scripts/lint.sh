#!/usr/bin/env bash
# Syntax check, luacheck and StyLua format check.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.tools/bin"
cd "$ROOT"

if [[ ! -x "$BIN/lua" ]]; then
	echo "Toolchain missing: run scripts/bootstrap.sh first." >&2
	exit 1
fi

mapfile -t files < <(find QuestTogether tests -name '*.lua' | sort)
for file in "${files[@]}"; do
	"$BIN/luac" -p "$file"
done
rm -f luac.out
"$BIN/luacheck" --no-color --quiet QuestTogether tests
"$BIN/stylua" --check QuestTogether tests
echo "Lint passed (${#files[@]} files)."
