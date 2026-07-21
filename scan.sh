#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 The OSS-CRS authors
# SPDX-License-Identifier: Apache-2.0
#
# Core OSS-CRS scan logic, shared by the composite action (action.yaml) and the
# local runner (local-run.sh) so "local == CI" by construction. Configuration
# comes from environment variables:
#
#   HARNESS         (required) harness name (eg parse_class)
#   CRS             CRS name, selects the bundled compose  (default: crs-bug-finding-claude-code)
#   PROJ_PATH       OSS-Fuzz project dir           (default: oss-fuzz)
#   WORKSPACE       repo checkout root             (default: git toplevel)
#   IMAGE           runner image                   (default: ghcr.io/ossf/oss-crs-runner:latest)
#   COMPOSE_FILE    CRS compose file                (default: bundled composes/<CRS>.compose.yaml)
#   LITELLM_CONFIG  LiteLLM config for proxy CRSs   (default: bundled composes/<CRS>.litellm-config.yaml if present)
#   TIMEOUT         time allowed to run            (default: 300)
#   FAIL_ON_CRASH   exit non-zero on a pov         (default: true)
#   !! CRS_ENV passes the required values to the configured CRS 
#   CRS_ENV         newline separated KEY=VALUE credentials/env to forward into the CRS
#   GITHUB_OUTPUT   if set, `crashed`/`artifacts-dir` are written there
#
# Secrets model: every `KEY=VALUE` line in CRS_ENV is exported into this process
# and forwarded into the oss-crs container by NAME ONLY (`docker run -e KEY`), so
# secret values never appear on a command line or in the CI log. The compose /
# LiteLLM config for the chosen CRS decides which of those names it reads
# (eg ${CLAUDE_CODE_OAUTH_TOKEN}, os.environ/OPENAI_API_KEY).
set -euo pipefail

SCAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HARNESS="${HARNESS:?HARNESS is required}"
CRS="${CRS:-crs-bug-finding-claude-code}"
PROJ_PATH="${PROJ_PATH:-oss-fuzz}"
WORKSPACE="${WORKSPACE:-$(git rev-parse --show-toplevel)}"
TIMEOUT="${TIMEOUT:-300}"
FAIL_ON_CRASH="${FAIL_ON_CRASH:-true}"
IMAGE="${IMAGE:-ghcr.io/ossf/oss-crs-runner:latest}"

WORKDIR="${WORKSPACE}/.oss-crs-work"
ARTIFACTS="${WORKSPACE}/oss-crs-artifacts/${HARNESS}"
mkdir -p "$WORKDIR" "$ARTIFACTS"

# Publish artifacts-dir immediately so the caller's upload step always has a
# valid path, even if a later phase (prepare/build-target) aborts under `set -e`.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "artifacts-dir=$ARTIFACTS" >> "$GITHUB_OUTPUT"
fi

# Collect logs on ANY exit (including build failures) so the uploaded artifact
# always carries something useful for triage.
collect_logs() {
  find "$WORKDIR" -type d -name 'logs' -exec cp -a {} "$ARTIFACTS/" \; 2>/dev/null || true
}
trap collect_logs EXIT

# The container only sees $WORKSPACE, so the bundled compose for this CRS is
# copied in. COMPOSE_FILE overrides the bundled default entirely.
COMPOSE_FILE="${COMPOSE_FILE:-}"
if [[ -z "$COMPOSE_FILE" ]]; then
  src="${SCAN_DIR}/composes/${CRS}.compose.yaml"
  if [[ ! -f "$src" ]]; then
    echo "error: no bundled compose for CRS '${CRS}' (${src})." >&2
    echo "       Pass COMPOSE_FILE / compose-file to run any other registry CRS." >&2
    exit 2
  fi
  COMPOSE_FILE="${WORKDIR}/$(basename "$src")"
  cp -f "$src" "$COMPOSE_FILE"
fi

# LiteLLM-proxy CRSs (codex, gemini, …) reference a litellm config from the
# compose as `./.oss-crs-work/litellm-config.yaml` (relative to the run cwd,
# WORKSPACE). Stage it at exactly that path: the per-CRS bundled config, or an
# override. Fuzzer / OAuth CRSs have no llm_config and ignore it.
LITELLM_CONFIG="${LITELLM_CONFIG:-}"
if [[ -z "$LITELLM_CONFIG" && -f "${SCAN_DIR}/composes/${CRS}.litellm-config.yaml" ]]; then
  LITELLM_CONFIG="${SCAN_DIR}/composes/${CRS}.litellm-config.yaml"
