#!/usr/bin/env bash
# Fingerprint of the StackRamp files that shape a service image, so the image
# tag (<commit sha>-<fingerprint>) changes when the platform's build inputs
# change, not only when the app commit does. Without it, re-running an app on
# the same commit (manual run, deploy_all, schedule) would reuse an image
# built with an older platform Dockerfile or build recipe.
#
# Inputs hashed:
#   - this action's action.yml (build flags, BuildKit/mirror setup)
#   - the platform Dockerfile for the language, unless the service dir has its
#     own Dockerfile (then the platform one isn't used, so it isn't hashed)
# Other languages' Dockerfiles are not hashed, so changing python.Dockerfile
# doesn't rebuild Go services.
#
# Usage: fingerprint.sh <context dir> <language>   -> prints 12 hex chars
set -euo pipefail

CONTEXT="${1:?usage: fingerprint.sh <context dir> <language>}"
LANGUAGE="${2:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../../.." && pwd)"   # the stackramp checkout

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1
  fi
}

{
  echo "stackramp-image-fingerprint v1"
  echo "file providers/gcp/workflows/build-image/action.yml $(sha < "${HERE}/action.yml")"
  if [ -f "${CONTEXT}/Dockerfile" ]; then
    echo "dockerfile custom"
  else
    DF="platform-action/dockerfiles/${LANGUAGE}.Dockerfile"
    if [ -f "${ROOT}/${DF}" ]; then
      echo "file ${DF} $(sha < "${ROOT}/${DF}")"
    else
      echo "dockerfile missing ${DF}"
    fi
  fi
} | sha | cut -c1-12
