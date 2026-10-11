#!/usr/bin/env bash
# Builds QuestTogether-<version>.zip containing just the QuestTogether/ folder, for manual installs.
# Releases to CurseForge are packaged by the BigWigs packager (see .pkgmeta).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

version="${1:-$(git describe --tags --always 2>/dev/null || echo dev)}"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -r QuestTogether "$staging/QuestTogether"
sed -i "s/@project-version@/$version/" "$staging/QuestTogether/QuestTogether.toc"
output="$ROOT/QuestTogether-$version.zip"
rm -f "$output"
(cd "$staging" && python3 -m zipfile -c "$output" QuestTogether)
echo "Built $output"
