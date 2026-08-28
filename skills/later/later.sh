#!/usr/bin/env sh
# later.sh -- the parked-thought store behind the /later skill.
#
# One implementation of the store, two callers: the skill (add/list/done/maybe)
# and the SessionStart hook (show). The path resolution lives here for a
# reason -- two implementations of the mangling rule would drift, and a drifted
# path does not error, it silently starts a second invisible store.
#
# Usage (flags come before the text):
#   later.sh add [--user] <text>          park a thought
#   later.sh list [--user|--all]          numbered open items
#   later.sh done [--user] <n>            mark item n handled
#   later.sh maybe [--user] <n> <why>     mark item n possibly handled
#   later.sh show                         hook mode: digest, or nothing at all
#   later.sh path [--user]                print the store path
#
# `show` always exits 0. A broken store must never stop a session starting.

set -u

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SHOW_REPO_MAX="${LATER_SHOW_REPO_MAX:-7}"
SHOW_USER_MAX="${LATER_SHOW_USER_MAX:-3}"

die() {
  printf 'later: %s\n' "$1" >&2
  exit 1
}

# Claude Code keys per-project state on a path with every non-alphanumeric
# character replaced by a dash. Matching that convention puts later.md beside
# the project's own memory/ directory rather than somewhere novel.
mangle() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

# The MAIN repository root, deliberately -- not the working directory.
#
# --git-common-dir resolves to the main checkout's .git from inside a linked
# worktree, so every worktree of a repo shares one store. Keying on the
# worktree's own path would tie parked thoughts to a directory that gets
# deleted when the branch lands, losing them at the exact moment the work they
# were parked behind finishes.
# --path-format=absolute (git 2.31+) matters more than it looks: without it git
# answers with a bare ".git" in the main checkout but an absolute path from a
# linked worktree, and resolving the relative form against $PWD produces a
# different string for the same directory -- on Windows a different flavour of
# path entirely (/c/Users/... against C:/Users/...). Two spellings are two
# stores, which is this whole function's failure mode rather than an error.
repo_root() {
  d=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    d=$(git rev-parse --git-common-dir 2>/dev/null) ||
    return 1
  [ -n "$d" ] || return 1
  case "$d" in
    /* | ?:*) ;;
    *) d="$PWD/$d" ;;
  esac
  case "$d" in
    */.git) d=${d%/.git} ;;
  esac
  printf '%s' "$d"
}

repo_name() {
  r=$(repo_root) || return 1
  printf '%s' "${r##*/}"
}

store_path() {
  if [ "${1:-repo}" = user ]; then
    printf '%s/later.md' "$CLAUDE_HOME"
    return 0
  fi
  r=$(repo_root) || return 1
  [ -n "$r" ] || return 1
  printf '%s/projects/%s/later.md' "$CLAUDE_HOME" "$(mangle "$r")"
}

# Deliberately not wrapped in a resolve_store() helper: `die` inside a command
# substitution exits only the subshell, so the caller sails on with an empty
# path and writes nowhere. The check belongs at the call site.
NO_REPO="not inside a git repository -- use --user to park this at user level"

# Open and possibly-handled items, as "lineno:text". Handled items stay in the
# file -- "did I already do this?" is worth answering -- but never display.
entries() {
  [ -f "$1" ] || return 0
  grep -n '^- \[[ ~]\] ' "$1" 2>/dev/null || true
}

count_entries() {
  entries "$1" | wc -l | tr -d ' '
}

