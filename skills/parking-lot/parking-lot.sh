#!/usr/bin/env sh
# parking-lot.sh -- the parked-thought store behind the /parking-lot skill.
#
# One implementation of the store, two callers: the skill (add/list/done/plain/maybe)
# and the SessionStart hook (hook, which wraps show). The path resolution lives here for a
# reason -- two implementations of the mangling rule would drift, and a drifted
# path does not error, it silently starts a second invisible store.
#
# Usage (a scope flag may go anywhere except in `add`, whose text is free-form):
#   parking-lot.sh add [--user] [--next | --on YYYY-MM-DD | --tag <tag>] <text>
#                                         park a thought, optionally as a reminder
#   parking-lot.sh list [--user|--all]          numbered open items
#   parking-lot.sh done [--user] <n>            mark item n handled
#   parking-lot.sh plain [--user] <n>           drop item n's (when: ...), keeping it parked
#   parking-lot.sh maybe [--user] <n> <why>     mark item n possibly handled
#   parking-lot.sh show                         the digest, as plain text
#   parking-lot.sh hook                         the digest as SessionStart hook JSON
#   parking-lot.sh path [--user]                print the store path
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
# covers the store, the directory holding it, and the temp file `done`/`maybe`/
# `plain` rewrite through, which would otherwise expose the whole store for the
# length of the rewrite. An existing store keeps its permissions until the next
# such rewrite, which replaces it with that temp file and so tightens it -- only
# ever in that direction. On MSYS/Git Bash the mode reads 0644 whatever the
# umask; NTFS profile ACLs cover the exposure there instead.
umask 077

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SHOW_REPO_MAX="${PARKING_LOT_SHOW_REPO_MAX:-7}"
SHOW_USER_MAX="${PARKING_LOT_SHOW_USER_MAX:-3}"

die() {
  printf 'parking-lot: %s\n' "$1" >&2
  exit 1
}

# Claude Code keys per-project state on a path with every non-alphanumeric
# character replaced by a dash. Matching that convention puts parking-lot.md beside
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
NO_REPO="not inside a git repository -- use --user instead"

# Why store_path failed, so the message names the actual problem. Being inside
# a repository and getting "not inside a git repository" sends the reader
# looking in the wrong place entirely.
no_repo_reason() {
  # Checked before git is run, because the shell's not-found error carries this
  # script's path and line number, and every caller puts this string in front
  # of the user -- the digest into every session. It is not NO_REPO either: a
  # store written while git was on PATH still exists, and its key cannot be
  # resolved without git.
  #
  # Every string here reaches six callers, only one of which is parking a
  # thought, so they name the flag rather than telling the reader what to do
  # with it.
  if ! command -v git > /dev/null 2>&1; then
    printf '%s' "git is not installed, and a repository-scoped store needs it -- use --user instead"
    return 0
  fi
  if err=$(git rev-parse --git-dir 2>&1); then
    printf '%s' "git 2.31 or newer is required for a repository-scoped store (it needs --path-format) -- upgrade git, or use --user"
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
    dir=$CLAUDE_HOME
  else
    r=$(repo_root) || return 1
    [ -n "$r" ] || return 1
    dir="$CLAUDE_HOME/projects/$(mangle "$r")"
  fi
  # A store under the skill's former name is moved, never copied. One found
  # beside an existing store is left alone and reported by stray_note.
  if [ -f "$dir/later.md" ] && [ ! -e "$dir/parking-lot.md" ]; then
    mv "$dir/later.md" "$dir/parking-lot.md" 2>/dev/null
    if [ -f "$dir/later.md" ] && [ ! -e "$dir/parking-lot.md" ]; then
      printf '%s/later.md' "$dir"
      return 0
    fi
  fi
  printf '%s/parking-lot.md' "$dir"
}

