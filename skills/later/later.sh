#!/usr/bin/env sh
# later.sh -- the parked-thought store behind the /later skill.
#
# One implementation of the store, two callers: the skill (add/list/done/maybe)
# and the SessionStart hook (show). The path resolution lives here for a
# reason -- two implementations of the mangling rule would drift, and a drifted
# path does not error, it silently starts a second invisible store.
#
# Usage (a scope flag may go anywhere except in `add`, whose text is free-form):
#   later.sh add [--user] <text>          park a thought
#   later.sh list [--user|--all]          numbered open items
#   later.sh done [--user] <n>            mark item n handled
#   later.sh maybe [--user] <n> <why>     mark item n possibly handled
#   later.sh show                         hook mode: digest, or nothing at all
#   later.sh path [--user]                print the store path
#
# -- ends the flags, for text or a reason that starts with one.
#
# --all is for `list` only: every other command acts on exactly one store.
#
# `show` always exits 0. A broken store must never stop a session starting.

set -u

# The store holds thoughts written nowhere else, so it is created private
# rather than at whatever the caller's umask happens to be -- commonly 022,
# which makes it 0644 and readable by every other account on the machine. This
# covers the store, the directory holding it, and the temp file `maybe`/`done`
# rewrite through, which would otherwise expose the whole store for the length
# of the rewrite. An existing store keeps its permissions until the next `done`
# or `maybe`, which replaces it with that temp file and so tightens it -- only
# ever in that direction. On MSYS/Git Bash the mode reads 0644 whatever the
# umask; NTFS profile ACLs cover the exposure there instead.
umask 077

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
# --path-format=absolute (git 2.31+) is required rather than preferred, and the
# reason is that every alternative spelling of this path is a second store.
#
# Without it git answers with a bare ".git" in the main checkout, an absolute
# path from a linked worktree, and "../../.git" from a subdirectory. Resolving
# those relative forms against $PWD gives a different string for the same
# directory every time the working directory moves -- and on Windows a
# different flavour of path entirely (/c/Users/... against C:/Users/...).
#
# Two spellings are two stores, and that failure is silent: the thought is
# written, `list` from elsewhere says "Nothing parked", and nothing errors. So
# there is no fallback. On older git a repository-scoped store is refused with
# a message that says why, which is recoverable; a fragmented one is not.
repo_root() {
  d=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$d" ] || return 1
  case "$d" in
    */.git) d=${d%/.git} ;;
  esac
  printf '%s' "$d"
}

# Deliberately not wrapped in a resolve_store() helper: `die` inside a command
# substitution exits only the subshell, so the caller sails on with an empty
# path and writes nowhere. The check belongs at the call site.
NO_REPO="not inside a git repository -- use --user to park this at user level"

# Why store_path failed, so the message names the actual problem. Being inside
# a repository and getting "not inside a git repository" sends the reader
# looking in the wrong place entirely.
no_repo_reason() {
  if err=$(git rev-parse --git-dir 2>&1); then
    printf '%s' "git 2.31 or newer is required for a repository-scoped store (it needs --path-format) -- park this with --user, or upgrade git"
    return 0
  fi
  case "$err" in
    # Anything else git says -- a dubious-ownership refusal being much the
    # commonest -- is passed through rather than reported as "not a repo",
    # which sends the reader looking in the wrong place entirely.
    *"not a git repository"*) printf '%s' "$NO_REPO" ;;
    '') printf '%s' "$NO_REPO" ;;
    *) printf 'git could not resolve this repository: %s' "$err" ;;
  esac
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

  store=$(store_path "$scope") || die "$(no_repo_reason)"
  [ -n "$store" ] || die "$(no_repo_reason)"
  dir=$(dirname "$store")
  mkdir -p "$dir" || die "cannot create $dir"

  # Every write is checked. A full disk or a read-only directory makes the
  # redirection fail while the script sails on to print "Parked (...)", which
  # reports a thought saved that was never written -- to the one file in this
  # design that has no other copy. A refusal the user can see is recoverable;
  # a false confirmation is the thought gone.
  if [ ! -f "$store" ]; then
    if [ "$scope" = user ]; then
      printf '# Later (user)\n\nParked thoughts belonging to no single repository. Written by the /later skill.\n\n' > "$store" ||
        die "could not write $store"
    else
      printf '# Later (%s)\n\nParked thoughts for this repository. Written by the /later skill.\n\n' "$(repo_name)" > "$store" ||
        die "could not write $store"
    fi
  fi

  # User-level items record where the thought arrived from, since that is the
  # whole case for the user store. In a repo store the origin is the file.
  origin=""
  if [ "$scope" = user ]; then
    origin=$(repo_name) || origin=""
  fi
  if [ -n "$origin" ]; then
    printf -- '- [ ] %s (from %s) %s\n' "$(date +%Y-%m-%d)" "$origin" "$text" >> "$store" ||
      die "could not append to $store -- nothing was parked"
  else
    printf -- '- [ ] %s %s\n' "$(date +%Y-%m-%d)" "$text" >> "$store" ||
      die "could not append to $store -- nothing was parked"
  fi

  printf 'Parked (%s store, %s open).\n' "$scope" "$(count_entries "$store")"
}

