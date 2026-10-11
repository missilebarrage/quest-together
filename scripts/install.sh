#!/usr/bin/env bash
# Copies the addon into the game's AddOns folder and verifies the copy.
# The folder comes from $QT_ADDONS_DIR or .tools/addons-path (git-ignored, one line).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

target="${QT_ADDONS_DIR:-}"
if [[ -z "$target" && -f .tools/addons-path ]]; then
	target="$(head -n1 .tools/addons-path)"
fi
if [[ -z "$target" || ! -d "$target" ]]; then
	echo "Set QT_ADDONS_DIR or write your Interface/AddOns path to .tools/addons-path." >&2
	exit 1
fi

destination="$target/QuestTogether"
mkdir -p "$destination"
# Mirror QuestTogether/ exactly: copy every file, then remove files that no longer exist.
(cd QuestTogether && find . -type f) | while read -r file; do
	mkdir -p "$destination/$(dirname "$file")"
	cp "QuestTogether/$file" "$destination/$file"
done
(cd "$destination" && find . -type f) | while read -r file; do
	[[ -f "QuestTogether/$file" ]] || rm -f "$destination/$file"
done
find "$destination" -type d -empty -delete

if diff -r QuestTogether "$destination" >/dev/null; then
	echo "Installed to $destination. New files need a game restart; changes need /reload."
else
	echo "Installed copy differs from QuestTogether/" >&2
	exit 1
fi
