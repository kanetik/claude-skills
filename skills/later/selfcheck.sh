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

# The first park into an empty store must report exactly 1. SKILL.md warns
# "nothing is replaying the store" only above 1, so a 2 here would fire that
# warning on every user's first ever park -- on a correctly installed hook.
firstpark=$(cd "$repo" && sh "$LATER" add "idea one" 2>&1)
case "$firstpark" in
  *"1 open"*) ok "the first park into an empty store reports 1" ;;
  *) no "the first park into an empty store reports 1" "$firstpark" ;;
esac

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

# The other half of the count contract: the second park must report 2, so the
# warning above 1 can fire at all. (The first-park-reports-1 half, which is the
# one that stops the skill telling every new user their hook is broken, is
# asserted at the top of this file where that first park happens.)
first=$(cd "$repo" && sh "$LATER" add "count contract" 2>&1)
case "$first" in
  *"2 open"*) ok "add reports the count including the item just parked" ;;
  *) no "add reports the count including the item just parked" "$first" ;;
esac
run done 2 > /dev/null

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

# A newline in the reason used to end the entry there and leave the remainder
# as a line matching no entry pattern -- in the file for good, invisible to
# both `list` and the digest.
before=$(wc -l < "$store")
run maybe 1 "$(printf 'first line\nsecond line')" > /dev/null
after=$(wc -l < "$store")
check "a multi-line reason adds no orphan line" "$after" "$before"
grep -q 'possibly handled by first line second line' "$store" &&
  ok "a multi-line reason is collapsed, not truncated" ||
  no "a multi-line reason is collapsed, not truncated" "$(grep 'possibly handled' "$store")"

run maybe 1 'path C:\dir\file' > /dev/null
grep -q 'possibly handled by path C:\\dir\\file' "$store" &&
  ok "backslashes in the reason survive awk" || no "backslashes in the reason survive awk" "$(grep 'possibly handled' "$store")"

# --- user store -------------------------------------------------------------

run add --user "cross-repo idea" > /dev/null
ustore="$CLAUDE_CONFIG_DIR/later.md"
[ -f "$ustore" ] && ok "user store created at CLAUDE_CONFIG_DIR/later.md" ||
  no "user store created at CLAUDE_CONFIG_DIR/later.md" "missing"
grep -q '(from myrepo) cross-repo idea' "$ustore" &&
  ok "user items record the originating repo" || no "user items record the originating repo" "$(cat "$ustore")"
grep -q 'cross-repo idea' "$store" && no "user item stays out of the repo store" "leaked" ||
  ok "user item stays out of the repo store"

# The collision three reviewers found: both stores number from 1, so a bare
# number read off `--all` marked a repository item instead of the user item it
# was read from -- hiding an unrelated thought while the finished one stayed
# open. The prefix is what carries the scope from the listing to the command.
run list --all | grep -q '  u1\. .*cross-repo idea' &&
  ok "list --all prefixes user items with u" || no "list --all prefixes user items with u" "$(run list --all)"
run list --all | grep -q 'later.sh done --user' &&
  ok "list --all says how to mark a u-prefixed item" || no "list --all says how to mark a u-prefixed item" "$(run list --all)"
run list --user | grep -q '  1\. .*cross-repo idea' &&
  ok "list --user numbers plainly from 1" || no "list --user numbers plainly from 1" "$(run list --user)"

repo_before=$(opens)
run done --user 1 > /dev/null
check "done --user leaves the repo store untouched" "$(opens)" "$repo_before"
grep -q '^- \[x\] .*cross-repo idea' "$ustore" &&
  ok "done --user marks the user item" || no "done --user marks the user item" "$(cat "$ustore")"

for bad in done maybe add path; do
  if run "$bad" --all 1 > /dev/null 2>&1; then
    no "$bad --all is refused" "it succeeded"
  else
    ok "$bad --all is refused"
  fi
