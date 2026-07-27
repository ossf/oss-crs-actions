#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 The OSS-CRS Authors
# SPDX-License-Identifier: Apache-2.0
#
# Run in your local machine exactly what the CI action does:
#  - Build the oss-crs-runner image
#  - Run scan.sh (the same core script the composite action calls)
#
# This runs against a checked out repository' OSS-fuzz harnesses.
#
# Needs Docker and a Linux/amd64 host
#
# Usage:
#   ./local-run.sh <HARNESS> [TIMEOUT_SECONDS]
#   HARNESS is required (a target from your project's oss-fuzz/build.sh);
#   TIMEOUT defaults to 120.
#
# Env var overrides:
#   IMAGE=<ref>     use an existing image instead of building oss-crs-runner:local
#   NO_BUILD=1      skip the image build (implies a prebuilt IMAGE)
#   WORKSPACE=...   target repo checkout root (default: the git toplevel of the current dir)
#   PROJ_PATH=...   Oss-fuzz harness path in the project dir (default: oss-fuzz)
#   CRS=<name>      CRS engine to run (default: crs-bug-finding-claude-code). LLM CRSs need
#                   their own CRS_ENV set, for example:
#                     CRS_ENV="CLAUDE_CODE_OAUTH_TOKEN=$(cat token)" ./local-run.sh
#   CRS_ENV=...     newline-separated KEY=VALUE env vars to forward to the CRS (see scan.sh)
set -euo pipefail

SCAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HARNESS="${1:?usage: local-run.sh <harness> [timeout]  (harness = a target from your oss-fuzz/build.sh)}"
TIMEOUT="${2:-120}"
IMAGE="${IMAGE:-oss-crs-runner:local}"
WORKSPACE="${WORKSPACE:-$(git rev-parse --show-toplevel)}"

if ! docker info >/dev/null 2>&1; then
  echo "error: Docker is not available. Start Docker and retry." >&2
  exit 1
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "warning: non-Linux host — the OSS-Fuzz amd64 base image runs under" >&2
  echo "         emulation and will be slow; CI (ubuntu-latest) is the real target." >&2
fi

if [[ "${NO_BUILD:-0}" != "1" && "$IMAGE" == "oss-crs-runner:local" ]]; then
  echo "==> Building runner image ${IMAGE}"
  docker build -f "${SCAN_DIR}/runner.Dockerfile" -t "$IMAGE" "$SCAN_DIR"
fi

echo "==> Scanning harness '${HARNESS}' (CRS=${CRS:-crs-bug-finding-claude-code}) for ${TIMEOUT}s (fail-on-crash disabled)"
HARNESS="$HARNESS" \
CRS="${CRS:-crs-bug-finding-claude-code}" \
TIMEOUT="$TIMEOUT" \
IMAGE="$IMAGE" \
WORKSPACE="$WORKSPACE" \
PROJ_PATH="${PROJ_PATH:-oss-fuzz}" \
CRS_ENV="${CRS_ENV:-}" \
FAIL_ON_CRASH="false" \
  bash "${SCAN_DIR}/scan.sh"

echo "==> Done. PoVs/logs (if any): ${WORKSPACE}/oss-crs-artifacts/${HARNESS}"
