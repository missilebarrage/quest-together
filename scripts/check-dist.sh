#!/usr/bin/env bash
# Checks the repository before anything is shared or packaged:
#  * no absolute paths or e-mail addresses in tracked text files,
#  * none of the terms in .tools/privacy-denylist.txt (git-ignored, one per line),
#  * the TOC names Tim as author, targets interface 16001 and lists exactly the files in QuestTogether/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
failed=0

fail() {
	echo "check-dist: $*" >&2
	failed=1
}

# Every file that could be published: tracked files plus new, not-ignored ones.
if git rev-parse --git-dir >/dev/null 2>&1; then
	mapfile -t files < <(git ls-files --cached --others --exclude-standard)
else
	mapfile -t files < <(find . -type f -not -path './.git/*' -not -path './.tools/*' | sed 's|^\./||')
fi

for file in "${files[@]}"; do
	[[ -f "$file" ]] || continue
	grep -Iq . "$file" 2>/dev/null || continue # skip binary files
	[[ "$file" == "scripts/check-dist.sh" ]] && continue # the patterns below appear in this file
	if grep -qE '(/home/|/Users/|/mnt/[a-z]/|[A-Za-z]:\\\\Users)' "$file"; then
		fail "absolute path in $file"
	fi
	if grep -nE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$file" | grep -vE 'noreply@|example\.(invalid|com)' >/dev/null; then
		fail "e-mail address in $file"
	fi
done

denylist=".tools/privacy-denylist.txt"
if [[ -f "$denylist" ]]; then
	while IFS= read -r term || [[ -n "$term" ]]; do
		[[ -z "$term" || "$term" == \#* ]] && continue
		for file in "${files[@]}"; do
			[[ -f "$file" ]] || continue
			if grep -Fqi -- "$term" "$file"; then
				fail "denylisted term found in $file"
			fi
		done
		if git rev-parse --git-dir >/dev/null 2>&1 && git log --all --format='%an %ae %cn %ce %B' | grep -Fqi -- "$term"; then
			fail "denylisted term found in git history (author, committer or message)"
		fi
	done <"$denylist"
else
	echo "check-dist: note: no $denylist; only generic checks ran." >&2
fi

toc="QuestTogether/QuestTogether.toc"
grep -q '^## Author: Tim$' "$toc" || fail "TOC author must be Tim"
grep -q '^## Interface: 16001$' "$toc" || fail "TOC interface must be 16001"
listed="$(grep -v '^#' "$toc" | grep -v '^\s*$' | tr '\\' '/' | sed 's/\r$//' | sort)"
present="$(cd QuestTogether && find . -name '*.lua' | sed 's|^\./||' | sort)"
if [[ "$listed" != "$present" ]]; then
	fail "TOC file list doesn't match QuestTogether/*.lua:"
	diff <(echo "$listed") <(echo "$present") >&2 || true
fi

if [[ $failed -ne 0 ]]; then
	exit 1
fi
echo "Distribution check passed."
