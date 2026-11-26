#!/usr/bin/env bash
# Publish this repository on GitHub. Run it yourself, with the GitHub CLI logged in (gh auth login):
#
#   scripts/publish-github.sh                 # creates <you>/pgsmith, public
#   scripts/publish-github.sh my-org/pgsmith
#
# Creates the repository from this directory, pushes the current branch, and sets the
# description, website and topics. It never commits for you: commit first.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=${1:-pgsmith}
DESCRIPTION="Flagsmith feature flags, evaluated inside Postgres: the same answers as Flagsmith's engine, compiled to SQL the planner inlines, synced from inside the database. Plus FlagShift, a terraform plan for flag changes."
TOPICS=(postgresql postgres-extension feature-flags feature-toggles flagsmith supabase pg-tle sql ab-testing
        experimentation devtools open-source self-hosted)

command -v gh >/dev/null || { echo "Install the GitHub CLI first: https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Log in first: gh auth login" >&2; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
  echo "There are uncommitted changes. Commit them (git add -A && git commit), then run this again." >&2
  exit 1
fi

if git remote get-url origin >/dev/null 2>&1; then
  echo "origin already set: $(git remote get-url origin); pushing there."
  git push -u origin HEAD
else
  gh repo create "$REPO" --public --source . --remote origin --description "$DESCRIPTION" --push
fi
FULL=$(gh repo view --json nameWithOwner -q .nameWithOwner)
args=(); for t in "${TOPICS[@]}"; do args+=(--add-topic "$t"); done
gh repo edit "$FULL" --description "$DESCRIPTION" --enable-issues --enable-discussions "${args[@]}"

cat <<EOF

Published: https://github.com/$FULL

Two things the CLI cannot do:
  1. Social preview: Settings -> General -> Social preview -> upload assets/social-preview.png
  2. Private vulnerability reporting: Settings -> Security -> enable "Private vulnerability reporting"

Then, optionally:
  - CI badge for README.md:
      [![CI](https://github.com/$FULL/actions/workflows/ci.yml/badge.svg)](https://github.com/$FULL/actions/workflows/ci.yml)
  - Point the example workflow at your action: demos/flagshift/github/flagshift.yml uses your-org/pgsmith/action
  - Release: git tag v$(cat extension/VERSION) && git push --tags   (assets + ghcr.io/$FULL/sync image)
  - database.dev: cd extension/dist/dbdev && dbdev publish
EOF