# Names a later.md holding entries beside the store in use, which nothing else
# reads. Prints nothing otherwise.
stray_note() {
  old="${1%/*}/later.md"
  [ "$1" != "$old" ] && [ -f "$old" ] || return 0
  sn=$(count_entries "$old")
  [ "$sn" -gt 0 ] || return 0
  printf 'parking-lot: %s holds %s item(s) from before the rename that are not in %s -- move them into it, then delete it\n' "$old" "$sn" "$1"
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

# Entries as "rank:lineno:text", rank 0 for a reminder that has come due, 1
# for one to raise at the next stopping point, 2 for an ordinary item, and 9
# for a reminder whose date or tag has not arrived yet.
ranked_entries() {
  [ -f "$1" ] || return 0
  present=" "
  if grep -q '(when: tag ' "$1" 2>/dev/null; then
    present=" $(git tag -l 2>/dev/null | tr '\n' ' ')"
  fi
  awk -v today="$(date +%Y%m%d)" -v present="$present" '
    !/^- \[[ ~]\] / { next }
    {
      w = ""
      if (match($0, /^- \[.\] [0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-] (\(from [^)]*\) )?\(when: [^)]*\) /)) {
        w = substr($0, 1, RLENGTH)
        sub(/.*\(when: /, "", w)
        sub(/\) $/, "", w)
      }
      rank = 2
      if (w == "next") rank = 1
      else if (w ~ /^tag /) {
        t = substr(w, 5)
        rank = (t != "" && t !~ /[ \t]/ && index(present, " " t " ")) ? 0 : 9
      }
      else if (w ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
        d = w; gsub(/-/, "", d)
        rank = (d + 0 <= today + 0) ? 0 : 9
      }
      printf "%s:%s:%s\n", rank, NR, $0
    }
  ' "$1" | sort -t: -k1,1n -k2,2n
}

# One store's part of the digest, leading with a newline, or nothing at all.
# $2 is the heading: "Parked (user" is closed by the count, so the user store
# reads "Parked (user, 2 open)" and a repository "Parked in foo (2 open)".
digest_section() {
  ds_ranked=$(ranked_entries "$1")
  ds_wait=$(printf '%s\n' "$ds_ranked" | grep -c '^9:' || true)
  ds_active=$(printf '%s\n' "$ds_ranked" | grep '^[0-8]:' | sed 's/^[0-9]*:[0-9]*:/  /')
  ds_n=0
  [ -z "$ds_active" ] || ds_n=$(printf '%s\n' "$ds_active" | wc -l | tr -d ' ')
  [ "$ds_n" -gt 0 ] || [ "$ds_wait" -gt 0 ] || return 0
  case "$2" in
    *'(user') printf '\n%s, %s open):' "$2" "$ds_n" ;;
    *) printf '\n%s (%s open):' "$2" "$ds_n" ;;
  esac
  [ "$ds_n" -eq 0 ] || printf '\n%s' "$(printf '%s\n' "$ds_active" | head -n "$3")"
  [ "$ds_n" -le "$3" ] || printf '\n  ... and %s more (%s)' "$((ds_n - $3))" "$4"
  [ "$ds_wait" -eq 0 ] || printf '\n  %s more waiting for a date or tag (%s)' "$ds_wait" "$4"
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
      printf '# Parking lot (user)\n\nParked thoughts belonging to no single repository. Written by the /parking-lot skill.\n\n' > "$store" ||
        die "could not write $store"
    else
      printf '# Parking lot (%s)\n\nParked thoughts for this repository. Written by the /parking-lot skill.\n\n' "$(repo_name)" > "$store" ||
        die "could not write $store"
    fi
  fi

  # User-level items record where the thought arrived from, since that is the
  # whole case for the user store. In a repo store the origin is the file.
  origin=""
  if [ "$scope" = user ]; then
    origin=$(repo_name) || origin=""
  fi
  printf -- '- [ ] %s %s%s%s\n' "$(date +%Y-%m-%d)" "${origin:+(from $origin) }" "${when:+(when: $when) }" "$text" >> "$store" ||
    die "could not append to $store -- nothing was parked"

  printf 'Parked (%s store, %s open).\n' "$scope" "$(count_entries "$store")"
}

