#!/usr/bin/env bash
# Merge the latest make-all/tuya-local release into the fork on a branch,
# resolve the conflicts the fork always has the same way, and open a pull
# request that the Auto-merge workflow merges once CI passes.
#
# Resolved here:
# - .github/workflows: the fork's own workflows replace upstream's, so any
#   upstream workflow file is removed.
# - manifest.json / pyproject.toml: conflict hunks with the "version" line
#   keep the fork's version (release-please owns it); other hunks (the
#   requirements) take upstream's.
# - commits listed in .github/upstream-sync-excludes are reverted on top of
#   the release before the merge, so they never reach the fork.
# Any other conflict stops the sync and opens an issue: resolve it by hand
# as README.md ("Sync with upstream") describes.
#
# Needs GH_TOKEN with contents, pull requests, issues and workflows write
# access, and the upstream remote fetchable.
set -euo pipefail

UPSTREAM_REPO=${UPSTREAM_REPO:-make-all/tuya-local}
REPO=${GITHUB_REPOSITORY:?}
EXCLUDES=.github/upstream-sync-excludes

git remote get-url upstream >/dev/null 2>&1 ||
  git remote add upstream "https://github.com/$UPSTREAM_REPO.git"
git fetch --quiet --tags upstream

TAG=$(gh release view --repo "$UPSTREAM_REPO" --json tagName --jq .tagName)
VERSION=$(git show "$TAG:custom_components/tuya_local/manifest.json" | jq -r .version)
BRANCH="sync/upstream-$VERSION"
echo "Latest upstream release: $TAG (version $VERSION)"

if git merge-base --is-ancestor "$TAG" HEAD; then
  echo "Already merged: nothing to do"
  exit 0
fi
if [ -n "$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number --jq '.[].number')" ]; then
  echo "A pull request for $BRANCH is already open"
  exit 0
fi

open_issue() {
  local title="Upstream sync to $VERSION needs manual resolution"
  if [ -n "$(gh issue list --repo "$REPO" --state open --search "\"$title\" in:title" --json number --jq '.[].number')" ]; then
    echo "Issue already open: $title"
    return
  fi
  gh issue create --repo "$REPO" --title "$title" --body "$(printf '%s\n\n%s\n\n```\n%s\n```\n\n%s' \
    "The weekly sync could not merge \`$TAG\` from $UPSTREAM_REPO on its own." \
    "$1" "$2" \
    "Resolve it by hand as README.md (\"Sync with upstream\") describes. The next weekly run picks up later releases once \`$TAG\` is merged.")"
}

FORK_HEAD=$(git rev-parse HEAD)
FORK_WORKFLOWS=$(git ls-files .github/workflows)
EXCLUDED=$(grep -Eo '^[0-9a-f]{7,40}' "$EXCLUDES" 2>/dev/null || true)

# Revert the listed upstream commits this release brings in on top of the
# release itself, where they revert cleanly, so they never reach the merge.
git checkout --quiet --detach "$TAG"
for sha in $EXCLUDED; do
  git cat-file -e "$sha^{commit}" 2>/dev/null || continue
  git merge-base --is-ancestor "$sha" "$TAG" || continue
  git merge-base --is-ancestor "$sha" "$FORK_HEAD" && continue
  if ! git revert --no-edit "$sha" >/dev/null 2>&1; then
    git revert --abort
    git checkout --quiet "$FORK_HEAD"
    open_issue "Excluded upstream commit $sha does not revert cleanly on $TAG:" \
      "$(git log -1 --format='%h %s' "$sha")"
    exit 1
  fi
  echo "Excluded $(git log -1 --format='%h %s' "$sha")"
done
UPSTREAM_REF=$(git rev-parse HEAD)

git checkout --quiet -B "$BRANCH" "$FORK_HEAD"
git merge --no-ff --no-commit "$UPSTREAM_REF" >/dev/null 2>&1 || true

# Upstream workflow files, new or changed, never land in the fork.
git ls-files .github/workflows | sort -u | while read -r f; do
  grep -qxF "$f" <<<"$FORK_WORKFLOWS" || git rm --quiet -f -- "$f"
done

# Keep the fork's version, take upstream's requirements.
for f in custom_components/tuya_local/manifest.json pyproject.toml; do
  git diff --name-only --diff-filter=U | grep -qxF "$f" || continue
  python3 - "$f" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8", newline="").read()
hunk = re.compile(r"<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n", re.S)
text = hunk.sub(lambda m: m.group(1) if '"version"' in m.group(1) or re.search(r"^version\s*=", m.group(1), re.M) else m.group(2), text)
if "<<<<<<<" in text:
    sys.exit(f"{path}: unresolved conflict")
open(path, "w", encoding="utf-8", newline="").write(text)
PY
  git add -- "$f"
done

CONFLICTS=$(git diff --name-only --diff-filter=U)
if [ -n "$CONFLICTS" ]; then
  git merge --abort
  open_issue "These files conflict:" "$CONFLICTS"
  exit 1
fi
git commit --quiet --no-edit -m "Merge upstream release $VERSION" \
  -m "Merged by the weekly upstream sync (.github/workflows/upstream-sync.yml)."

git commit --quiet --allow-empty -m "chore: release $VERSION-fork.1" -m "Release-As: $VERSION-fork.1"
git push --quiet --force origin "$BRANCH"

gh label create upstream-sync --repo "$REPO" --color 0e8a16 \
  --description "Weekly merge of an upstream release" 2>/dev/null || true
gh pr create --repo "$REPO" --base main --head "$BRANCH" --label upstream-sync \
  --title "chore: merge upstream release $VERSION" \
  --body "Merges [$UPSTREAM_REPO $TAG](https://github.com/$UPSTREAM_REPO/releases/tag/$TAG) and releases it as \`$VERSION-fork.1\`.

Opened by the weekly upstream sync. Upstream workflow files are removed, the fork's version is kept, and commits listed in \`$EXCLUDES\` are reverted. Auto-merge merges it with a merge commit once every check passes, so the next sync keeps its merge base."
