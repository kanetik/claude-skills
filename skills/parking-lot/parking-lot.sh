#!/usr/bin/env sh
# parking-lot.sh -- the parked-thought store behind the /parking-lot skill.
# Store paths are resolved only here: a second copy of the rule would drift into
# a second, silent store.
#
# Usage (a scope flag may go anywhere except in `add`, whose text is free-form):
#   parking-lot.sh add [--user] [--next | --on YYYY-MM-DD | --tag <tag>] <text>
#   parking-lot.sh list [--user|--all]
#   parking-lot.sh done [--user] <n>
#   parking-lot.sh reopen [--user] <handled-line> <line>
#   parking-lot.sh plain [--user] <n>
#   parking-lot.sh maybe [--user] <n> <why>
#   parking-lot.sh show
#   parking-lot.sh hook
#   parking-lot.sh path [--user]
#
# `show` always exits 0: a broken store must never stop a session starting.

set -u

umask 077

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SHOW_REPO_MAX="${PARKING_LOT_SHOW_REPO_MAX:-7}"
SHOW_USER_MAX="${PARKING_LOT_SHOW_USER_MAX:-3}"

die() {
  printf 'parking-lot: %s\n' "$1" >&2
  exit 1
}

# Claude Code's per-project state key: every non-alphanumeric character becomes a dash.
mangle() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

# Keyed on the main repository root, never the worktree or working directory,
# and with no fallback for git < 2.31: see docs/adr/0003.
repo_root() {
  d=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$d" ] || return 1
  case "$d" in
    */.git) d=${d%/.git} ;;
  esac
  printf '%s' "$d"
}

# Check store_path at each call site: `die` inside $(...) exits only the subshell.
NO_REPO="not inside a git repository -- use --user instead"

no_repo_reason() {
  if ! command -v git > /dev/null 2>&1; then
    printf '%s' "git is not installed, and a repository-scoped store needs it -- use --user instead"
    return 0
  fi
  if err=$(git rev-parse --git-dir 2>&1); then
    printf '%s' "git 2.31 or newer is required for a repository-scoped store (it needs --path-format) -- upgrade git, or use --user"
    return 0
  fi
  case "$err" in
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
  # later.md is the store under the skill's former name.
  if [ -f "$dir/later.md" ] && [ ! -e "$dir/parking-lot.md" ]; then
    mv "$dir/later.md" "$dir/parking-lot.md" 2>/dev/null
    if [ -f "$dir/later.md" ] && [ ! -e "$dir/parking-lot.md" ]; then
      printf '%s/later.md' "$dir"
      return 0
    fi
  fi
  printf '%s/parking-lot.md' "$dir"
}

stray_note() {
  old="${1%/*}/later.md"
  [ "$1" != "$old" ] && [ -f "$old" ] || return 0
  sn=$(count_entries "$old")
  [ "$sn" -gt 0 ] || return 0
  printf 'parking-lot: %s holds %s item(s) from before the rename that are not in %s -- move them into it, then delete it\n' "$old" "$sn" "$1"
}

entries() {
  [ -f "$1" ] || return 0
  grep -n '^- \[[ ~]\] ' "$1" 2>/dev/null || true
}

count_entries() {
  entries "$1" | wc -l | tr -d ' '
}

# rank:lineno:text -- rank 0 due reminder, 1 --next, 2 plain, 9 not yet due.
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

# A $2 of "Parked (user" is left open for the count to close.
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
  text=$(printf '%s' "$*" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ *//; s/ *$//')
  [ -n "$text" ] || die "nothing to park"

  store=$(store_path "$scope") || die "$(no_repo_reason)"
  [ -n "$store" ] || die "$(no_repo_reason)"
  dir=$(dirname "$store")
  mkdir -p "$dir" || die "cannot create $dir"

  if [ ! -f "$store" ]; then
    if [ "$scope" = user ]; then
      printf '# Parking lot (user)\n\nParked thoughts belonging to no single repository. Written by the /parking-lot skill.\n\n' > "$store" ||
        die "could not write $store"
    else
      printf '# Parking lot (%s)\n\nParked thoughts for this repository. Written by the /parking-lot skill.\n\n' "$(repo_name)" > "$store" ||
        die "could not write $store"
    fi
  fi

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

cmd_list() {
  scope=$1
  found=0
  if [ "$scope" != user ]; then
    store=$(store_path repo 2>/dev/null) || store=""
    if [ -n "$store" ] && [ -e "$store" ] && { [ ! -f "$store" ] || [ ! -r "$store" ]; }; then
      printf 'parking-lot: repository store unreachable -- %s cannot be read\n' "$store" >&2
      found=1
    elif [ -n "$store" ]; then
      print_list "$store" "Parked in $(repo_name)"
      [ "$(count_entries "$store")" -gt 0 ] && found=1
      stray=$(stray_note "$store")
      [ -z "$stray" ] || { printf '%s\n' "$stray" >&2; found=1; }
    else
      printf 'parking-lot: repository store unreachable -- %s\n' "$(no_repo_reason)" >&2
      found=1
    fi
  fi
  if [ "$scope" = user ] || [ "$scope" = all ]; then
    ustore=$(store_path user)
    if [ -e "$ustore" ] && { [ ! -f "$ustore" ] || [ ! -r "$ustore" ]; }; then
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

# n counts entries(), as list does, so it means what list printed.
cmd_mark() {
  scope=$1
  n=$2
  mark=$3
  why=$(printf '%s' "${4:-}" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ *//; s/ *$//')

  case "$n" in
    '' | *[!0-9]*) die "expected an item number, got '${n}'" ;;
  esac
  [ "$n" -ge 1 ] || die "item numbers start at 1"

  store=$(store_path "$scope") || die "$(no_repo_reason)"
  [ -n "$store" ] || die "$(no_repo_reason)"
  target=$(entries "$store" | sed -n "${n}p")
  if [ -z "$target" ]; then
    if [ "$scope" = user ]; then
      die "no user item $n -- run 'list --user' to see what is parked there"
    fi
    die "no item $n in this repository -- run 'list' to see what is parked"
  fi
  lineno=${target%%:*}

  # ENVIRON, not -v: awk processes escapes in a -v value. Only an item already
  # marked ~ loses a reason, and only the last one: the separator is ordinary prose.
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
  line=$(printf '%s\n' "$3" | sed 's/^ *u\{0,1\}[0-9][0-9]*\. //')
  case "$line" in '- [ ] '* | '- [~] '*) ;; *) die "reopen restores an open or possibly-handled line" ;; esac
  restore=$(printf '%s\n' "$line" | sed 's/^\(- \[.\] [0-9-]* \((from [^)]*) \)\{0,1\}(when: [^)]*\), waiting)/\1)/')
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

cmd_show() {
  out=""
  note=""

  store=$(store_path repo 2>/dev/null) || store=""
  if [ -z "$store" ]; then
    # Being outside any repository is normal, not news.
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

# One stray control byte makes the hook's JSON invalid and the digest vanishes.
json_str() {
  tab=$(printf '\t')
  cr=$(printf '\r')
  tr -d '\000-\010\013\014\016-\037' |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$tab/\\\\t/g" -e "s/$cr/\\\\r/g" |
    awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

# systemMessage reaches the screen, additionalContext the model.
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

# `add` takes leading flags only, since its text is free-form; every other
# command takes a scope flag anywhere, so `done 1 --user` cannot hit the repo store.
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
  case "$scope:$when" in
    "user:tag "*) die "--tag is for repository items -- park it without --user" ;;
    user:next) die "--next is for repository items -- park it without --user" ;;
  esac
else
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
