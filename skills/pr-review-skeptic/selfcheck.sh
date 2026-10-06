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

only=$(mktemp -d)
cp "$FX/first-ok.md" "$only/c-1.md"
if sh "$CHECK" first "$only"/c-*.md "$only"/f-*.md "$only"/r-*.md >/dev/null; then
  ok "the documented globs pass where only c-*.md exists"
else
  no "the documented globs pass where only c-*.md exists"
fi
if sh "$CHECK" first "$only/c-2.md" >/dev/null 2>&1; then
  no "a named file that does not exist fails"
else
  ok "a named file that does not exist fails"
fi
rm -rf "$only"

if sh "$CHECK" first "$FX/first-ok.md" "$FX/no-attribution.md" >/dev/null; then
  no "one bad file fails the batch"
else
  ok "one bad file fails the batch"
fi

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