done
run list --all > /dev/null 2>&1 && ok "list --all is still accepted" ||
  no "list --all is still accepted" "it failed"

# `--` ends the flags, so text and reasons that begin with a dash can still be
# passed. Without it the unknown-flag guard refuses a reason like
# "--no-verify was needed", which is ordinary prose about a flag.
run add -- "--user is a flag, not a scope here" > /dev/null 2>&1 &&
  ok "-- lets add park text that starts with a flag" ||
  no "-- lets add park text that starts with a flag" "it failed"
run list | grep -q -- '--user is a flag, not a scope here' &&
  ok "the dash-led thought is stored verbatim" || no "the dash-led thought is stored verbatim" "$(run list)"

run maybe -- 1 "--no-verify was needed" > /dev/null 2>&1 &&
  ok "-- lets maybe take a reason that starts with a flag" ||
  no "-- lets maybe take a reason that starts with a flag" "$(run maybe -- 1 '--no-verify was needed' 2>&1)"

# The store holds thoughts written nowhere else; it must not be created at a
# permissive default umask. Windows reports 0644 regardless, so only assert
# where the platform actually carries POSIX bits.
# Both spellings: `-c` is GNU coreutils, `-f` is BSD, and macOS ships the BSD
# one. Folding an unreadable mode into the pass would make this check green on
# macOS whatever `umask 077` does -- a test that cannot fail for the regression
# it names, which is worse than no test, because it reads as coverage.
# `-c '%a'` is GNU; `-f '%OLp'` is BSD, which macOS ships -- O asks for octal
# and L selects the low nine permission bits. Not `%A`: that is GNU's letter
# for the *symbolic* mode and is not a BSD datum letter at all, so BSD stat
# exits 1 with "%A: bad format" (swallowed by 2>/dev/null) and every macOS run
# reported "could not read the mode" instead of checking it.
#
# The empty test is belt-and-braces rather than load-bearing: BSD stat does
# signal a bad format through its exit status, so the `|| echo unreadable`
# chain already catches it. It costs one line and covers any stat that reports
# success while printing nothing.
perms=$(stat -c '%a' "$store" 2>/dev/null || stat -f '%OLp' "$store" 2>/dev/null || echo unreadable)
[ -n "$perms" ] || perms=unreadable
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) ok "store permissions (skipped: no POSIX bits on this platform)" ;;
  *)
    case "$perms" in
      600) ok "the store is created private" ;;
      unreadable) no "the store is created private" "could not read the mode; neither stat -c nor stat -f worked" ;;
      *) no "the store is created private" "mode $perms" ;;
    esac
    ;;
esac

# Flag position. `done 1 --user` is the natural typo of the command `list --all`
# prints; with leading-only parsing the flag was dropped and the mark landed on
# the same-numbered REPOSITORY item, hiding an unrelated thought.
run add --user "trailing flag target" > /dev/null
repo_before=$(opens)
run done 1 --user > /dev/null 2>&1
check "done <n> --user does not touch the repo store" "$(opens)" "$repo_before"
grep -q '^- \[x\] .*trailing flag target' "$ustore" &&
  ok "done <n> --user marks the user item" || no "done <n> --user marks the user item" "$(cat "$ustore")"

run done 1 --usr > /dev/null 2>&1 && no "an unknown flag is refused" "it succeeded" ||
  ok "an unknown flag is refused"
run done 1 banana > /dev/null 2>&1 && no "trailing junk after the number is refused" "it succeeded" ||
  ok "trailing junk after the number is refused"
run maybe 1 "" > /dev/null 2>&1 && no "an empty reason is refused" "it succeeded" ||
  ok "an empty reason is refused"
run done 0 2>&1 | grep -qi 'sed' && no "done 0 leaks no raw sed error" "$(run done 0 2>&1)" ||
  ok "done 0 leaks no raw sed error"

