#!/usr/bin/env sh
# Self-check for scripts/check-attribution.sh. Run it directly: sh selfcheck.sh

set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECK="$here/scripts/check-attribution.sh"
FX="$here/fixtures/attribution"
fails=0

ok() { printf 'ok   %s\n' "$1"; }
no() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

passes() { if sh "$CHECK" "$1" "$FX/$2" >/dev/null; then ok "$1 accepts $2"; else no "$1 accepts $2"; fi; }
refuses() { if sh "$CHECK" "$1" "$FX/$2" >/dev/null; then no "$1 refuses $2"; else ok "$1 refuses $2"; fi; }

passes first first-ok.md
passes first first-merged-ok.md
passes later later-ok.md
refuses first no-attribution.md
refuses later no-attribution.md
refuses later later-missing-scope.md
refuses first later-ok.md
refuses first no-marker.md

crlf=$(mktemp)
tr -d '\r' < "$FX/first-ok.md" | sed 's/$/\r/' > "$crlf"
if sh "$CHECK" first "$crlf" >/dev/null; then ok "first accepts CRLF body"; else no "first accepts CRLF body"; fi
rm -f "$crlf"

dir=$(mktemp -d)
if sh "$CHECK" first "$dir" >/dev/null; then ok "an empty payload directory passes"; else no "an empty payload directory passes"; fi
cp "$FX/first-ok.md" "$dir/c-1.md"
if sh "$CHECK" first "$dir" >/dev/null; then ok "a directory holding only c-*.md passes"; else no "a directory holding only c-*.md passes"; fi
cp "$FX/no-attribution.md" "$dir/r-1.md"
if sh "$CHECK" first "$dir" >/dev/null; then no "a bad reply in the directory fails"; else ok "a bad reply in the directory fails"; fi
if sh "$CHECK" first "$dir/missing" >/dev/null 2>&1; then
  no "a path that does not exist fails"
else
  ok "a path that does not exist fails"
fi
rm -rf "$dir"

if sh "$CHECK" first "$FX/first-ok.md" "$FX/no-attribution.md" >/dev/null; then
  no "one bad file fails the batch"
else
  ok "one bad file fails the batch"
fi

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
