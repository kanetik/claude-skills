#!/usr/bin/env sh
# Self-check for scripts/first-pass.sh and scripts/call-sites.sh. Run it directly: sh selfcheck.sh
# Touches nothing outside its own temp directory.

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FX="$here/fixtures"
fails=0

ok() { printf 'ok   %s\n' "$1"; }
no() { printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$3], got [$2]"; fi; }

# --- first-pass outcome: each fixture is named for the outcome it must produce ---
for f in "$FX"/first-pass/*.facts; do
  want=$(basename "$f" .facts)
  check "first-pass $want" "$(sh "$here/scripts/first-pass.sh" classify < "$f")" "$want"
done

check "first-pass: a request that registered nothing is not-available even past the wait" \
  "$(printf 'requested=no\nreviewed=no\nelapsed=900\nwait=600\n' | sh "$here/scripts/first-pass.sh" classify)" \
  not-available
check "first-pass: a review that arrived after the wait still counts" \
  "$(printf 'requested=no\nreviewed=yes\nelapsed=900\nwait=600\n' | sh "$here/scripts/first-pass.sh" classify)" \
  arrived

# --- closure check: a fix that covers two of three callers ---
tmp=$(mktemp -d 2>/dev/null || mktemp -d -t closure)
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
case_dir="$FX/closure-half-done"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name Test
git -C "$repo" config core.autocrlf false
cp "$case_dir"/before/* "$repo"/
git -C "$repo" add -A && git -C "$repo" commit -qm before
cp "$case_dir"/after/* "$repo"/
git -C "$repo" add -A && git -C "$repo" commit -qm fix

sites=$(sh "$here/scripts/call-sites.sh" "$repo" HEAD fetch)
untouched=$(printf '%s\n' "$sites" | awk '$1 == "untouched" && $0 !~ /import / { split($2, a, ":"); print a[1] ":" a[2] }' | sort)
check "closure: the caller the fix missed is reported untouched" "$untouched" "$(cat "$case_dir/expected-untouched")"
check "closure: the two fixed callers and the definition are reported touched" \
  "$(printf '%s\n' "$sites" | grep -c '^touched ')" 3

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
