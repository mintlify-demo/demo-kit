#!/usr/bin/env bash
# Reset the mintlify-demo GitHub org to its demo starting state.
#
#   ./reset.sh             full reset (close PRs, reset main, recreate branches, reopen PRs)
#   ./reset.sh --dry-run   print every action, change nothing (read-only API calls only)
#   ./reset.sh --only-open only (re)create the demo branches and open missing demo PRs;
#                          never closes PRs or touches main
#
# reset_repos (API repos): main is force-reset to the demo-baseline tag.
# docs_safe_repos (docs):  main is NEVER force-pushed. Open PRs by the Mintlify app/Autopilot
#   are closed; bot PRs merged since the demo-reset-last tag are reverted in one commit
#   (conflicting reverts are skipped with a WARNING). Exit code 3 = finished with warnings.
#
# Safe to run repeatedly. Needs: gh (authed with repo scope), jq, git.
# Demo PRs are opened against main (not stacked). Each demo/* branch already contains the
# commits below it, so they merge in any order.
# Source of the demo commits: the demo-src/* backup branches on GitHub; if one is missing,
# the script rebuilds it from patches/<repo>/*.patch on top of the demo-baseline tag.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$KIT/manifest.json"
DRY=0; ONLY_OPEN=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --only-open) ONLY_OPEN=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

mkdir -p "$KIT/logs"
LOG="$KIT/logs/reset-$(date +%Y%m%d-%H%M%S)$( [ $DRY = 1 ] && echo -dryrun || true ).log"
exec > >(tee -a "$LOG") 2>&1

ORG=$(jq -r .org "$MANIFEST")
TAG=$(jq -r .baseline_tag "$MANIFEST")
BACKUP_PREFIX=$(jq -r .backup_prefix "$MANIFEST")
mapfile -t REPOS < <(jq -r '.reset_repos[]' "$MANIFEST")
GIT_NAME="DeweyMarco"; GIT_EMAIL="marco@mintlify.com"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
run()  { if [ $DRY = 1 ]; then echo "  DRY-RUN: $*"; else "$@"; fi; }
api()  { gh api "$@"; }

log "mintlify-demo reset starting (dry_run=$DRY only_open=$ONLY_OPEN) log=$LOG"
gh auth status >/dev/null 2>&1 || { log "ERROR: gh is not authenticated"; exit 1; }
for bin in jq git; do command -v "$bin" >/dev/null || { log "ERROR: $bin is not installed"; exit 1; }; done

# Optional local venv for running the API repos and their tests (the reset itself does not
# use it). Defaults to $KIT/.venv so this works on a GitHub Actions runner as well as a
# local clone. Skip with SKIP_VENV=1 (the nightly workflow does). Override the path with DEMO_VENV.
if [ "${SKIP_VENV:-}" != 1 ] && [ "${GITHUB_ACTIONS:-}" != true ]; then
  VENV="${DEMO_VENV:-$KIT/.venv}"
  if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -c 'import fastapi, pytest, strawberry' 2>/dev/null; then
    if [ $DRY = 1 ]; then echo "  DRY-RUN: create venv $VENV from requirements-dev.txt"
    elif python3 -m venv "$VENV" && "$VENV/bin/pip" install -q -r "$KIT/requirements-dev.txt"; then log "  created venv $VENV"
    else log "WARNING: could not create venv $VENV (reset continues)"; fi
  fi
fi

# Resolve the commit a tag points at (handles annotated tags).
tag_commit() {
  local repo=$1 ref type sha
  ref=$(api "repos/$ORG/$repo/git/ref/tags/$TAG")
  type=$(jq -r .object.type <<<"$ref"); sha=$(jq -r .object.sha <<<"$ref")
  if [ "$type" = tag ]; then sha=$(api "repos/$ORG/$repo/git/tags/$sha" --jq .object.sha); fi
  echo "$sha"
}
# Print a ref's sha, or nothing if it doesn't exist (gh prints the 404 body on stdout, so discard it).
ref_sha() { local out; if out=$(api "repos/$ORG/$1/git/ref/$2" --jq .object.sha 2>/dev/null); then echo "$out"; fi; }
branch_sha() { ref_sha "$1" "heads/$2"; }