print_list() {
  store=$1
  label=$2
  prefix=${3:-}
  n=$(count_entries "$store")
  [ "$n" -gt 0 ] || return 0
  printf '%s:\n' "$label"
  waiting=$(ranked_entries "$store" | awk -F: '$1 == 9 { printf "%s ", $2 }')
  entries "$store" | awk -v pfx="$prefix" -v waiting=" $waiting" '{
    ln = $0; sub(/:.*/, "", ln)
    sub(/^[0-9]+:/, "")
    if (index(waiting, " " ln " ")) sub(/\(when: [^)]*/, "&, waiting")
    printf "  %s%d. %s\n", pfx, NR, $0
  }'
  printf '\n'
}

# Each store numbers from 1, and `--all` shows both -- so without the prefix
# there are two items called "1" and the number alone does not say which store
# it came from. `done`/`maybe`/`plain` default to the repository store, so a number
# read off the user half of an `--all` listing would mark an unrelated
# repository item and hide it, while the item actually finished stayed open.
# The `u` is what carries the scope from the listing to the command.
cmd_list() {
  scope=$1
  found=0
  if [ "$scope" != user ]; then
    store=$(store_path repo 2>/dev/null) || store=""
    if [ -n "$store" ] && [ -e "$store" ] && { [ ! -f "$store" ] || [ ! -r "$store" ]; }; then
      # Anything present that is not a readable regular file counts as empty
      # otherwise, for the same reason the else branch exists: entries()
      # swallows the grep failure, and -f alone passes a directory through to
      # it. Both arrive as "nothing parked" over a store that was never read.
      printf 'parking-lot: repository store unreachable -- %s cannot be read\n' "$store" >&2
      found=1
    elif [ -n "$store" ]; then
      print_list "$store" "Parked in $(repo_name)"
      [ "$(count_entries "$store")" -gt 0 ] && found=1
      stray=$(stray_note "$store")
      [ -z "$stray" ] || { printf '%s\n' "$stray" >&2; found=1; }
    else
      # Say why rather than reporting an empty list. An unreachable store and
      # an empty one look identical from here, and reporting "nothing parked"
      # over items that exist is the silent failure this whole design is
      # arranged to avoid -- refusing to write was only half of it.
      printf 'parking-lot: repository store unreachable -- %s\n' "$(no_repo_reason)" >&2
      found=1
    fi
  fi
  if [ "$scope" = user ] || [ "$scope" = all ]; then
    ustore=$(store_path user)
    if [ -e "$ustore" ] && { [ ! -f "$ustore" ] || [ ! -r "$ustore" ]; }; then
      # Named rather than listed as empty, and nothing is listed after it: an
      # empty "Parked (user)" heading under this notice says the store was
      # read and held nothing.
      printf 'parking-lot: user store unreachable -- %s cannot be read\n' "$ustore" >&2
      found=1
    else
      if [ "$scope" = all ]; then
        print_list "$ustore" "Parked (user)" "u"
        [ "$(count_entries "$ustore")" -gt 0 ] &&
          printf 'Mark a u-prefixed item with --user: parking-lot.sh done --user <n>\n\n'
      else
        print_list "$ustore" "Parked (user)"
      fi
      [ "$(count_entries "$ustore")" -gt 0 ] && found=1
      stray=$(stray_note "$ustore")
      [ -z "$stray" ] || { printf '%s\n' "$stray" >&2; found=1; }
    fi
  fi
  [ "$found" -eq 1 ] || printf 'Nothing parked.\n'
}