fi
if [[ -n "$LITELLM_CONFIG" ]]; then
  cp -f "$LITELLM_CONFIG" "${WORKDIR}/litellm-config.yaml"
fi

# Forward credentials/config into the oss-crs container. Each CRS_ENV line is
# `KEY=VALUE`; we export it here and pass `-e KEY` (name only) so the value is
# read from the environment and never lands on the command line or in the log.
ENV_ARGS=()
if [[ -n "${CRS_ENV:-}" ]]; then
  while IFS= read -r line; do
    # Trim leading/trailing whitespace; skip blanks and comments.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      echo "error: CRS_ENV line is not KEY=VALUE: '${line%%=*}'" >&2
      exit 2
    fi
    key="${line%%=*}"
    val="${line#*=}"
    # Tolerate `KEY = VALUE`: trim whitespace around the name, and any space
    # introduced before the value. (Secret values have no leading whitespace.)
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "error: invalid env var name in CRS_ENV: '${key}'" >&2
      exit 2
    fi
    export "${key}=${val}"
    ENV_ARGS+=(-e "$key")
  done <<< "$CRS_ENV"
fi

echo "::group::Config"
echo "image=$IMAGE"
echo "crs=$CRS  harness=$HARNESS  timeout=${TIMEOUT}s"
echo "compose=$COMPOSE_FILE  proj=$PROJ_PATH  work=$WORKDIR"
echo "litellm-config=${LITELLM_CONFIG:-(none)}"
# Print forwarded NAMES only (never values).
fwd=()
for ((i = 1; i < ${#ENV_ARGS[@]}; i += 2)); do fwd+=("${ENV_ARGS[i]}"); done
echo "forwarded-env=${fwd[*]:-(none)}"
echo "::endgroup::"

# Run the oss-crs CLI from the image. The workspace is bind-mounted at the SAME
# absolute path in and out of the container, and the Docker socket is shared, so
# the paths oss-crs hands to the daemon resolve on the host.
oss_crs() {
  docker run --rm \
    ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${WORKSPACE}:${WORKSPACE}" \
    -w "${WORKSPACE}" \
    "$IMAGE" "$@"
}

echo "::group::image"
# Pull only registry images; a locally-built image (e.g. :local) stays as-is.
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE"
echo "::endgroup::"

echo "::group::prepare"
oss_crs prepare --compose-file "$COMPOSE_FILE" --work-dir "$WORKDIR"
echo "::endgroup::"

echo "::group::build-target"
oss_crs build-target \
  --compose-file "$COMPOSE_FILE" \
  --fuzz-proj-path "$PROJ_PATH" \
  --target-source-path "${WORKSPACE}" \
  --work-dir "$WORKDIR"
echo "::endgroup::"

echo "::group::run"
run_rc=0
oss_crs run \
  --compose-file "$COMPOSE_FILE" \
  --fuzz-proj-path "$PROJ_PATH" \
  --target-source-path "${WORKSPACE}" \
  --target-harness "$HARNESS" \
  --timeout "$TIMEOUT" \
  --work-dir "$WORKDIR" || run_rc=$?
echo "run exit code: $run_rc"
echo "::endgroup::"

# Collect PoVs. A finding is written to a CRS's SUBMIT_DIR/<harness>/povs/, then
# promoted by the exchange sidecar to EXCHANGE_DIR/<target>/<harness>/povs/. The
# libFuzzer engine also drops raw reproducers (crash-*/oom-*/timeout-*/leak-*).
# Catch all of them so neither the submit nor the exchange path is missed.
echo "::group::collect"
crashed=false
while IFS= read -r -d '' pov; do
  crashed=true
  cp -f "$pov" "$ARTIFACTS/" 2>/dev/null || true
done < <(find "$WORKDIR" \
           \( -path '*/povs/*' \
              -o -name 'crash-*' -o -name 'oom-*' -o -name 'timeout-*' -o -name 'leak-*' \) \
           -type f -print0 2>/dev/null)
# (logs are gathered by the EXIT trap, so they're captured on failure too.)
echo "crashed=$crashed"
ls -la "$ARTIFACTS" || true
echo "::endgroup::"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  # artifacts-dir was already published near the top.
  echo "crashed=$crashed" >> "$GITHUB_OUTPUT"
fi

if [[ "$crashed" == "true" ]]; then
  echo "PoV found for harness '${HARNESS}' (artifacts in ${ARTIFACTS})."
  if [[ "$FAIL_ON_CRASH" == "true" ]]; then
    echo "Failing because FAIL_ON_CRASH=true."
    exit 1
  fi
fi