# Point refs/heads/<branch> at <sha>, creating or force-updating it.
set_branch() {
  local repo=$1 branch=$2 sha=$3 cur
  cur=$(branch_sha "$repo" "$branch")
  if [ "$cur" = "$sha" ]; then log "  $repo:$branch already at ${sha:0:7}"; return; fi
  if [ -n "$cur" ]; then
    log "  $repo:$branch ${cur:0:7} -> ${sha:0:7} (force)"
    run api -X PATCH "repos/$ORG/$repo/git/refs/heads/$branch" -f sha="$sha" -F force=true --silent
  else
    log "  $repo:$branch create at ${sha:0:7}"
    run api -X POST "repos/$ORG/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$sha" --silent
  fi
}

# Rebuild missing demo-src/* backups for a repo from the saved patch series.
rebuild_backups_from_patches() {
  local repo=$1 base=$2 tmp
  log "  $repo: rebuilding backup branches from patches"
  if [ $DRY = 1 ]; then echo "  DRY-RUN: clone, git am patches/$repo/*.patch onto ${base:0:7}, push ${BACKUP_PREFIX}*"; return; fi
  tmp=$(mktemp -d)
  git clone -q "https://github.com/$ORG/$repo.git" "$tmp/$repo"
  (
    cd "$tmp/$repo"
    git checkout -q "$base"
    while read -r order backup patch; do
      git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" am -q "$KIT/$patch"
      git push -q -f origin "HEAD:refs/heads/$backup"
    done < <(jq -r --arg r "$repo" '.prs[] | select(.repo==$r) | "\(.order) \(.backup_branch) \(.patch)"' "$MANIFEST" | sort -n)
  )
  rm -rf "$tmp"
}

declare -A BASELINE
for repo in "${REPOS[@]}"; do BASELINE[$repo]=$(tag_commit "$repo"); log "$repo: $TAG = ${BASELINE[$repo]:0:7}"; done

# ---- 0. Docs-safe repos: never force-push. Close bot PRs, revert merged bot PRs. -----------
WARNINGS=()
warn() { log "WARNING: $*"; WARNINGS+=("$*"); }
mapfile -t DOCS_REPOS < <(jq -r '.docs_safe_repos[]?' "$MANIFEST")
MARKER=$(jq -r '.docs_marker_tag // "demo-reset-last"' "$MANIFEST")
BOT_RE=$(jq -r '.bot_author_regex' "$MANIFEST")

