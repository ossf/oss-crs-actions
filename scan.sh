#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 The OSS-CRS Authors
# SPDX-License-Identifier: Apache-2.0
#
# Core OSS-CRS scan logic, this script us shared by the composite action (action.yaml)
# and the local runner script (local-run.sh) so "local == CI" by construction.
#
# All the configuration comes from environment variables:
#
#   HARNESS         (required) harness name (a target from your oss-fuzz/build.sh)
#   CRS             CRS name (a bundled compose)   (default: crs-bug-finding-claude-code)
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
#   EVENT_NAME      triggering event name (set by the action)
#   HEAD_REPO_FORK  "true" when the PR head is a fork (set by the action)
#
# Runs that forward CRS_ENV are refused for pull_request_target and fork pull requests.
#
# Secrets handling: every `KEY=VALUE` line in CRS_ENV is exported into this process
# and forwarded into the oss-crs container by NAME ONLY (`docker run -e KEY`), so
# secret values never appear on a command line or in the CI log. The compose /
# LiteLLM config for the chosen CRS decides which of those names it reads
# (eg ${CLAUDE_CODE_OAUTH_TOKEN}, os.environ/OPENAI_API_KEY).
#
# Inputs are validated before use: HARNESS/CRS are plain names, TIMEOUT is an
# integer, and every user-supplied path (COMPOSE_FILE, LITELLM_CONFIG, PROJ_PATH)
# must resolve inside WORKSPACE.
set -euo pipefail

SCAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HARNESS="${HARNESS:?HARNESS is required}"
CRS="${CRS:-crs-bug-finding-claude-code}"
PROJ_PATH="${PROJ_PATH:-oss-fuzz}"
WORKSPACE="${WORKSPACE:-$(git rev-parse --show-toplevel)}"
TIMEOUT="${TIMEOUT:-300}"
FAIL_ON_CRASH="${FAIL_ON_CRASH:-true}"
IMAGE="${IMAGE:-ghcr.io/ossf/oss-crs-runner:latest}" # FIXME: We need to pin this
COMPOSE_FILE="${COMPOSE_FILE:-}"
LITELLM_CONFIG="${LITELLM_CONFIG:-}"

die() {
  echo "error: $*" >&2
  exit 2
}