cmd_add() {
  scope=$1
  shift
  [ $# -gt 0 ] || die "nothing to park"
  # Collapse to one line: the store is a list, and a thought spanning lines
  # breaks both the numbering and the digest.
  text=$(printf '%s' "$*" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ *//; s/ *$//')
  [ -n "$text" ] || die "nothing to park"

  store=$(store_path "$scope") || die "$NO_REPO"
  [ -n "$store" ] || die "$NO_REPO"
  dir=$(dirname "$store")
  mkdir -p "$dir" || die "cannot create $dir"

  if [ ! -f "$store" ]; then
    if [ "$scope" = user ]; then
      printf '# Later (user)\n\nParked thoughts belonging to no single repository. Written by the /later skill.\n\n' > "$store"
    else
      printf '# Later (%s)\n\nParked thoughts for this repository. Written by the /later skill.\n\n' "$(repo_name)" > "$store"
    fi
  fi

  # User-level items record where the thought arrived from, since that is the
  # whole case for the user store. In a repo store the origin is the file.
  origin=""
  if [ "$scope" = user ]; then
    origin=$(repo_name) || origin=""
  fi
  if [ -n "$origin" ]; then
    printf -- '- [ ] %s (from %s) %s\n' "$(date +%Y-%m-%d)" "$origin" "$text" >> "$store"
  else
    printf -- '- [ ] %s %s\n' "$(date +%Y-%m-%d)" "$text" >> "$store"
  fi

  printf 'Parked (%s store, %s open).\n' "$scope" "$(count_entries "$store")"
}

print_list() {
  store=$1
  label=$2
  n=$(count_entries "$store")
  [ "$n" -gt 0 ] || return 0
  printf '%s:\n' "$label"
  entries "$store" | awk '{ sub(/^[0-9]+:/, ""); printf "  %d. %s\n", NR, $0 }'
  printf '\n'
}

cmd_list() {
  scope=$1
  found=0
  if [ "$scope" != user ]; then
    store=$(store_path repo 2>/dev/null) || store=""
    if [ -n "$store" ]; then
      print_list "$store" "Parked in $(repo_name)"
      [ "$(count_entries "$store")" -gt 0 ] && found=1
    fi
  fi
  if [ "$scope" = user ] || [ "$scope" = all ]; then
    ustore=$(store_path user)
    print_list "$ustore" "Parked (user)"
    [ "$(count_entries "$ustore")" -gt 0 ] && found=1
  fi
  [ "$found" -eq 1 ] || printf 'Nothing parked.\n'
}

# Rewrite the mark on the Nth displayed item. Numbering is over displayed
# items, so it matches what `list` printed.
cmd_mark() {
  scope=$1
  n=$2
  mark=$3
  why=${4:-}

  case "$n" in
    '' | *[!0-9]*) die "expected an item number, got '${n}'" ;;
  esac

  store=$(store_path "$scope") || die "$NO_REPO"
  [ -n "$store" ] || die "$NO_REPO"
  target=$(entries "$store" | sed -n "${n}p")
  [ -n "$target" ] || die "no item $n -- run 'list' to see what is parked"
  lineno=${target%%:*}

  tmp="${store}.tmp.$$"
  awk -v ln="$lineno" -v mark="$mark" -v why="$why" '
    NR == ln {
      sub(/^- \[[ ~]\] /, "")
      sub(/ -- possibly handled by .*$/, "")
      if (why != "") printf "- [%s] %s -- possibly handled by %s\n", mark, $0, why
      else printf "- [%s] %s\n", mark, $0
      next
    }
    { print }
  ' "$store" > "$tmp" || die "could not rewrite $store"
  mv "$tmp" "$store" || die "could not replace $store"

  sed -n "${lineno}p" "$store"
}

# Hook mode. Prints nothing when nothing is parked -- a digest that appears
# every session whether or not it has news is one you stop reading.
cmd_show() {
  out=""

  store=$(store_path repo 2>/dev/null) || store=""
  if [ -n "$store" ] && [ -f "$store" ]; then
    n=$(count_entries "$store")
    if [ "$n" -gt 0 ]; then
      out="$out
Parked in $(repo_name) ($n open):
$(entries "$store" | head -n "$SHOW_REPO_MAX" | sed 's/^[0-9]*:/  /')"
      if [ "$n" -gt "$SHOW_REPO_MAX" ]; then
        out="$out
  ... and $((n - SHOW_REPO_MAX)) more (later.sh list)"
      fi
    fi
  fi

  ustore=$(store_path user)
  if [ -f "$ustore" ]; then
    un=$(count_entries "$ustore")
    if [ "$un" -gt 0 ]; then
      out="$out
Parked (user, $un open):
$(entries "$ustore" | head -n "$SHOW_USER_MAX" | sed 's/^[0-9]*:/  /')"
      if [ "$un" -gt "$SHOW_USER_MAX" ]; then
        out="$out
  ... and $((un - SHOW_USER_MAX)) more (later.sh list --user)"
      fi
    fi
  fi

  [ -n "$out" ] || exit 0
  printf 'Parked thoughts from earlier sessions, via the /later skill. Do not act on these now; see the skill for when to raise them.%s\n' "$out"
  exit 0
}

# --- arguments --------------------------------------------------------------

[ $# -gt 0 ] || die "usage: later.sh add|list|done|maybe|show|path [--user] [args]"
cmd=$1
shift

scope=repo
while [ $# -gt 0 ]; do
  case "$1" in
    --user) scope=user; shift ;;
    --all) scope=all; shift ;;
    *) break ;;
  esac
done

case "$cmd" in
  add) cmd_add "$scope" "$@" ;;
  list) cmd_list "$scope" ;;
  done) cmd_mark "$scope" "${1:-}" x ;;
  maybe)
    n=${1:-}
    [ $# -gt 0 ] && shift
    cmd_mark "$scope" "$n" '~' "$*"
    ;;
  show) cmd_show ;;
  path) store_path "$scope" && printf '\n' ;;
  *) die "unknown command '$cmd'" ;;
esac
