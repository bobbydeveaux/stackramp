#!/usr/bin/env bash
# Is the pull request behind a PR preview environment already closed?
#
# Usage: pr-closed.sh <environment> <owner/repo>
#   GH_TOKEN        token that can read the repo's pull requests
#   GITHUB_API_URL  optional (GitHub Enterprise); default https://api.github.com
#
# Prints two lines for $GITHUB_OUTPUT on stdout:
#   closed=<true|false>  true only when GitHub says the PR is closed (merged
#                        or not). Not a preview (dev, prod) -> false, no call.
#   pr=<number>          the PR number, empty when not a preview
#
# Fails open: when GitHub can't be asked, it prints closed=false and a
# warning, so a GitHub API hiccup never blocks a preview deploy. The
# preview sweep (providers/gcp/workflows/preview-sweep) is the backstop.
set -uo pipefail

ENVIRONMENT="${1:-}"
REPO="${2:-}"

if [[ ! "$ENVIRONMENT" =~ ^pr-([0-9]+)$ ]]; then
  echo "closed=false"
  echo "pr="
  exit 0
fi
PR="${BASH_REMATCH[1]}"
echo "pr=${PR}"

API="${GITHUB_API_URL:-https://api.github.com}"
if ! BODY=$(curl -sSf --max-time 20 --retry 2 \
    -H "Authorization: Bearer ${GH_TOKEN:-}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/repos/${REPO}/pulls/${PR}" 2>&1); then
  echo "::warning::Could not read the state of PR #${PR} (${BODY}); deploying the preview anyway" >&2
  echo "closed=false"
  exit 0
fi

STATE=$(jq -r '.state // ""' <<<"$BODY" 2>/dev/null || true)
if [ "$STATE" = "closed" ]; then
  echo "PR #${PR} is closed; the preview must not exist" >&2
  echo "closed=true"
else
  [ "$STATE" = "open" ] || echo "::warning::PR #${PR} state '${STATE}' unknown; deploying the preview anyway" >&2
  echo "closed=false"
fi
