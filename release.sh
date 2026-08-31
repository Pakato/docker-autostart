#!/usr/bin/env bash
# release.sh <version>  e.g.  ./release.sh 1.2.0
#
# Tags the current commit and pushes it. The tag push is what makes GitHub
# Actions build and publish the versioned image tags to Docker Hub.
set -euo pipefail

version="${1:-}"
[ -n "$version" ] || { echo "usage: $0 <version>   (e.g. 1.2.0)" >&2; exit 1; }
version="${version#v}"

if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
    echo "error: '$version' is not semver (X.Y.Z)" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is dirty; commit or stash first" >&2
    exit 1
fi

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || echo "warning: releasing from '$branch', not main"

git fetch --tags --quiet
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    echo "error: tag v$version already exists" >&2
    exit 1
fi

git tag -a "v$version" -m "v$version"
git push origin "v$version"

echo "Pushed v$version. Watch the build:"
echo "  gh run watch \$(gh run list --workflow=docker-publish.yml -L1 --json databaseId -q '.[0].databaseId')"
