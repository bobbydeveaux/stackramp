#!/usr/bin/env bash
# Delete ONE app's PR preview resources whose pull request is closed.
#
# What counts as this app's preview (nothing else is ever touched):
#   Cloud Run services named exactly
#     {app}-pr-N         primary backend
#     {app}-{name}-pr-N  each named entry of the parsed `backends` output
#                        (the mcp block and every backends[] entry)
#   unless labelled stackramp-app=<another app>; or labelled
#   stackramp-app={app} and stackramp-pr=N with a name ending -pr-N (preview
#   deploys add these labels, so a backend since removed from stackramp.yaml
#   is still found). N is digits only. Prefix matching is exact, so app
#   "qbot" never matches "qbot-ai-pr-5" of app "qbot-ai". (The SSO frontend
#   is never deployed for PRs, so there is no {app}-fe-pr-N.)
#   Firebase Hosting channels pr-N on the app's dev site: site_id_dev from
#   the app's Terraform state, else a unique {app}-dev / {app}-xxxxx-dev.
#
# Env:
#   APP_NAME   stackramp.yaml `name`
#   BACKENDS   JSON `backends` output of platform-action (may be empty)
#   PROJECT    GCP platform project
#   REGION     Cloud Run region
#   PR_NUM     cleanup mode: only PR N, treated as closed without asking
#              GitHub (the run on PR close). Unset: sweep mode, every
#              preview found, each PR's state asked from GitHub.
#   REPO       owner/repo (sweep mode)
#   GH_TOKEN   token that can read pull requests (sweep mode)
#   DRY_RUN    true: list what would be deleted, delete nothing
#   QUOTA_PROJECT  optional: sent as x-goog-user-project to Firebase (needed
#              only when running locally with user credentials)
#
# Lists everything first, then deletes. A PR whose state can't be read is
# kept (warning). Exits non-zero when Cloud Run can't be listed or a delete
# failed (a service already gone is fine); Firebase listing problems are
# warnings only (as before), a failed channel delete is an error.
set -euo pipefail

: "${APP_NAME:?}" "${PROJECT:?}" "${REGION:?}"
BACKENDS="${BACKENDS:-}"
[ -n "$BACKENDS" ] || BACKENDS="[]"
PR_NUM="${PR_NUM:-}"
DRY_RUN="${DRY_RUN:-false}"
API_GH="${GITHUB_API_URL:-https://api.github.com}"
API_FB="https://firebasehosting.googleapis.com/v1beta1"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ -n "$PR_NUM" ] && [[ ! "$PR_NUM" =~ ^[0-9]+$ ]]; then
  echo "::error::PR_NUM must be a number, got '${PR_NUM}'"; exit 1
fi

# ── 1. Cloud Run: candidate preview services, "N<TAB>service" ─────────────────
PREFIXES=$(jq -c --arg app "$APP_NAME" \
  '[$app] + [.[]? | select((.name // "") != "") | "\($app)-\(.name)"] | unique' \
  <<<"$BACKENDS")

# One list call; fails the script on auth/permission errors.
SERVICES_JSON=$(gcloud run services list --region="$REGION" --project="$PROJECT" --format=json)

