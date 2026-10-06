#!/usr/bin/env sh
set -u

usage() {
  cat >&2 <<'EOF'
usage:
  first-pass.sh status <owner>/<repo> <num> <requested-at-iso8601> <wait-seconds> [bot-login]
  first-pass.sh classify < facts

facts, one key=value per line:
  requested=yes|no   the bot is still in reviewRequests
  reviewed=yes|no    the bot submitted a review at or after requested-at
  elapsed=<seconds>  since requested-at
  wait=<seconds>     how long the loop waits for the review

prints one of: arrived | pending | timed-out | not-available
EOF
  exit 2
}

classify() {
  requested=no reviewed=no elapsed=0 wait=0
  while IFS='=' read -r k v; do
    case $k in
      requested) requested=$v ;;
      reviewed) reviewed=$v ;;
      elapsed) elapsed=$v ;;
      wait) wait=$v ;;
    esac
  done
  if [ "$reviewed" = yes ]; then
    echo arrived
  elif [ "$requested" = yes ]; then
    if [ "$elapsed" -ge "$wait" ]; then echo timed-out; else echo pending; fi
  else
    echo not-available
  fi
}

status() {
  [ $# -ge 4 ] || usage
  owner=${1%%/*} repo=${1#*/} num=$2 since=$3 wait=$4 bot=${5:-copilot-pull-request-reviewer}
  facts=$(gh api graphql -F owner="$owner" -F repo="$repo" -F number="$num" -f query='
    query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){
      reviewRequests(first:20){nodes{requestedReviewer{__typename ... on Bot{login}}}}
      reviews(last:100){nodes{author{login} submittedAt}}}}}' \
    --jq "
      .data.repository.pullRequest as \$p
      | \"requested=\" + (if [\$p.reviewRequests.nodes[] | select(.requestedReviewer.login? == \"$bot\")] | length > 0 then \"yes\" else \"no\" end),
        \"reviewed=\" + (if [\$p.reviews.nodes[] | select(.author.login == \"$bot\" and .submittedAt >= \"$since\")] | length > 0 then \"yes\" else \"no\" end),
        \"elapsed=\" + ((now - (\"$since\" | fromdateiso8601)) | floor | tostring),
        \"wait=$wait\"") || exit 1
  printf '%s\n' "$facts"
  printf '%s\n' "$facts" | classify
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case $cmd in
  classify) classify ;;
  status) status "$@" ;;
  *) usage ;;
esac
