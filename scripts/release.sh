#!/usr/bin/env bash
# Cut a release tag from a repo's VERSION file (generalized from the phosphor pattern).
#
# Usage: scripts/release.sh [repo-dir]   (default: the current repo)
#
# Validates: strict SemVer in VERSION, a clean working tree, tag == vVERSION (and that HEAD is not
# already tagged with a different version), and a monotonic bump over the latest existing vX.Y.Z
# tag. Set DRY_RUN=1 to preview without tagging. Pure git + coreutils (no python).
set -euo pipefail

cd "${1:-.}"
cd "$(git rev-parse --show-toplevel)"
name="$(basename "$PWD")"

die() {
  echo "release($name): $*" >&2
  exit 1
}
note() { echo "release($name): $*"; }

base="$(tr -d '\r\n' <VERSION 2>/dev/null || true)"
[ -n "$base" ] || die "VERSION file is empty/missing"

# Strict SemVer (no prerelease/build metadata) for tags.
if ! [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "VERSION must be SemVer 'X.Y.Z' (got: '$base')"
fi

tag="v$base"

# Require a clean tree for a release.
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "working tree is dirty (commit or stash changes before tagging a release)"
fi

# Do not allow tagging a commit already tagged with a different version.
head_tag="$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)"
if [ -n "$head_tag" ] && [ "$head_tag" != "$tag" ]; then
  die "HEAD is already tagged as '$head_tag' (refusing to also tag '$tag')"
fi

# Tag must not already exist elsewhere.
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  if [ -n "$head_tag" ] && [ "$head_tag" = "$tag" ]; then
    note "tag '$tag' already exists on HEAD (nothing to do)"
    exit 0
  fi
  die "tag '$tag' already exists (bump VERSION first)"
fi

# Ensure this is a bump over the latest existing vX.Y.Z tag (if any), via version sort.
latest="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -n 1 || true)"
if [ -n "$latest" ]; then
  highest="$(printf '%s\n%s\n' "$latest" "$tag" | sort -V | tail -n 1)"
  if [ "$tag" = "$latest" ] || [ "$highest" != "$tag" ]; then
    die "VERSION ($base) is not a bump over the latest tag (${latest#v})"
  fi
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  note "DRY_RUN=1; would run: git tag -a '$tag' -m '$name $tag'"
  exit 0
fi

note "tagging HEAD with '$tag'"
git tag -a "$tag" -m "$name $tag"
note "created tag '$tag'"
note "next: git push origin '$tag'  (or: git push --tags)"
