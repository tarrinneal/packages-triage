#!/usr/bin/env bash
# Copyright 2013 The Flutter Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Formats, tests, commits, and deploys `script/triage` both to the current
# branch on `origin` and to the standalone GitHub Pages repository (`workflow_repo`
# in `triage.yaml`, defaulting to `tarrinneal/packages-triage`).
#
# Uses core `git commit-tree` instead of `git subtree` so it works out of the box
# on macOS/Linux without extra git add-ons.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

if [[ "$SCRIPT_DIR" == "$REPO_ROOT" ]]; then
  SUBTREE_PREFIX=""
else
  SUBTREE_PREFIX="${SCRIPT_DIR#"$REPO_ROOT"/}"
fi

# Read default workflow_repo from triage.yaml if present.
DEFAULT_DEPLOY_REPO="tarrinneal/packages-triage"
if [[ -f "$SCRIPT_DIR/triage.yaml" ]]; then
  PARSED_REPO="$(sed -n 's/^[[:space:]]*workflow_repo:[[:space:]]*\([^#[:space:]]*\).*/\1/p' "$SCRIPT_DIR/triage.yaml" | head -n 1 | tr -d "\"'")"
  if [[ -n "$PARSED_REPO" ]]; then
    DEFAULT_DEPLOY_REPO="$PARSED_REPO"
  fi
fi

COMMIT_MSG=""
DEPLOY_REPO="$DEFAULT_DEPLOY_REPO"
TARGET_BRANCH="main"
SKIP_CHECKS=false
SKIP_ORIGIN=false
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [commit message]

Formats, analyzes, tests, commits (if needed), and pushes script/triage to both
origin and the standalone GitHub Pages repo ($DEFAULT_DEPLOY_REPO).

Options:
  -m, --message <msg>     Commit message (can also be passed as positional arg)
  -r, --repo <owner/repo> Target GitHub Pages repository (default: $DEFAULT_DEPLOY_REPO)
  -b, --branch <branch>   Target branch in Pages repository (default: main)
      --skip-checks       Skip dart format, dart analyze, and dart test
      --no-origin         Skip pushing the current branch to origin
      --dry-run           Show what would be pushed without pushing
  -h, --help              Show this help message

Examples:
  ./script/triage/deploy.sh "Add floating triage companion"
  ./script/triage/deploy.sh -m "Update config" --skip-checks
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message)
      COMMIT_MSG="${2:-}"
      shift 2
      ;;
    -r|--repo)
      DEPLOY_REPO="${2:-}"
      shift 2
      ;;
    -b|--branch)
      TARGET_BRANCH="${2:-}"
      shift 2
      ;;
    --skip-checks)
      SKIP_CHECKS=true
      shift
      ;;
    --no-origin)
      SKIP_ORIGIN=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "$COMMIT_MSG" ]]; then
        COMMIT_MSG="$1"
      else
        COMMIT_MSG="$COMMIT_MSG $1"
      fi
      shift
      ;;
  esac
done

if [[ "$SKIP_CHECKS" == "false" ]]; then
  echo "==> Running dart format, analyze, and test in $SCRIPT_DIR..."
  (
    cd "$SCRIPT_DIR"
    dart format .
    dart analyze
    dart test
  )
fi

cd "$REPO_ROOT"

PATHSPEC="${SUBTREE_PREFIX:-.}"
if [[ -n "$(git status --porcelain -- "$PATHSPEC")" ]]; then
  if [[ -z "$COMMIT_MSG" ]]; then
    COMMIT_MSG="Update triage tool"
  fi
  echo "==> Staging and committing changes in $PATHSPEC..."
  git add -- "$PATHSPEC"
  git commit -m "$COMMIT_MSG"
else
  echo "==> Working tree clean in $PATHSPEC."
  if [[ -z "$COMMIT_MSG" ]]; then
    COMMIT_MSG="$(git log -1 --format=%s HEAD)"
  fi
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$SKIP_ORIGIN" == "false" && -n "$SUBTREE_PREFIX" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would push $CURRENT_BRANCH to origin"
  else
    echo "==> Pushing $CURRENT_BRANCH to origin..."
    git push origin "$CURRENT_BRANCH"
  fi
fi

DEPLOY_URL="https://github.com/${DEPLOY_REPO}.git"
if [[ -n "$SUBTREE_PREFIX" ]]; then
  TREE_SPEC="HEAD:${SUBTREE_PREFIX}"
else
  TREE_SPEC="HEAD^{tree}"
fi

TREE_SHA="$(git rev-parse --verify "$TREE_SPEC")"
if [[ -z "$TREE_SHA" ]]; then
  echo "Error: Could not resolve git tree for $TREE_SPEC" >&2
  exit 1
fi

echo "==> Fetching $DEPLOY_REPO ($TARGET_BRANCH)..."
git fetch "$DEPLOY_URL" "$TARGET_BRANCH"
REMOTE_TREE_SHA="$(git rev-parse FETCH_HEAD^{tree})"

if [[ "$TREE_SHA" == "$REMOTE_TREE_SHA" ]]; then
  echo "✓ $DEPLOY_REPO ($TARGET_BRANCH) already matches $TREE_SPEC ($TREE_SHA). Nothing to push."
  exit 0
fi

DEPLOY_COMMIT_SHA="$(git commit-tree "$TREE_SHA" -p FETCH_HEAD -m "$COMMIT_MSG")"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] Would push commit $DEPLOY_COMMIT_SHA (tree $TREE_SHA) to $DEPLOY_URL refs/heads/$TARGET_BRANCH"
else
  echo "==> Pushing $TREE_SPEC ($DEPLOY_COMMIT_SHA) to $DEPLOY_REPO ($TARGET_BRANCH)..."
  git push "$DEPLOY_URL" "${DEPLOY_COMMIT_SHA}:refs/heads/${TARGET_BRANCH}"
  echo "✓ Deployed to https://github.com/${DEPLOY_REPO}"
fi
