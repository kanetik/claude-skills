#!/usr/bin/env sh
set -u

[ $# -ge 3 ] || {
  cat >&2 <<'EOF'
usage: call-sites.sh <repo-dir> <fix-commit> <symbol>...

Every whole-word occurrence of each symbol in the tree at <fix-commit>, one per line:
  touched   <path>:<line>:<text>     the fix commit changed this line
  untouched <path>:<line>:<text>     it did not
EOF
  exit 2
}

repo=$1 fix=$2; shift 2

touched=$(git -C "$repo" diff -U0 --no-renames "$fix^" "$fix" | awk '
  /^\+\+\+ / { path = substr($0, 7); next }
  /^@@ / {
    split($3, r, ",")
    start = substr(r[1], 2) + 0
    count = (2 in r) ? r[2] + 0 : 1
    for (i = 0; i < count; i++) print path ":" (start + i)
  }') || exit 1

for sym in "$@"; do
  git -C "$repo" grep -n -w -F -e "$sym" "$fix" -- || true
done | sed "s|^$fix:||" | sort -u | while IFS= read -r hit; do
  key=$(printf '%s' "$hit" | cut -d: -f1,2)
  if printf '%s\n' "$touched" | grep -qxF -- "$key"; then
    printf 'touched   %s\n' "$hit"
  else
    printf 'untouched %s\n' "$hit"
  fi
done
