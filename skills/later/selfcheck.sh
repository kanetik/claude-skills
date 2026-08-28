#!/usr/bin/env sh
# Self-check for later.sh. Run it directly: sh selfcheck.sh
#
# Everything happens inside a throwaway directory with CLAUDE_CONFIG_DIR
# pointed at it, so this never touches a real store.

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LATER="$here/later.sh"
fails=0

ok() { printf 'ok   %s\n' "$1"; }
no() { printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }

check() {
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$3], got [$2]"; fi
}

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t later)
trap 'rm -rf "$tmp"' EXIT

CLAUDE_CONFIG_DIR="$tmp/claude"
export CLAUDE_CONFIG_DIR

repo="$tmp/myrepo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name Test
: > "$repo/seed"
git -C "$repo" add seed
git -C "$repo" commit -qm seed

run() { (cd "$repo" && sh "$LATER" "$@"); }
opens() { run list | grep -c '^  [0-9]*\.' || true; }

# --- store location ---------------------------------------------------------

run add "idea one" > /dev/null
store=$(run path)
case "$store" in
  "$CLAUDE_CONFIG_DIR"/projects/*/later.md) ok "store lands under projects/<mangled>/later.md" ;;
  *) no "store lands under projects/<mangled>/later.md" "$store" ;;
esac
[ -f "$store" ] && ok "store file created" || no "store file created" "$store missing"

# The load-bearing claim: a linked worktree shares the main repo's store, so
# parked thoughts survive the worktree being deleted when a branch lands.
wt="$tmp/wt"
git -C "$repo" worktree add -q -b wtbranch "$wt" 2>/dev/null
wt_store=$(cd "$wt" && sh "$LATER" path)
check "worktree resolves to the same store" "$wt_store" "$store"

# --- add / list -------------------------------------------------------------

run add "idea two" > /dev/null
check "two items open" "$(opens)" "2"

run list | grep -q '1\. .*idea one' && ok "list numbers from 1" || no "list numbers from 1" "$(run list)"

multi=$(printf 'line one\nline two')
run add "$multi" > /dev/null
run list | grep -q 'line one line two' && ok "multi-line thought collapses to one line" ||
  no "multi-line thought collapses to one line" "$(run list)"
check "three items open" "$(opens)" "3"

# --- done / maybe -----------------------------------------------------------

run done 1 > /dev/null
check "done removes an item from the list" "$(opens)" "2"
grep -q '^- \[x\] .*idea one' "$store" && ok "done marks [x] in the file" ||
  no "done marks [x] in the file" "$(cat "$store")"
run list | grep -q 'idea one' && no "handled items stop displaying" "still listed" ||
  ok "handled items stop displaying"

run maybe 1 "commit abc123" > /dev/null
grep -q '^- \[~\] .*idea two -- possibly handled by commit abc123' "$store" &&
  ok "maybe marks [~] with a reason" || no "maybe marks [~] with a reason" "$(cat "$store")"
check "possibly-handled items still display" "$(opens)" "2"

run maybe 1 "commit def456" > /dev/null
count=$(grep -c 'possibly handled by' "$store")
check "re-marking replaces the reason rather than appending" "$count" "1"

# --- user store -------------------------------------------------------------

run add --user "cross-repo idea" > /dev/null
ustore="$CLAUDE_CONFIG_DIR/later.md"
[ -f "$ustore" ] && ok "user store created at CLAUDE_CONFIG_DIR/later.md" ||
  no "user store created at CLAUDE_CONFIG_DIR/later.md" "missing"
grep -q '(from myrepo) cross-repo idea' "$ustore" &&
  ok "user items record the originating repo" || no "user items record the originating repo" "$(cat "$ustore")"
grep -q 'cross-repo idea' "$store" && no "user item stays out of the repo store" "leaked" ||
  ok "user item stays out of the repo store"

# --- show (hook mode) -------------------------------------------------------

run show | grep -q 'Parked in myrepo' && ok "show reports the repo store" ||
  no "show reports the repo store" "$(run show)"

# Silence when there is nothing to say -- the property that keeps the digest
# worth reading.
empty="$tmp/empty"
mkdir -p "$empty"
git -C "$empty" init -q
out=$(cd "$empty" && CLAUDE_CONFIG_DIR="$tmp/blank" sh "$LATER" show)
check "show prints nothing when nothing is parked" "$out" ""

out=$(cd "$empty" && CLAUDE_CONFIG_DIR="$tmp/blank" sh "$LATER" show; echo "rc=$?")
check "show exits 0 with an empty store" "$out" "rc=0"

# --- failure modes ----------------------------------------------------------

outside="$tmp/notarepo"
mkdir -p "$outside"
if (cd "$outside" && sh "$LATER" add "nope" > /dev/null 2>&1); then
  no "add outside a repo fails" "it succeeded"
else
  ok "add outside a repo fails"
fi
(cd "$outside" && sh "$LATER" add --user "fine" > /dev/null 2>&1) &&
  ok "add --user works outside a repo" || no "add --user works outside a repo" "it failed"

run done 99 > /dev/null 2>&1 && no "done on a bad index fails" "it succeeded" ||
  ok "done on a bad index fails"
run done abc > /dev/null 2>&1 && no "done on a non-number fails" "it succeeded" ||
  ok "done on a non-number fails"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'all checks passed\n'
else
  printf '%d check(s) failed\n' "$fails"
  exit 1
fi