# --- Input validation -------------------------------------------------------
[[ "$HARNESS" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "invalid harness name '${HARNESS}' (allowed: letters, digits, '.', '_', '-')"
[[ "$CRS" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "invalid CRS name '${CRS}' (allowed: letters, digits, '.', '_', '-')"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
  || die "timeout must be a positive integer (seconds), got '${TIMEOUT}'"
[[ "$FAIL_ON_CRASH" == "true" || "$FAIL_ON_CRASH" == "false" ]] \
  || die "fail-on-crash must be 'true' or 'false', got '${FAIL_ON_CRASH}'"

# PROJ_PATH is relative to WORKSPACE and cannot climb out of it.
[[ "$PROJ_PATH" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] \
  || die "invalid proj-path '${PROJ_PATH}' (must be a relative path inside the checkout)"
[[ "/${PROJ_PATH}/" != *"/../"* ]] \
  || die "proj-path must not contain '..' (got '${PROJ_PATH}')"

[[ -d "$WORKSPACE" ]] || die "workspace '${WORKSPACE}' is not a directory"
WORKSPACE_REAL="$(cd "$WORKSPACE" && pwd -P)"

# Fails unless $2 resolves (following symlinks) to a path inside the workspace.
require_in_workspace() {
  local what="$1" path="$2" resolved
  resolved="$(realpath "$path" 2>/dev/null)" || die "${what} '${path}' does not exist"
  [[ "$resolved" == "$WORKSPACE_REAL" || "$resolved" == "$WORKSPACE_REAL"/* ]] \
    || die "${what} '${path}' resolves outside the workspace (${resolved})"
}

require_in_workspace "proj-path" "${WORKSPACE}/${PROJ_PATH}"
[[ -d "${WORKSPACE}/${PROJ_PATH}" ]] || die "proj-path '${PROJ_PATH}' is not a directory"
if [[ -n "$COMPOSE_FILE" ]]; then
  require_in_workspace "compose-file" "$COMPOSE_FILE"
  [[ -f "$COMPOSE_FILE" ]] || die "compose-file '${COMPOSE_FILE}' is not a file"
fi
if [[ -n "$LITELLM_CONFIG" ]]; then
  require_in_workspace "litellm-config" "$LITELLM_CONFIG"
  [[ -f "$LITELLM_CONFIG" ]] || die "litellm-config '${LITELLM_CONFIG}' is not a file"
fi

WORKDIR="${WORKSPACE}/.oss-crs-work"
ARTIFACTS="${WORKSPACE}/oss-crs-artifacts/${HARNESS}"
mkdir -p "$WORKDIR" "$ARTIFACTS"

# Publish artifacts dir immediately so the caller's upload step always has a
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

# LiteLLM-proxy CRSs (codex, gemini, etc) reference a litellm config from the
# compose as `./.oss-crs-work/litellm-config.yaml` (relative to the run cwd,
# WORKSPACE). Stage it at exactly that path: the per-CRS bundled config, or an
# override. Fuzzer / OAuth CRSs have no llm_config and ignore it.
if [[ -z "$LITELLM_CONFIG" && -f "${SCAN_DIR}/composes/${CRS}.litellm-config.yaml" ]]; then
  LITELLM_CONFIG="${SCAN_DIR}/composes/${CRS}.litellm-config.yaml"
fi
if [[ -n "$LITELLM_CONFIG" ]]; then
  cp -f "$LITELLM_CONFIG" "${WORKDIR}/litellm-config.yaml"
fi

# Never hand credentials to code that can come from an untrusted pull request.
if [[ -n "${CRS_ENV:-}" ]]; then
  if [[ "${EVENT_NAME:-}" == "pull_request_target" || "${HEAD_REPO_FORK:-}" == "true" ]]; then
    echo "error: refusing to forward credentials (env) for '${EVENT_NAME:-}' from a fork or pull_request_target." >&2
    echo "       Run it from workflow_dispatch/schedule/push instead." >&2
    exit 2
  fi
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
    # These names would let a caller redirect this script, the runner, the
    # Docker client or the interpreter inside the runner image.
    case "$key" in
      GITHUB_OUTPUT | GITHUB_ENV | GITHUB_PATH | GITHUB_STATE | GITHUB_STEP_SUMMARY | GITHUB_ACTION_PATH | GITHUB_WORKSPACE | \
        RUNNER_* | ACTIONS_* | INPUT_* | DOCKER_* | COMPOSE_* | BUILDX_* | BASH_* | LD_* | UV_* | PYTHON* | \
        PATH | HOME | IFS | ENV | SHELL | SHELLOPTS | BASHOPTS | PS4 | PROMPT_COMMAND | CDPATH | TMPDIR | \
        HARNESS | CRS | CRS_ENV | PROJ_PATH | IMAGE | LITELLM_CONFIG | TIMEOUT | FAIL_ON_CRASH | \
        WORKSPACE | WORKDIR | ARTIFACTS | SCAN_DIR | EVENT_NAME | HEAD_REPO_FORK)
        echo "error: env var name '${key}' is reserved and cannot be forwarded via CRS_ENV" >&2
        exit 2
        ;;
    esac
    # Make sure the runner masks the value in logs even if it did not come from a secret.
    [[ -n "$val" ]] && echo "::add-mask::${val}"
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

# Run the oss-crs CLI from the image. The workspace is mounted at the SAME
# absolute path in and out of the container, and the Docker socket is shared, so
# the paths oss-crs hands to the daemon resolve on the host.
oss_crs() {
  docker run --rm \
    --security-opt no-new-privileges \
    ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${WORKSPACE}:${WORKSPACE}" \
    -w "${WORKSPACE}" \
    "$IMAGE" "$@"
}

echo "::group::image"
# Pull only registry images, a locally-built image (eg :local) stays as is.
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
  # artifacts-dir was already published near the top
  echo "crashed=$crashed" >> "$GITHUB_OUTPUT"
fi

if [[ "$crashed" == "true" ]]; then
  echo "PoV found for harness '${HARNESS}' (artifacts in ${ARTIFACTS})."
  if [[ "$FAIL_ON_CRASH" == "true" ]]; then
    echo "Failing because FAIL_ON_CRASH=true."
    exit 1
  fi
fi
