#!/usr/bin/env bash
# Full check: lint, the test suite and the distribution/privacy check.
# Pass a filter to run only matching tests: scripts/test.sh Scanner
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ $# -gt 0 ]]; then
	.tools/bin/lua tests/run.lua "$1"
	exit
fi

scripts/lint.sh
echo "Tests:"
.tools/bin/lua tests/run.lua
scripts/check-dist.sh
