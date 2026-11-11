#!/usr/bin/env bash
# Verify the mintlify-demo org is in the expected post-reset state.
# Exit 0 if all checks pass, 1 otherwise.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$KIT/manifest.json"
ORG=$(jq -r .org "$MANIFEST")
TAG=$(jq -r .baseline_tag "$MANIFEST")
SITE="${DEMO_SITE:-https://mintlify-demo.mintlify.site}"
fail=0
say() { echo "$*"; }
bad() { echo "FAIL: $*"; fail=1; }

tag_commit() {
  local repo=$1 ref type sha
  ref=$(gh api "repos/$ORG/$repo/git/ref/tags/$TAG")
  type=$(jq -r .object.type <<<"$ref"); sha=$(jq -r .object.sha <<<"$ref")
  if [ "$type" = tag ]; then sha=$(gh api "repos/$ORG/$repo/git/tags/$sha" --jq .object.sha); fi
  echo "$sha"
}

say "== API mains == $TAG"
while read -r repo; do
  base=$(tag_commit "$repo")
  main=$(gh api "repos/$ORG/$repo/commits/main" --jq .sha)
  if [ "$main" = "$base" ]; then say "  $repo main=${main:0:7} ok"
  else bad "$repo main=${main:0:7} != $TAG ${base:0:7}"; fi
done < <(jq -r '.reset_repos[]' "$MANIFEST")

say "== demo PRs (expect 12, all base main)"
expected=$(jq -r '.prs[] | "\(.repo) \(.branch)"' "$MANIFEST" | sort)
declare -A seen=()
n_open=0
n_main=0
while read -r repo; do
  while IFS=$'\t' read -r num head base title; do
    [ -z "$num" ] && continue
    # only the kit's demo/* heads
    if [[ "$head" != demo/* ]]; then continue; fi
    n_open=$((n_open + 1))
    seen["$repo $head"]=1
    if [ "$base" = main ]; then n_main=$((n_main + 1)); say "  $repo#$num $head -> $base ok"
    else bad "$repo#$num $head -> $base (expected main)"; fi
  done < <(gh pr list --repo "$ORG/$repo" --state open --limit 100 --json number,headRefName,baseRefName,title \
            --jq '.[] | [.number, .headRefName, .baseRefName, .title] | @tsv')
done < <(jq -r '.reset_repos[]' "$MANIFEST")

while read -r repo branch; do
  [ -z "${seen[$repo $branch]:-}" ] && bad "missing open PR $repo $branch"
done <<<"$expected"
[ "$n_open" -eq 12 ] || bad "open demo PRs: $n_open (expected 12)"
[ "$n_main" -eq 12 ] || bad "demo PRs targeting main: $n_main (expected 12)"

say "== docs open PRs (expect none)"
docs_open=$(gh pr list --repo "$ORG/docs" --state open --limit 100 --json number,title,author \
  --jq '.[] | "#\(.number) \(.author.login) \(.title)"')
if [ -n "$docs_open" ]; then bad "open PRs in docs:"$'\n'"$docs_open"
else say "  none ok"; fi

say "== site $SITE/"
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$SITE/" || echo curl-fail)
if [ "$code" = 200 ]; then say "  $code ok"
else bad "site / returned $code (expected 200)"; fi

if [ $fail -ne 0 ]; then say "== verification failed"; exit 1; fi
say "== verification passed"