# Rewrite the mark on the Nth displayed item, or with mark "plain" drop its
# (when: ...) and leave the mark alone. Numbering is over displayed
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
  PARKING_LOT_WHY="$why" awk -v ln="$lineno" -v mark="$mark" '
    BEGIN { why = ENVIRON["PARKING_LOT_WHY"]; sep = " -- possibly handled by " }
    NR == ln && mark == "plain" {
      if (match($0, /^- \[.\] [0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-][0-9-] (\(from [^)]*\) )?\(when: [^)]*\) /)) {
        pre = substr($0, 1, RLENGTH)
        sub(/\(when: [^)]*\) $/, "", pre)
        print pre substr($0, RLENGTH + 1)
      } else print
      next
    }
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

cmd_reopen() {
  case "$2" in '- [x] '*) ;; *) die "reopen takes the handled line as done printed it" ;; esac
  case "$3" in '- [ ] '* | '- [~] '*) ;; *) die "reopen restores an open or possibly-handled line" ;; esac
  restore=$(printf '%s\n' "$3" | sed 's/^\(- \[.\] [0-9-]* \((from [^)]*) \)\{0,1\}(when: [^)]*\), waiting)/\1)/')
  bare=$(PARKING_LOT_LINE="$restore" awk 'BEGIN {
    l = ENVIRON["PARKING_LOT_LINE"]; b = substr(l, 7); sep = " -- possibly handled by "
    if (substr(l, 4, 1) == "~") {
      cut = 0; off = 1
      while ((i = index(substr(b, off), sep)) > 0) { cut = off + i - 1; off = cut + 1 }
      if (cut > 0) b = substr(b, 1, cut - 1)
    }
    print b
  }')
  [ "$bare" = "$(printf '%s\n' "$2" | cut -c7-)" ] || die "reopen restores only the item that handled line came from"
  store=$(store_path "$1") || die "$(no_repo_reason)"
  [ -n "$store" ] || die "$(no_repo_reason)"
  lineno=$(grep -n -x -F -- "$2" "$store" 2>/dev/null | tail -n 1 | cut -d: -f1)
  [ -n "$lineno" ] || die "no handled item matches that line"
  tmp="${store}.tmp.$$"
  PARKING_LOT_LINE="$restore" awk -v ln="$lineno" 'NR == ln { print ENVIRON["PARKING_LOT_LINE"]; next } { print }' "$store" > "$tmp" ||
    die "could not rewrite $store"
  mv "$tmp" "$store" || die "could not replace $store"
  sed -n "${lineno}p" "$store"
}

# A store whose key cannot be RESOLVED is named rather than counted as empty,
# for the reason cmd_list gives. A store present but not readable is named too --
# entries() swallows a grep failure, so without the check it would count as
# empty, which is the same silent failure one layer down.
cmd_show() {
  out=""
  note=""

  store=$(store_path repo 2>/dev/null) || store=""
  if [ -z "$store" ]; then
    # Outside a repository there is no repository store to reach and never
    # will be -- the normal state of every non-git session, not something to
    # report at the top of it. Anything else is a store that may hold items
    # and cannot be read, which is news.
    reason=$(no_repo_reason)
    [ "$reason" = "$NO_REPO" ] ||
      note="parking-lot: repository store unreachable -- $reason"
  elif [ -e "$store" ] && { [ ! -f "$store" ] || [ ! -r "$store" ]; }; then
    note="parking-lot: repository store unreachable -- $store cannot be read"
  elif [ -f "$store" ]; then
    out="$out$(digest_section "$store" "Parked in $(repo_name)" "$SHOW_REPO_MAX" "parking-lot.sh list")"
  fi

  ustore=$(store_path user)
  if [ -e "$ustore" ] && { [ ! -f "$ustore" ] || [ ! -r "$ustore" ]; }; then
    note="${note:+$note
}parking-lot: user store unreachable -- $ustore cannot be read"
  elif [ -f "$ustore" ]; then
    out="$out$(digest_section "$ustore" "Parked (user" "$SHOW_USER_MAX" "parking-lot.sh list --user")"
  fi

  for s in "$store" "$ustore"; do
    [ -n "$s" ] || continue
    stray=$(stray_note "$s")
    [ -z "$stray" ] || note="${note:+$note
}$stray"
  done

  [ -z "$note" ] || printf '%s\n' "$note"
  if [ -z "$out" ]; then
    [ -n "$note" ] || printf 'Nothing parked, via the /parking-lot skill.\n'
    exit 0
  fi
  printf 'Parked thoughts from earlier sessions, via the /parking-lot skill. Do not act on these now; see the skill for when to raise them. A (when: <date>) or (when: tag ...) item listed here is a reminder that has come due: mention it once, in one line. A (when: next) item waits for a stopping point.%s\n' "$out"
  exit 0
}

