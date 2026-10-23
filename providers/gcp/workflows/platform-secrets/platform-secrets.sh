#!/usr/bin/env bash
# Discover the platform secrets a Cloud Run service should mount.
#
# Usage: platform-secrets.sh <project> <app_name> <environment>
#        platform-secrets.sh --filter <app_name> <environment>   (print the filter only)
#
# Prints two lines for $GITHUB_OUTPUT on stdout (logs secret NAMES, never
# values, on stderr):
#   secret_refs=<NAME=NAME:latest,...>   the --set-secrets refs (may be empty)
#   clear_secrets=<true|false>           true when the project has platform
#     secrets but none match this service: the deploy then passes
#     --clear-secrets (if it has no other secret refs), so secrets scoped away
#     are taken off. Before the scoping labels, such a service always got a
#     non-empty --set-secrets that replaced its whole list; this keeps that.
#     false when the project has no platform secrets at all (no flag, as before).
#
# A secret is mounted when it has the label platform-inject=true and both:
#   - platform-app is absent, or equals the app (stackramp.yaml `name`)
#   - platform-env is absent, or equals the environment scope:
#       prod -> prod, dev -> dev, pr-<n> (PR previews) -> dev,
#       anything else -> itself
# A secret with neither scoping label is mounted everywhere (unchanged).
#
# Label values may only hold lowercase letters, digits, '_' and '-' (max 63),
# so the app and environment are normalised the same way before matching.
set -euo pipefail

label_value() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' | cut -c1-63
}

scope_env() {
  case "$1" in
    pr-*) echo dev ;;              # previews: dev-scoped secrets, never prod
    *)    label_value "$1" ;;
  esac
}

build_filter() {
  local app env
  app=$(label_value "$1")
  env=$(scope_env "$2")
  if [ -z "$app" ] || [ -z "$env" ]; then
    echo "platform-secrets: app_name and environment are required" >&2
    exit 1
  fi
  printf 'labels.platform-inject=true AND (-labels.platform-app:* OR labels.platform-app=%s) AND (-labels.platform-env:* OR labels.platform-env=%s)' "$app" "$env"
}

if [ "${1:-}" = "--filter" ]; then
  build_filter "${2:-}" "${3:-}"
  echo
  exit 0
fi

PROJECT="${1:?project required}"
FILTER=$(build_filter "${2:-}" "${3:-}")
echo "Platform secret filter: $FILTER" >&2

# --verbosity=error hides gcloud's "filter keys were not present" warning
# while no secret carries a scoping label yet. A failed listing fails the
# deploy (set -e), as before.
NAMES=$(gcloud secrets list \
  --project="$PROJECT" \
  --filter="$FILTER" \
  --format="value(name.basename())" \
  --verbosity=error)

REFS=""; COUNT=0
for NAME in $NAMES; do
  REFS="${REFS:+$REFS,}${NAME}=${NAME}:latest"
  COUNT=$((COUNT + 1))
done
echo "Platform secrets mounted (${COUNT}): $(echo $NAMES)" >&2

CLEAR=false
if [ "$COUNT" -eq 0 ]; then
  ANY=$(gcloud secrets list \
    --project="$PROJECT" \
    --filter="labels.platform-inject=true" \
    --format="value(name.basename())" \
    --limit=1 \
    --verbosity=error)
  if [ -n "$ANY" ]; then
    CLEAR=true
    echo "No platform secret is scoped to this service: clearing any it still has." >&2
  fi
fi
printf 'secret_refs=%s\nclear_secrets=%s\n' "$REFS" "$CLEAR"
