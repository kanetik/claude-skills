#!/usr/bin/env sh
set -u

[ $# -ge 2 ] || {
  cat >&2 <<'EOF'
usage: check-attribution.sh first|later <comment-file>...

Each file must end with the attribution line and then the marker line:
  first run:  <!-- pr-review-skeptic: unit=<k> -->
  later run:  <!-- pr-review-skeptic: scope=whole|delta unit=<k> -->
              <!-- pr-review-skeptic -->
Prints each file that does not, and exits 1 if any.
EOF
  exit 2
}

case $1 in
  first) want='^<!-- pr-review-skeptic: unit=[0-9c][0-9c,]* -->$' ;;
  later) want='^<!-- pr-review-skeptic: scope=(whole|delta) unit=[0-9c][0-9c,]* -->$' ;;
  *) echo "first or later, not [$1]" >&2; exit 2 ;;
esac
shift

bad=0
for f in "$@"; do
  tail2=$(tr -d '\r' < "$f" | awk 'NF { a = b; b = $0 } END { print a; print b }')
  attr=$(printf '%s\n' "$tail2" | sed -n 1p)
  marker=$(printf '%s\n' "$tail2" | sed -n 2p)
  if [ "$marker" != '<!-- pr-review-skeptic -->' ] || ! printf '%s\n' "$attr" | grep -Eq "$want"; then
    printf 'missing attribution: %s\n' "$f"
    bad=1
  fi
done
exit $bad