# The delimiter between an item and its reason is ordinary prose, so a parked
# thought can contain it. Marking such an item used to truncate the user's own
# words out of the only copy that exists.
sentinel="audit -- possibly handled by nobody, keep this tail"
run add "$sentinel" > /dev/null
idx=$(run list | awk '/keep this tail/ { gsub(/[^0-9]/, "", $1); print $1; exit }')
run maybe "$idx" "commit abc" > /dev/null
grep -q 'audit -- possibly handled by nobody, keep this tail -- possibly handled by commit abc' "$store" &&
  ok "marking keeps item text that contains the delimiter" ||
  no "marking keeps item text that contains the delimiter" "$(grep 'keep this tail' "$store")"
run maybe "$idx" "commit def" > /dev/null
grep -q 'audit -- possibly handled by nobody, keep this tail -- possibly handled by commit def' "$store" &&
  ok "re-marking strips only the reason it wrote" ||
  no "re-marking strips only the reason it wrote" "$(grep 'keep this tail' "$store")"

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

# Pre-2.31 git. There is no fallback on purpose: resolving a relative
# --git-common-dir against $PWD keys a different store for every working
# directory, and that failure is silent. Refusing is recoverable.
realgit=$(command -v git)
shim="$tmp/shim"
mkdir -p "$shim"
{
  printf '#!/usr/bin/env sh\n'
  printf 'for a in "$@"; do case "$a" in --path-format=*) echo "error: unknown option" >&2; exit 129 ;; esac; done\n'
  printf 'exec "%s" "$@"\n' "$realgit"
} > "$shim/git"
chmod +x "$shim/git"

out=$(cd "$repo" && PATH="$shim:$PATH" sh "$LATER" add "on old git" 2>&1)
if [ $? -eq 0 ]; then
  no "add is refused on pre-2.31 git" "it succeeded -- the store would fragment by cwd"
else
  ok "add is refused on pre-2.31 git"
fi
case "$out" in
  *2.31*) ok "the pre-2.31 message names the git requirement" ;;
  *) no "the pre-2.31 message names the git requirement" "$out" ;;
esac

# The digest must degrade rather than break: the repo store is unreachable on
# old git, but a broken store must never stop a session starting, and the user
# store is unaffected.
out=$(cd "$repo" && PATH="$shim:$PATH" sh "$LATER" show 2>&1)
rc=$?
check "show exits 0 on pre-2.31 git" "$rc" "0"
case "$out" in
  *"Parked in myrepo"*) no "show drops the unreachable repo store on pre-2.31 git" "$out" ;;
  *) ok "show drops the unreachable repo store on pre-2.31 git" ;;
esac
case "$out" in
  *error*|*fatal*) no "show emits no git error on pre-2.31 git" "$out" ;;
  *) ok "show emits no git error on pre-2.31 git" ;;
esac

# Refusing to WRITE on old git was only half of it. `list` reporting an empty
# store over items that exist is the same silent failure, on the read side.
out=$(cd "$repo" && PATH="$shim:$PATH" sh "$LATER" list 2>&1)
case "$out" in
  *"Nothing parked"*) no "list does not claim an unreachable store is empty" "$out" ;;
  *2.31*) ok "list does not claim an unreachable store is empty" ;;
  *) no "list does not claim an unreachable store is empty" "$out" ;;
esac

out=$(cd "$repo" && PATH="$shim:$PATH" sh "$LATER" path 2>&1)
case "$out" in
  *2.31*) ok "path says why rather than printing nothing" ;;
  *) no "path says why rather than printing nothing" "[$out]" ;;
esac

# A git that fails for some other reason inside a repo -- dubious ownership is
# the common one on Windows -- must not be reported as "not a git repository".
badshim="$tmp/badshim"
mkdir -p "$badshim"
{
  printf '#!/usr/bin/env sh\n'
  printf 'echo "fatal: detected dubious ownership in repository" >&2\n'
  printf 'exit 128\n'
} > "$badshim/git"
chmod +x "$badshim/git"
out=$(cd "$repo" && PATH="$badshim:$PATH" sh "$LATER" add "x" 2>&1)
case "$out" in
  *"dubious ownership"*) ok "an unrelated git failure is reported as itself" ;;
  *) no "an unrelated git failure is reported as itself" "$out" ;;
