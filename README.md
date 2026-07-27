# oss-crs-actions

A reusable GitHub Action that runs [**OSS-CRS**](https://github.com/ossf/oss-crs) —
the OpenSSF orchestration framework for autonomous bug-finding — against one harness
of your **OSS-Fuzz-format** project.

Today it ships one bundled Cyber Reasoning System (CRS): **Claude Code**
(`crs-bug-finding-claude-code`), an LLM agent that drives bug-finding against your
target. The action is built to be CRS-agnostic — more of the
[registry](https://oss-crs.openssf.org/registry) (fuzzers like `crs-libfuzzer` /
`crs-jazzer`, and other LLM agents) will be enabled over time, and you can already run
any registry CRS today by supplying its compose via `compose-file`.

```yaml
- uses: actions/checkout@v4
- uses: ossf/oss-crs-actions@v1        # pin to a tag or commit SHA
  with:
    crs: crs-bug-finding-claude-code   # the default
    harness: my_harness                # a target from your oss-fuzz/build.sh
    proj-path: oss-fuzz
    timeout: "1500"
    fail-on-crash: "false"
    env: |
      CLAUDE_CODE_OAUTH_TOKEN=${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

## What you provide

Your repo supplies a standard **[OSS-Fuzz project](https://google.github.io/oss-fuzz/)**
directory (default `oss-fuzz/`) containing `project.yaml`, `Dockerfile`, and `build.sh`.
**Harness names come from that `build.sh`** — each fuzz target it drops in `$OUT/` is one
harness, and that name is what you pass as `harness:`. Everything else — the oss-crs CLI,
its toolchain, and the CRS compose — ships with the action.

## Setup

Claude Code authenticates with an OAuth token (no LiteLLM proxy):

1. Locally: `claude setup-token`
2. Repo → **Settings → Secrets and variables → Actions** → new secret
   `CLAUDE_CODE_OAUTH_TOKEN` = the token
3. Add a caller workflow (see [`examples/workflows/claude-dispatch.yaml`](examples/workflows/claude-dispatch.yaml)).

Because it needs a secret and costs Claude quota, run it **manual-dispatch / scheduled
only, in a trusted context — never on fork PRs.**

## Inputs

| Input | Default | Notes |
| --- | --- | --- |
| `harness` | — (required) | Harness name (from your `build.sh`). |
| `crs` | `crs-bug-finding-claude-code` | Bundled engine. For any other registry CRS, set `compose-file` instead. |
| `proj-path` | `oss-fuzz` | `--fuzz-proj-path` (your OSS-Fuzz project dir). |
| `image` | `ghcr.io/ossf/oss-crs-runner:latest` | Public runner image; override to pin/self-host. |
| `compose-file` | bundled `composes/<crs>.compose.yaml` | Path **in your checkout** to a custom compose. Use to run a non-bundled CRS or to resize. |
| `litellm-config` | bundled `composes/<crs>.litellm-config.yaml` | Path in your checkout to a LiteLLM config, for proxy-based LLM CRSs (not used by Claude). |
| `timeout` | `300` | Run budget (seconds). |
| `fail-on-crash` | `true` | `true` fails the job on a PoV; `false` reports only. |
| `env` | `""` | Credentials to forward, one `KEY=VALUE` per line. See **Secrets** below. |

**Outputs:** `crashed` (`true`/`false`) and `artifacts-dir` (collected PoVs + logs).

## Secrets

Credentials are passed **generically** through the `env:` input — one `KEY=VALUE` per
line, values coming from your caller's secrets:

```yaml
    env: |
      CLAUDE_CODE_OAUTH_TOKEN=${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Each name is exported and forwarded into the CRS container **by name only**
(`docker run -e KEY`), so values never appear on a command line or in the log. The CRS's
compose decides which names it reads (Claude reads `CLAUDE_CODE_OAUTH_TOKEN`). This
passthrough is generic, so bringing a new CRS online needs no change to the action.

## How it works

- **Runner image.** This repo publishes a **public** image,
  `ghcr.io/ossf/oss-crs-runner`, bundling the oss-crs CLI + Docker client/compose/buildx
  (built by [`.github/workflows/oss-crs-image.yaml`](.github/workflows/oss-crs-image.yaml)).
  Consumers pull it anonymously — no GHCR login needed.
- **Isolation.** Runs on an ephemeral GitHub-hosted runner. The oss-crs CLI runs inside
  the pinned image and drives the runner's own Docker daemon via a mounted socket; the
  workspace is bind-mounted at the **same absolute path** in/out of the container so paths
  handed to the daemon resolve. No root, no `--privileged`, no Docker-in-Docker.
- **The exact checkout** is analyzed via `--target-source-path`, never a stale `main`.
- **Scan core.** All logic lives in [`scan.sh`](scan.sh) (prepare → build-target → run →
  collect PoVs/logs), shared by the action and `local-run.sh` so **local == CI**.

## Test it locally

Because the action is a thin wrapper over `scan.sh`, you can run the identical flow on
your machine. Requires Docker; use a **Linux/amd64** host for a faithful mirror (the
OSS-Fuzz base image is amd64; other hosts work under slow emulation).

```bash
# From your project checkout: build the runner image and run Claude on one harness.
CRS=crs-bug-finding-claude-code \
CRS_ENV="CLAUDE_CODE_OAUTH_TOKEN=$(cat token.txt)" \
WORKSPACE=$(pwd) /path/to/oss-crs-actions/local-run.sh my_harness 600
```

PoVs and logs land in `oss-crs-artifacts/<harness>/`.

## Adding another CRS

The action already accepts any registry CRS via `compose-file`. To run one, write a
compose that references it (use the bundled Claude compose in [`composes/`](composes/) as
a pattern) and point `compose-file` at your file:

```yaml
- uses: ossf/oss-crs-actions@v1
  with:
    harness: my_harness
    compose-file: .github/oss-crs/my-crs.compose.yaml   # your file, in your repo
    env: |
      SOME_API_KEY=${{ secrets.SOME_API_KEY }}
```

Composes for other CRSs (libfuzzer, jazzer, codex, gemini), reconciled against the
upstream [`ossf/oss-crs`](https://github.com/ossf/oss-crs) examples, are staged in
`staged-composes/` (kept out of git). They'll be promoted into `composes/` and documented
here as each is validated.

## Repo layout

| Path | Role |
| --- | --- |
| `action.yaml` | The composite action (maps inputs → env → `scan.sh`). |
| `scan.sh` | Scan core; shared by the action and `local-run.sh`. |
| `local-run.sh` | Run the exact CI flow on your machine. |
| `runner.Dockerfile` / `entrypoint.sh` | The public oss-crs runner image. |
| `composes/` | Bundled CRS compose(s). |
| `.github/workflows/oss-crs-image.yaml` | Builds & publishes the public runner image. |
| `examples/workflows/` | Copy-paste caller templates. |

## Bumping OSS-CRS

Update `OSS_CRS_REF` in `runner.Dockerfile`, then re-run the `oss-crs-image` workflow
(`workflow_dispatch`) to republish `ghcr.io/ossf/oss-crs-runner:latest`.

## Caveats

- The full oss-crs Docker loop needs a Linux Docker host — validate with `local-run.sh`
  or a CI dispatch dry-run before relying on it.
- The `ghcr.io/ossf/...` image namespace assumes this repo lives under `ossf`. If it lives
  elsewhere, the publish workflow uses that owner automatically; set the `image` input on
  the consumer side to match.
