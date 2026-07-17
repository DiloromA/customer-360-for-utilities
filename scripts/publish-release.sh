#!/usr/bin/env bash
#
# publish-release.sh — publish a major release of this project to one of the
# release mirror repos.
#
# Model:
#   - origin = timstan-db/...   the canonical dev repo, full history (never touched here)
#   - mirrors receive one clean squashed commit per release, tagged vX.Y.Z.
#
# Each mirror has its own persistent orphan branch that accumulates exactly one
# snapshot commit per release. Each snapshot is the *entire tree* of `main` at
# publish time, committed with the previous release as its parent so the mirror's
# history reads as a linear list of releases and `git diff` between releases works.
#
# Mirrors (independent — publish to whichever you want, when you want):
#   internal  -> tim-stanton_data/customer-360-for-utilities        (gh: tim-stanton_data)
#   industry  -> databricks-industry-solutions/customer-360-...     (gh: timstan-db)
#
# Usage:
#   scripts/publish-release.sh --mirror <internal|industry> vX.Y.Z ["changelog"] [--force]
#
#   --force  overwrite the mirror's main (needed the first time a mirror repo
#            already has unrelated history, e.g. a template scaffold commit).
#
# Preconditions:
#   - Run from a clean `main`.
#   - `gh` is logged into both accounts (gh auth login), org SSO authorized.
#   - The mirror's remote + local orphan branch exist (see RELEASING.md setup).
#
set -euo pipefail

# ---- args -------------------------------------------------------------------
MIRROR=""; VERSION=""; CHANGELOG=""; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mirror) MIRROR="${2:-}"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    -*)       echo "unknown flag: $1" >&2; exit 2 ;;
    *)        if [[ -z "$VERSION" ]]; then VERSION="$1"; else CHANGELOG="$1"; fi; shift ;;
  esac
done

usage() { echo "usage: $0 --mirror <internal|industry> vX.Y.Z [\"changelog\"] [--force]" >&2; }

if [[ -z "$MIRROR" || -z "$VERSION" ]]; then usage; exit 2; fi
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like vX.Y.Z (got '$VERSION')" >&2; exit 2
fi

# ---- mirror config ----------------------------------------------------------
SOURCE_BRANCH="main"
REMOTE_BRANCH="main"
case "$MIRROR" in
  internal)
    RELEASE_REMOTE="release";          RELEASE_BRANCH="release"
    PUBLISH_ACCOUNT="tim-stanton_data"; OWNER="tim-stanton_data" ;;
  industry)
    RELEASE_REMOTE="release-industry"; RELEASE_BRANCH="release-industry"
    PUBLISH_ACCOUNT="timstan-db";       OWNER="databricks-industry-solutions" ;;
  *)
    echo "error: unknown mirror '$MIRROR' (want: internal | industry)" >&2; exit 2 ;;
esac
LOCAL_TAG="${MIRROR}/${VERSION}"   # namespaced locally so mirrors never collide
REMOTE_TAG="$VERSION"             # each mirror repo has its own tag namespace

# ---- preconditions ----------------------------------------------------------
current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" != "$SOURCE_BRANCH" ]]; then
  echo "error: publish from '$SOURCE_BRANCH', not '$current_branch'." >&2; exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree not clean. Commit or stash first." >&2; exit 1
fi
if ! git remote get-url "$RELEASE_REMOTE" >/dev/null 2>&1; then
  echo "error: no '$RELEASE_REMOTE' remote. Add it first (see RELEASING.md)." >&2; exit 1
fi
if git rev-parse -q --verify "refs/tags/$LOCAL_TAG" >/dev/null; then
  echo "error: tag $LOCAL_TAG already exists locally." >&2; exit 1
fi
if ! git rev-parse -q --verify "refs/heads/$RELEASE_BRANCH" >/dev/null; then
  echo "error: local '$RELEASE_BRANCH' orphan branch is missing (see RELEASING.md setup)." >&2; exit 1
fi

# ---- build the snapshot commit (pure plumbing, no working-tree churn) -------
tree="$(git rev-parse "${SOURCE_BRANCH}^{tree}")"
parent="$(git rev-parse "$RELEASE_BRANCH")"
source_sha="$(git rev-parse --short "$SOURCE_BRANCH")"

msg="Release ${VERSION}"
[[ -n "$CHANGELOG" ]] && msg="${msg}"$'\n\n'"${CHANGELOG}"
msg="${msg}"$'\n\n'"Snapshot of ${SOURCE_BRANCH} @ ${source_sha}"

echo "==> [$MIRROR] Building snapshot of ${SOURCE_BRANCH} (@ ${source_sha}) as ${VERSION}..."
commit="$(git commit-tree "$tree" -p "$parent" -m "$msg")"

git update-ref "refs/heads/$RELEASE_BRANCH" "$commit"
git tag -a "$LOCAL_TAG" "$commit" -m "$msg"
echo "==> Local ${RELEASE_BRANCH} now at ${commit:0:7}, tagged ${LOCAL_TAG}."

# ---- push to the mirror as the publish account ------------------------------
# The gh credential helper hands git whichever gh account is *active*, so flip
# to the publish account for the push and restore afterward.
prev_account="$(gh auth status --active 2>/dev/null | sed -n 's/.*account \([^ ]*\).*/\1/p' | head -1 || true)"
restore_account() {
  if [[ -n "$prev_account" && "$prev_account" != "$PUBLISH_ACCOUNT" ]]; then
    gh auth switch --user "$prev_account" >/dev/null 2>&1 || true
  fi
}
trap restore_account EXIT

echo "==> Switching gh active account to ${PUBLISH_ACCOUNT} for push..."
gh auth switch --user "$PUBLISH_ACCOUNT" >/dev/null

push_flag=""
[[ "$FORCE" == "1" ]] && push_flag="--force"
echo "==> Pushing ${RELEASE_BRANCH} -> ${RELEASE_REMOTE}/${REMOTE_BRANCH} ${push_flag} and tag ${REMOTE_TAG}..."
git push $push_flag "$RELEASE_REMOTE" "${RELEASE_BRANCH}:${REMOTE_BRANCH}"
git push "$RELEASE_REMOTE" "refs/tags/${LOCAL_TAG}:refs/tags/${REMOTE_TAG}"

echo ""
echo "==> Done. Published ${VERSION} to ${MIRROR} (${OWNER})."
echo "    https://github.com/${OWNER}/customer-360-for-utilities/releases/tag/${REMOTE_TAG}"