SVC_LINES=$(jq -r --argjson p "$PREFIXES" --arg app "$APP_NAME" '
  def prnum($n; $x):
    if ($n | startswith($x + "-pr-")) then
      ($n[(($x | length) + 4):]) as $r
      | if ($r | test("^[0-9]+$")) then $r else empty end
    else empty end;
  .[] | .metadata.name as $n | (.metadata.labels // {}) as $l
  | ( (if ($l["stackramp-app"] // $app) == $app then [ $p[] as $x | prnum($n; $x) ] else [] end)
      + ( ($l["stackramp-pr"] // "") as $pr
          | if ($l["stackramp-app"] // "") == $app and ($pr | test("^[0-9]+$"))
               and ($n | endswith("-pr-" + $pr))
            then [$pr] else [] end ) )
  | unique | .[] | "\(.)\t\($n)"' <<<"$SERVICES_JSON" | sort -u)

# ── 2. Firebase: the app's dev site and its pr-N channels ────────────────────
# Dev sites are "{app}-{5 char suffix}-dev" (platform/main.tf), or "{app}-dev"
# for sites created before the suffix existed. The firebase CLI needs a
# firebase.json, so use the Hosting REST API directly.
SITE_ID=$(gcloud storage cat "gs://${PROJECT}-tf-state/${APP_NAME}-dev/default.tfstate" 2>/dev/null \
  | jq -r '.outputs.site_id.value // ""' 2>/dev/null || true)
CHANNEL_PRS=""
FB_TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
FB_H=(-H "Authorization: Bearer $FB_TOKEN")
[ -z "${QUOTA_PROJECT:-}" ] || FB_H+=(-H "x-goog-user-project: ${QUOTA_PROJECT}")
if [ -z "$FB_TOKEN" ]; then
  echo "::warning::No access token for Firebase; skipping preview channels"
  SITE_ID=""
elif [ -z "$SITE_ID" ]; then
  if SITES=$(curl -sf "${FB_H[@]}" \
      "${API_FB}/projects/${PROJECT}/sites?pageSize=200" \
      | jq -r '.sites[]?.name | split("/") | last'); then
    if grep -qx "${APP_NAME}-dev" <<<"$SITES"; then
      SITE_ID="${APP_NAME}-dev"
    else
      MATCHES=$(grep -E "^${APP_NAME}-[a-z0-9]{5}-dev$" <<<"$SITES" || true)
      if [ "$(grep -c . <<<"$MATCHES" || true)" = "1" ]; then
        SITE_ID="$MATCHES"
      else
        echo "No single Firebase dev site for ${APP_NAME} (found: ${MATCHES:-none}); no channels to check"
      fi
    fi
  else
    echo "::warning::Could not list Firebase sites; skipping preview channels"
  fi
fi

if [ -n "$SITE_ID" ]; then
  PAGE=""
  while :; do
    if ! RESP=$(curl -sf "${FB_H[@]}" \
        "${API_FB}/sites/${SITE_ID}/channels?pageSize=100${PAGE:+&pageToken=$PAGE}"); then
      echo "::warning::Could not list Firebase channels on ${SITE_ID}; skipping them"
      CHANNEL_PRS=""; break
    fi
    if ! PAGE_PRS=$(jq -r '.channels[]?.name | split("/") | last
        | select(test("^pr-[0-9]+$")) | ltrimstr("pr-")' <<<"$RESP"); then
      echo "::warning::Unreadable Firebase channel list on ${SITE_ID}; skipping channels"
      CHANNEL_PRS=""; break
    fi
    CHANNEL_PRS+="${PAGE_PRS}"$'\n'
    PAGE=$(jq -r '.nextPageToken // ""' <<<"$RESP" 2>/dev/null || true)
    [ -n "$PAGE" ] || break
  done
  CHANNEL_PRS=$(grep -E '^[0-9]+$' <<<"$CHANNEL_PRS" | sort -un || true)
fi

# Cleanup mode: only the closed PR.
if [ -n "$PR_NUM" ]; then
  SVC_LINES=$(awk -F'\t' -v n="$PR_NUM" '$1 == n' <<<"$SVC_LINES")
  CHANNEL_PRS=$(grep -x "$PR_NUM" <<<"$CHANNEL_PRS" || true)
fi

ALL_PRS=$( { cut -f1 <<<"$SVC_LINES"; echo "$CHANNEL_PRS"; } | grep -E '^[0-9]+$' | sort -un || true)

echo "Preview resources of ${APP_NAME} in ${PROJECT}/${REGION}${SITE_ID:+ (Firebase site ${SITE_ID})}:"
if [ -z "$ALL_PRS" ]; then
  echo "  none"
  echo "No PR preview resources for ${APP_NAME}." >> "$SUMMARY"
  exit 0
fi

# ── 3. Which PRs are closed ──────────────────────────────────────────────────
pr_state() {
  if [ -n "$PR_NUM" ]; then echo closed; return; fi
  local body
  if body=$(curl -sSf --max-time 20 --retry 2 \
      -H "Authorization: Bearer ${GH_TOKEN:-}" -H "Accept: application/vnd.github+json" \
      "${API_GH}/repos/${REPO:?REPO is required in sweep mode}/pulls/$1" 2>/dev/null); then
    jq -r '.state // "unknown"' <<<"$body"
  else
    echo unknown
  fi
}

DELETE_SVCS=""
DELETE_PRS=""
{
  echo "### PR preview sweep: ${APP_NAME}$([ "$DRY_RUN" = "true" ] && echo " (dry run)")"
  echo ""
  echo "| PR | state | Cloud Run services | Firebase channel | action |"
  echo "|---|---|---|---|---|"
} >> "$SUMMARY"
for N in $ALL_PRS; do
  STATE=$(pr_state "$N")
  SVCS=$(awk -F'\t' -v n="$N" '$1 == n {print $2}' <<<"$SVC_LINES" | paste -sd' ' -)
  CHAN=$(grep -qx "$N" <<<"$CHANNEL_PRS" && echo "pr-$N" || true)
  case "$STATE" in
    closed) ACTION="delete"
            DELETE_PRS+="$N"$'\n'
            if [ -n "$SVCS" ]; then DELETE_SVCS+=$(tr ' ' '\n' <<<"$SVCS")$'\n'; fi ;;
    open)   ACTION="keep" ;;
    *)      ACTION="keep (state unknown)"
            echo "::warning::Could not read the state of PR #${N}; keeping its preview" ;;
  esac
  if [ "$DRY_RUN" = "true" ] && [ "$ACTION" = "delete" ]; then ACTION="would delete"; fi
  echo "  PR #${N} [${STATE}] ${ACTION}: ${SVCS:-no services}${CHAN:+, channel $CHAN}"
  echo "| #${N} | ${STATE} | ${SVCS:--} | ${CHAN:--} | ${ACTION} |" >> "$SUMMARY"
done

if [ "$DRY_RUN" = "true" ]; then
  echo "Dry run: nothing deleted."
  exit 0
fi

# ── 4. Delete ────────────────────────────────────────────────────────────────
FAILED=0
DELETED=0
for SVC in $(grep . <<<"$DELETE_SVCS" | sort -u || true); do
  echo "Deleting Cloud Run service ${SVC}"
  if gcloud run services delete "$SVC" --region="$REGION" --project="$PROJECT" --quiet; then
    DELETED=$((DELETED + 1))
  elif ! ERR=$(gcloud run services describe "$SVC" --region="$REGION" --project="$PROJECT" 2>&1 >/dev/null) \
      && grep -qiE "cannot find|not found" <<<"$ERR"; then
    echo "${SVC} is already gone"
  else
    echo "::error::Could not delete ${SVC}"; FAILED=1
  fi
done

if [ -n "$SITE_ID" ]; then
  for N in $(grep . <<<"$DELETE_PRS" || true); do
    if ! grep -qx "$N" <<<"$CHANNEL_PRS"; then continue; fi
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
      "${FB_H[@]}" "${API_FB}/sites/${SITE_ID}/channels/pr-${N}" || true)
    case "$CODE" in
      200) echo "Deleted Firebase preview channel pr-${N} on ${SITE_ID}" ;;
      404) echo "No Firebase preview channel pr-${N} on ${SITE_ID}" ;;
      *)   echo "::error::Deleting Firebase channel pr-${N} on ${SITE_ID} returned HTTP ${CODE}"; FAILED=1 ;;
    esac
  done
fi

echo "Deleted ${DELETED} preview service(s) for ${APP_NAME}"
exit "$FAILED"