# One JSON string body from stdin: escapes, lines joined with \n, and every
# other control character dropped, since one stray byte makes the hook's whole
# output invalid JSON and the digest silently disappears.
json_str() {
  tab=$(printf '\t')
  cr=$(printf '\r')
  tr -d '\000-\010\013\014\016-\037' |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$tab/\\\\t/g" -e "s/$cr/\\\\r/g" |
    awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

# systemMessage is what the user sees on screen; additionalContext is what the
# model gets. Plain stdout reaches only the model, which a session opened with a
# prompt already typed goes straight past. Claude Code prefixes systemMessage
# with the hook's event name, so the on-screen copy stays short.
cmd_hook() {
  full=$(cmd_show)
  screen=$(printf '%s\n' "$full" |
    sed -e '/^Nothing parked, via the \/parking-lot skill\.$/d' \
        -e 's/^Parked thoughts from earlier sessions, via the \/parking-lot skill\..*/Parked thoughts (\/parking-lot):/' |
    json_str)
  body=$(printf '%s\n' "$full" | json_str)
  msg=""
  [ -z "$screen" ] || msg="\"systemMessage\":\"$screen\","
  printf '{%s"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg" "$body"
  exit 0
}

# --- arguments --------------------------------------------------------------

[ $# -gt 0 ] || die "usage: parking-lot.sh add|list|done|reopen|plain|maybe|show|hook|path [--user] [args]"
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
when=""
if [ "$cmd" = add ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      --user) scope=user; shift ;;
      --all) scope=all; shift ;;
      --next | --on | --tag)
        [ -z "$when" ] || die "use only one of --next, --on, --tag"
        case "$1:${2:-}" in
          --next:*) when=next; shift ;;
          --on:[0-9][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]) when=$2; shift 2 ;;
          --on:*) die "--on takes a date as YYYY-MM-DD, got '${2:-}'" ;;
          --tag: | --tag:-* | --tag:*[!A-Za-z0-9._/+-]*) die "--tag takes a git tag name, got '${2:-}'" ;;
          --tag:*) when="tag $2"; shift 2 ;;
        esac
        ;;
      *) break ;;
    esac
  done
  # A tag is looked up in the repository the session is in, and a user item
  # surfaces in every repository.
  case "$scope:$when" in
    "user:tag "*) die "--tag is for repository items -- park it without --user" ;;
    user:next) die "--next is for repository items -- park it without --user" ;;
  esac
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
  plain)
    [ $# -le 1 ] || die "plain takes one item number, got: $*"
    cmd_mark "$scope" "${1:-}" plain
    ;;
  maybe)
    n=${1:-}
    [ $# -gt 0 ] && shift
    # An empty reason would blank an existing one and re-mark with nothing --
    # the reason is the whole difference between `maybe` and `done`.
    [ -n "$*" ] || die "maybe needs a reason -- use 'done $n' to mark it handled outright"
    cmd_mark "$scope" "$n" '~' "$*"
    ;;
  reopen)
    [ $# -eq 2 ] || die "reopen takes the handled line and the line to restore"
    cmd_reopen "$scope" "$1" "$2"
    ;;
  show) cmd_show ;;
  hook) cmd_hook ;;
  path)
    p=$(store_path "$scope") || die "$(no_repo_reason)"
    [ -n "$p" ] || die "$(no_repo_reason)"
    printf '%s\n' "$p"
    ;;
  *) die "unknown command '$cmd'" ;;
esac