docs_safe_reset() {
  local repo=$1 prs tmp marker_sha head_sha inrange reverted=() n
  log "$repo: docs-safe handling (no force-push; bot regex: $BOT_RE)"

  # (a) close open PRs authored by the Mintlify app / Autopilot, delete their branches
  prs=$(gh pr list --repo "$ORG/$repo" --state open --limit 200 \
        --json number,title,headRefName,isCrossRepository,author)
  while IFS=$'\t' read -r num head cross author title; do
    [ -z "$num" ] && continue
    log "  close bot PR #$num [$author] $head: $title"
    run gh pr close "$num" --repo "$ORG/$repo" --comment "Closed by the nightly demo reset." \
      || warn "$repo: could not close #$num"
    if [ "$cross" = false ] && [ "$head" != main ] && [ -n "$(branch_sha "$repo" "$head")" ]; then
      log "  delete branch $head"
      run api -X DELETE "repos/$ORG/$repo/git/refs/heads/$head" --silent || warn "$repo: could not delete $head"
    fi
  done < <(jq -r --arg re "$BOT_RE" '.[] | select(.author.login | test($re; "i"))
           | [.number, .headRefName, .isCrossRepository, .author.login, .title] | @tsv' <<<"$prs")
  jq -r --arg re "$BOT_RE" '.[] | select(.author.login | test($re; "i") | not)
        | "  leave open #\(.number) [\(.author.login)] \(.title)"' <<<"$prs"

  # (b) revert bot PRs merged into main since the marker tag (or demo-baseline on first run)
  marker_sha=$(ref_sha "$repo" "tags/$MARKER")
  if [ -z "$marker_sha" ]; then marker_sha=${BASELINE[$repo]}; log "  no $MARKER tag yet; using $TAG (${marker_sha:0:7})"; fi
  head_sha=$(branch_sha "$repo" main)
  log "  main=${head_sha:0:7}, looking for merged bot PRs after ${marker_sha:0:7}"

  tmp=$(mktemp -d)
  git clone -q "https://github.com/$ORG/$repo.git" "$tmp/$repo"
  cd "$tmp/$repo"
  git config user.name "$GIT_NAME"; git config user.email "$GIT_EMAIL"
  inrange=$(git rev-list "$marker_sha..origin/main")
  # merged bot PRs whose merge commit is in marker..main, newest first
  mapfile -t TO_REVERT < <(gh pr list --repo "$ORG/$repo" --state merged --base main --limit 200 \
      --json number,title,author,mergeCommit,mergedAt \
    | jq -r --arg re "$BOT_RE" '[.[] | select(.author.login | test($re; "i")) | select(.mergeCommit != null)]
                                 | sort_by(.mergedAt) | reverse | .[] | "\(.mergeCommit.oid)\t\(.number)\t\(.title)"' \
    | while IFS=$'\t' read -r sha num title; do grep -qx "$sha" <<<"$inrange" && printf '%s\t%s\t%s\n' "$sha" "$num" "$title"; done)
  n=${#TO_REVERT[@]}
  log "  $n merged bot PR(s) to revert"
  for line in "${TO_REVERT[@]}"; do
    IFS=$'\t' read -r sha num title <<<"$line"
    parents=$(git rev-list --parents -n1 "$sha" | wc -w)
    mflag=(); [ "$parents" -gt 2 ] && mflag=(-m 1)
    if git revert --no-edit "${mflag[@]}" "$sha" >/dev/null 2>&1; then
      log "  reverted #$num (${sha:0:7}) $title"; reverted+=("#$num $title")
    else
      git revert --abort >/dev/null 2>&1 || git reset -q --hard HEAD
      warn "$repo: revert of #$num (${sha:0:7}) '$title' CONFLICTS with later edits; skipped, revert it by hand"
    fi
  done
  if [ ${#reverted[@]} -gt 0 ]; then
    # squash the individual reverts into one commit
    git reset -q --soft origin/main
    git commit -q -m "Demo reset: revert Mintlify automation docs updates" \
      -m "$(printf 'Reverted:\n'; printf -- '- %s\n' "${reverted[@]}")"
    log "  revert commit $(git rev-parse --short HEAD) on top of ${head_sha:0:7}"
    if [ $DRY = 1 ]; then echo "  DRY-RUN: git push origin HEAD:main (fast-forward, no force)"
    elif git push -q origin HEAD:main; then log "  pushed revert to $repo main"
    else warn "$repo: push of revert commit rejected (main moved?); not forced, rerun reset"; fi
  fi
  head_sha=$( [ $DRY = 1 ] && echo "$head_sha" || git rev-parse HEAD )
  [ ${#reverted[@]} -eq 0 ] && head_sha=$(git rev-parse origin/main)
  cd "$KIT"; rm -rf "$tmp"

  # move the marker tag to the new main
  if [ -n "$(ref_sha "$repo" "tags/$MARKER")" ]; then
    log "  move tag $MARKER -> ${head_sha:0:7}"
    run api -X PATCH "repos/$ORG/$repo/git/refs/tags/$MARKER" -f sha="$head_sha" -F force=true --silent
  else
    log "  create tag $MARKER at ${head_sha:0:7}"
    run api -X POST "repos/$ORG/$repo/git/refs" -f ref="refs/tags/$MARKER" -f sha="$head_sha" --silent
  fi
}

if [ $ONLY_OPEN = 0 ]; then
  log "== Step 0: docs-safe repos"
  for repo in "${DOCS_REPOS[@]}"; do
    BASELINE[$repo]=$(tag_commit "$repo")
    docs_safe_reset "$repo"
  done
fi

if [ $ONLY_OPEN = 0 ]; then
  # ---- 1. Close every open PR and delete its head branch ---------------------------------
  log "== Step 1: close open PRs"
  for repo in "${REPOS[@]}"; do
    prs=$(gh pr list --repo "$ORG/$repo" --state open --limit 200 \
          --json number,title,headRefName,isCrossRepository,author)
    n=$(jq length <<<"$prs")
    log "$repo: $n open PR(s)"
    # Close highest-numbered first (stable order; PRs are independent and all target main).
    while IFS=$'\t' read -r num head cross author title; do
      [ -z "$num" ] && continue
      log "  close #$num [$author] $head: $title"
      run gh pr close "$num" --repo "$ORG/$repo" --comment "Closed by the nightly demo reset." \
        || log "  WARN: could not close #$num (already closed?)"
      if [ "$cross" = false ] && [ "$head" != main ] && [[ "$head" != "$BACKUP_PREFIX"* ]]; then
        if [ -n "$(branch_sha "$repo" "$head")" ]; then
          log "  delete branch $head"
          run api -X DELETE "repos/$ORG/$repo/git/refs/heads/$head" --silent || log "  WARN: could not delete $head"
        fi
      fi
    done < <(jq -r 'sort_by(-.number)[] | [.number, .headRefName, .isCrossRepository, .author.login, .title] | @tsv' <<<"$prs")
    # Leftover demo/* branches without an open PR (e.g. merged but not auto-deleted).
    while read -r b; do
      [ -z "$b" ] && continue
      log "  delete leftover branch $b"
      run api -X DELETE "repos/$ORG/$repo/git/refs/heads/$b" --silent || log "  WARN: could not delete $b"
    done < <(api "repos/$ORG/$repo/git/matching-refs/heads/demo/" --jq '.[].ref | sub("^refs/heads/"; "")' 2>/dev/null | grep '^demo/' || true)
  done

  # ---- 2. Force main back to the baseline tag ---------------------------------------------
  log "== Step 2: reset main to $TAG"
  for repo in "${REPOS[@]}"; do set_branch "$repo" main "${BASELINE[$repo]}"; done
fi

# ---- 3. Recreate demo branches from the backups -----------------------------------------
log "== Step 3: recreate demo branches"
for repo in $(jq -r '[.prs[].repo] | unique | .[]' "$MANIFEST"); do
  missing=0
  while read -r backup; do
    [ -z "$(branch_sha "$repo" "$backup")" ] && missing=1
  done < <(jq -r --arg r "$repo" '.prs[] | select(.repo==$r) | .backup_branch' "$MANIFEST")
  if [ $missing = 1 ]; then rebuild_backups_from_patches "$repo" "${BASELINE[$repo]}"; fi
  while read -r branch backup; do
    sha=$(branch_sha "$repo" "$backup")
    if [ -z "$sha" ]; then log "  $repo:$branch (backup $backup would be rebuilt from patches)"; continue; fi
    set_branch "$repo" "$branch" "$sha"
  done < <(jq -r --arg r "$repo" '.prs[] | select(.repo==$r) | "\(.branch) \(.backup_branch)"' "$MANIFEST")
done

# ---- 4. Open the demo PRs (each against main) ------------------------------------------
log "== Step 4: open demo PRs"
SUMMARY=()
count=$(jq '.prs | length' "$MANIFEST")
for i in $(seq 0 $((count - 1))); do
  pr=$(jq ".prs[$i]" "$MANIFEST")
  repo=$(jq -r .repo <<<"$pr"); branch=$(jq -r .branch <<<"$pr"); base=main
  title=$(jq -r .title <<<"$pr"); body=$(jq -r .body <<<"$pr")
  existing=$(gh pr list --repo "$ORG/$repo" --state open --head "$branch" --json url --jq '.[0].url // empty')
  if [ -n "$existing" ]; then
    log "  $repo $branch -> $base: already open $existing"; SUMMARY+=("$repo | $title | $existing"); continue
  fi
  log "  $repo: open '$title' ($branch -> $base)"
  if [ $DRY = 1 ]; then
    echo "  DRY-RUN: gh pr create --repo $ORG/$repo --head $branch --base $base --title \"$title\""
    SUMMARY+=("$repo | $title | (dry-run)")
  else
    url=$(gh pr create --repo "$ORG/$repo" --head "$branch" --base "$base" --title "$title" --body "$body")
    SUMMARY+=("$repo | $title | $url")
  fi
done

log "== Summary"
printf '  %s\n' "${SUMMARY[@]}"
if [ ${#WARNINGS[@]} -gt 0 ]; then
  log "== WARNINGS (${#WARNINGS[@]})"; printf '  WARNING: %s\n' "${WARNINGS[@]}"
  log "done with warnings. log: $LOG"; exit 3
fi
log "done. log: $LOG"