print_list() {
  store=$1
  label=$2
  prefix=${3:-}
  n=$(count_entries "$store")
  [ "$n" -gt 0 ] || return 0
  printf '%s:\n' "$label"
  entries "$store" | awk -v pfx="$prefix" '{ sub(/^[0-9]+:/, ""); printf "  %s%d. %s\n", pfx, NR, $0 }'
  printf '\n'
}

# Each store numbers from 1, and `--all` shows both -- so without the prefix
# there are two items called "1" and the number alone does not say which store
# it came from. `done`/`maybe` default to the repository store, so a number
# read off the user half of an `--all` listing would mark an unrelated
# repository item and hide it, while the item actually finished stayed open.
# The `u` is what carries the scope from the listing to the command.
cmd_list() {
  scope=$1
  found=0
  if [ "$scope" != user ]; then
    store=$(store_path repo 2>/dev/null) || store=""
    if [ -n "$store" ]; then
      print_list "$store" "Parked in $(repo_name)"
      [ "$(count_entries "$store")" -gt 0 ] && found=1
    else
      # Say why rather than reporting an empty list. An unreachable store and
      # an empty one look identical from here, and reporting "nothing parked"
      # over items that exist is the silent failure this whole design is
      # arranged to avoid -- refusing to write was only half of it.
      printf 'later: repository store unreachable -- %s\n' "$(no_repo_reason)" >&2
      found=1
    fi
  fi
  if [ "$scope" = user ] || [ "$scope" = all ]; then
    ustore=$(store_path user)
    if [ "$scope" = all ]; then
      print_list "$ustore" "Parked (user)" "u"
      [ "$(count_entries "$ustore")" -gt 0 ] &&
        printf 'Mark a u-prefixed item with --user: later.sh done --user <n>\n\n'
    else
      print_list "$ustore" "Parked (user)"
    fi
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
  # Same one-line collapse `add` applies to a parked thought, and for the same
  # reason: a newline in the reason ends the entry there and leaves the rest as
  # a line matching no entry pattern -- invisible to `list` and the digest, and
  # sitting in the store for good.
  why=$(printf '%s' "${4:-}" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ *//; s/ *$//')

  case "$n" in
    '' | *[!0-9]*) die "expected an item number, got '${n}'" ;;
  esac
  # `sed -n "0p"` is an error, not an empty result, so 0 would reach sed and
  # leak a raw diagnostic before the script's own message.
  [ "$n" -ge 1 ] || die "item numbers start at 1"

  store=$(store_path "$scope") || die "$(no_repo_reason)"
  [ -n "$store" ] || die "$(no_repo_reason)"
  target=$(entries "$store" | sed -n "${n}p")
  if [ -z "$target" ]; then
    # Name the store the number was looked up in. "run list" alone points at
    # the repository store, which is the wrong one to go and check.
    if [ "$scope" = user ]; then
      die "no user item $n -- run 'list --user' to see what is parked there"
    fi
    die "no item $n in this repository -- run 'list' to see what is parked"
  fi
  lineno=${target%%:*}

  # `why` goes through the environment rather than -v: awk processes escape
  # sequences in a -v assignment, so a backslash in the reason arrives mangled.
  #
  # Stripping a previous reason is deliberately narrow, because the delimiter
  # is ordinary prose a user could have parked. Two guards: strip only when the
  # entry is ALREADY marked `~` -- an unmarked one carries no reason of ours,
  # whatever its text looks like -- and strip at the LAST occurrence, since
  # that is the one this script appended. Without both, parking a thought that
  # happens to contain the delimiter and then marking it truncates the user's
  # own words out of the only copy that exists.
  tmp="${store}.tmp.$$"
  LATER_WHY="$why" awk -v ln="$lineno" -v mark="$mark" '
    BEGIN { why = ENVIRON["LATER_WHY"]; sep = " -- possibly handled by " }
    NR == ln {
      was = substr($0, 4, 1)
      body = substr($0, 7)
      if (was == "~") {
        cut = 0; off = 1
        while ((i = index(substr(body, off), sep)) > 0) { cut = off + i - 1; off = cut + 1 }
        if (cut > 0) body = substr(body, 1, cut - 1)
      }
      if (why != "") printf "- [%s] %s%s%s\n", mark, body, sep, why
      else printf "- [%s] %s\n", mark, body
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

# `add` takes leading flags only, because its text is free-form and may
# legitimately contain something that looks like one. Every other command
# accepts a scope flag ANYWHERE in its arguments.
#
# That asymmetry is the point rather than an inconsistency. `done 1 --user` is
# the natural typo of the command `list --all` tells you to run, and with
# leading-only parsing the flag is silently dropped: the mark lands on the
# repository item with the same number, hiding an unrelated thought while the
# one actually finished stays open. Silently marking the wrong item in the
# wrong store is the one failure here with no copy to recover from.
if [ "$cmd" = add ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      --user) scope=user; shift ;;
      --all) scope=all; shift ;;
      *) break ;;
    esac
  done