esac

# On pre-2.31 git the origin tag cannot be resolved -- repo_name goes through
# repo_root, which is what needs --path-format. The thought must still be
# parked; only the "(from <repo>)" label is absent. Locking that down so a
# later change cannot quietly turn the missing tag into a lost thought.
before=$(grep -c '^- \[' "$ustore")
out=$(cd "$repo" && PATH="$shim:$PATH" sh "$LATER" add --user "parked on old git" 2>&1)
case "$out" in
  *"Parked (user store"*) ok "add --user still parks on pre-2.31 git" ;;
  *) no "add --user still parks on pre-2.31 git" "$out" ;;
esac
after=$(grep -c '^- \[' "$ustore")
[ "$after" -eq "$((before + 1))" ] && ok "the pre-2.31 user item reaches the store" ||
  no "the pre-2.31 user item reaches the store" "$before -> $after"
grep -q '(from .*) parked on old git' "$ustore" &&
  no "the origin tag is absent on pre-2.31 git, as documented" "a tag was written" ||
  ok "the origin tag is absent on pre-2.31 git, as documented"

# A write that fails must never be reported as a park. This is the one file
# with no other copy, so a false "Parked" is the thought gone.
#
# The two writes need two different setups, and getting that wrong is easy in a
# way that leaves one guard uncovered while both checks pass. `cmd_add` takes
# the header branch whenever the store is not a regular file -- a directory
# included -- so a directory-based setup exercises the header write TWICE and
# never reaches the append at all.

# Header write: the store path is a directory, so the redirection fails. Not an
# uncreatable config root, which would trip the earlier `mkdir -p` guard and
# pass without reaching the write check.
#
# This one asserts the BEHAVIOUR, not one particular `||`: with the header
# guard removed the run still refuses, because the append that follows fails on
# the same directory and dies there. Mutation-tested -- removing the header
# guard alone leaves this green. That is defence in depth rather than a hole
# (nothing reaches the user either way), and saying so beats implying a
# coverage this check does not have.
blocked="$tmp/blocked"
mkdir -p "$blocked/later.md"
out=$(cd "$repo" && CLAUDE_CONFIG_DIR="$blocked" sh "$LATER" add --user "unwritable" 2>&1)
case "$out" in
  *Parked*) no "a failed header write is never reported as a park" "$out" ;;
  *) ok "a failed header write is never reported as a park" ;;
esac

# Append write: a real store file, created normally and then made read-only, so
# the header branch is skipped and the append is what fails. This is the common
# path -- every park after the first goes through it.
appendro="$tmp/appendro"
mkdir -p "$appendro"
(cd "$repo" && CLAUDE_CONFIG_DIR="$appendro" sh "$LATER" add --user "first, writable" > /dev/null 2>&1)
chmod 0400 "$appendro/later.md" 2>/dev/null
if [ -w "$appendro/later.md" ]; then
  # Some filesystems ignore the read-only bit (running as root, certain mounts).
  # A skipped check is honest; a vacuous one is not.
  ok "a failed append is never reported as a park (skipped: read-only bit not honoured here)"
else
  out=$(cd "$repo" && CLAUDE_CONFIG_DIR="$appendro" sh "$LATER" add --user "second, blocked" 2>&1)
  case "$out" in
    *Parked*) no "a failed append is never reported as a park" "$out" ;;
    *) ok "a failed append is never reported as a park" ;;
  esac
  chmod 0600 "$appendro/later.md" 2>/dev/null
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'all checks passed\n'
else
  printf '%d check(s) failed\n' "$fails"
  exit 1
fi
