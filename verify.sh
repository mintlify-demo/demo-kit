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

say "== docs restore sections (expect identical to their baseline tags)"
while IFS=$'\t' read -r repo btag paths tabs; do
  [ -z "$repo" ] && continue
  # Compare file blobs in the two trees directly. A three-dot compare (tag...main) diffs from the
  # merge base, so it falsely reports files when the baseline tag is not an ancestor of main.
  tree_files() { # repo ref -> "path<TAB>blobsha" for the restored paths
    local t; t=$(gh api "repos/$ORG/$1/git/trees/$2?recursive=1")
    if [ "$(jq -r .truncated <<<"$t")" = true ]; then echo "TRUNCATED"; return; fi
    jq -r --argjson p "$paths" '.tree[] | select(.type == "blob") | select(.path as $f | $p | any(. as $x | $f == $x or ($f | startswith($x + "/")))) | "\(.path)\t\(.sha)"' <<<"$t" | sort
  }
  bfiles=$(tree_files "$repo" "$(gh api "repos/$ORG/$repo/commits/$btag" --jq .sha)")
  mfiles=$(tree_files "$repo" "$(gh api "repos/$ORG/$repo/commits/main" --jq .sha)")
  if [ "$bfiles" = TRUNCATED ] || [ "$mfiles" = TRUNCATED ]; then changed="(tree listing truncated; cannot compare)"
  else changed=$(diff <(echo "$bfiles") <(echo "$mfiles") | sed -n 's/^[<>] \([^\t]*\)\t.*/\1/p' | sort -u || true); fi
  if [ -n "$changed" ]; then bad "$repo files differ from $btag:"$'\n'"$changed"; else say "  $repo $(jq -r 'join(", ")' <<<"$paths") match $btag ok"; fi
  b=$(gh api "repos/$ORG/$repo/contents/docs.json?ref=$btag" -H 'Accept: application/vnd.github.raw')
  m=$(gh api "repos/$ORG/$repo/contents/docs.json?ref=main" -H 'Accept: application/vnd.github.raw')
  q='[.navigation.languages[]? as $l | $l.tabs[] | select(.tab as $t | $names | index($t)) | {lang: $l.language, tab: .}]'
  if [ "$(jq -c --argjson names "$tabs" "$q" <<<"$b")" = "$(jq -c --argjson names "$tabs" "$q" <<<"$m")" ]; then
    say "  $repo nav tab(s) $(jq -r 'join(", ")' <<<"$tabs") match $btag ok"
  else bad "$repo nav tab(s) $(jq -r 'join(", ")' <<<"$tabs") differ from $btag"; fi
done < <(jq -r '.docs_restore[]? | [.repo, .baseline_tag, (.paths | tojson), ((.nav_tabs // []) | tojson)] | @tsv' "$MANIFEST")

say "== public Acme Help Center pages (expect 200, no login redirect)"
for p in "" getting-started plans-and-pricing free-trial shipping refunds contact-us password-help faq; do
  read -r code final < <(curl -sS -L -o /dev/null -w '%{http_code} %{url_effective}\n' --max-time 30 "$SITE/acme/$p" || echo "curl-fail -")
  if [ "$code" = 200 ] && [[ "$final" == "$SITE/acme"* ]]; then say "  /acme/$p $code ok"
  else bad "/acme/$p returned $code ($final)"; fi
done

say "== Spanish and French Acme pages (expect 200, no login redirect)"
for lang in es fr; do
  for p in "" plans-and-pricing refunds faq; do
    read -r code final < <(curl -sS -L -o /dev/null -w '%{http_code} %{url_effective}\n' --max-time 30 "$SITE/$lang/acme/$p" || echo "curl-fail -")
    if [ "$code" = 200 ] && [[ "$final" == "$SITE/$lang/acme"* ]]; then say "  /$lang/acme/$p $code ok"
    else bad "/$lang/acme/$p returned $code ($final)"; fi
  done
done

say "== Acme staff handbook (expect a login redirect for signed-out readers)"
loc=$(curl -sS -o /dev/null -w '%{redirect_url}' --max-time 30 "$SITE/acme/staff-handbook" || echo curl-fail)
if [[ "$loc" == *"/login"* ]]; then say "  /acme/staff-handbook -> login ok"
else bad "/acme/staff-handbook did not redirect to login ($loc)"; fi

say "== Acme Support Playbook (internal; expect a login redirect for signed-out readers)"
for p in index escalation-process refund-approvals hours-and-on-call; do
  loc=$(curl -sS -o /dev/null -w '%{redirect_url}' --max-time 30 "$SITE/playbook/$p" || echo curl-fail)
  if [[ "$loc" == *"/login"* ]]; then say "  /playbook/$p -> login ok"
  else bad "/playbook/$p did not redirect to login ($loc)"; fi
done

say "== site $SITE/"
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$SITE/" || echo curl-fail)
if [ "$code" = 200 ]; then say "  $code ok"
else bad "site / returned $code (expected 200)"; fi

if [ $fail -ne 0 ]; then say "== verification failed"; exit 1; fi
say "== verification passed"