else
  # Rotate the argument list, dropping flags and keeping order. An unknown
  # `--flag` is refused rather than read as a positional -- `done 1 --usr`
  # must not quietly become `done 1`.
  remaining=$#
  i=0
  endflags=0
  while [ "$i" -lt "$remaining" ]; do
    a=$1
    shift
    if [ "$endflags" -eq 1 ]; then
      set -- "$@" "$a"
    else
      case "$a" in
        --) endflags=1 ;;
        --user) scope=user ;;
        --all) scope=all ;;
        --*) die "unknown flag '$a' -- put -- before it if it is text" ;;
        *) set -- "$@" "$a" ;;
      esac
    fi
    i=$((i + 1))
  done
fi

# `--all` means "both stores", which only `list` can honour. Every other command
# acts on exactly one, so it is refused rather than quietly meaning "repo" --
# which would act on a repository item under a flag the caller used to mean the
# other one too.
if [ "$scope" = all ] && [ "$cmd" != list ]; then
  die "--all is only for 'list' -- use --user, or no flag for this repository"
fi

case "$cmd" in
  add) cmd_add "$scope" "$@" ;;
  list) cmd_list "$scope" ;;
  done)
    [ $# -le 1 ] || die "done takes one item number, got: $*"
    cmd_mark "$scope" "${1:-}" x
    ;;
  maybe)
    n=${1:-}
    [ $# -gt 0 ] && shift
    # An empty reason would blank an existing one and re-mark with nothing --
    # the reason is the whole difference between `maybe` and `done`.
    [ -n "$*" ] || die "maybe needs a reason -- use 'done $n' to mark it handled outright"
    cmd_mark "$scope" "$n" '~' "$*"
    ;;
  show) cmd_show ;;
  path)
    p=$(store_path "$scope") || die "$(no_repo_reason)"
    [ -n "$p" ] || die "$(no_repo_reason)"
    printf '%s\n' "$p"
    ;;
  *) die "unknown command '$cmd'" ;;
esac
