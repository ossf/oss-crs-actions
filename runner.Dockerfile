# SPDX-FileCopyrightText: Copyright 2026 The OSS-CRS Actions authors
# SPDX-License-Identifier: Apache-2.0
#
# Runner image that bundles OSS-CRS (https://github.com/ossf/oss-crs) and its
# non-trivial toolchain so CI doesn't reinstall it on every run. It ships the
# oss-crs CLI plus a Docker *client* and the compose/buildx plugins; it drives
# the runner's own Docker daemon through a mounted socket (see scan.sh). It is
# NOT a Docker-in-Docker image and holds no daemon.
#
# Published publicly by .github/workflows/oss-crs-image.yaml as
# ghcr.io/<owner>/oss-crs-runner so any consumer of this action can pull it
# without authentication.
FROM python:3.12-slim

# --- Pinned versions (bump deliberately) ------------------------------------
# OSS-CRS commit. Keep in sync with .github/workflows/oss-crs-image.yaml.
ARG OSS_CRS_REF=aab5ed87970b9cc1be4a0bae5a8dda59f49d9966
ARG DOCKER_VERSION=27.5.1
ARG COMPOSE_VERSION=2.32.4
ARG BUILDX_VERSION=0.20.1
ARG UV_VERSION=0.5.29

# --- OS deps ----------------------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# --- Docker client + compose + buildx plugins (client only, no daemon) ------
RUN set -eux; \
    curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
        | tar -xz -C /tmp; \
    install -m0755 /tmp/docker/docker /usr/local/bin/docker; \
    rm -rf /tmp/docker; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    curl -fsSL "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose; \
    curl -fsSL "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.linux-amd64" \
        -o /usr/local/lib/docker/cli-plugins/docker-buildx; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-buildx

# --- uv ---------------------------------------------------------------------
COPY --from=ghcr.io/astral-sh/uv:0.5.29 /uv /uvx /usr/local/bin/
# (UV_VERSION ARG documents the pin above; keep the two in sync when bumping.)

# --- OSS-CRS ----------------------------------------------------------------
RUN git clone https://github.com/ossf/oss-crs /opt/oss-crs \
    && git -C /opt/oss-crs checkout "${OSS_CRS_REF}"
WORKDIR /opt/oss-crs
# Resolve the Python environment and bake the sparse oss-fuzz helper scripts
# (base-builder/base-runner) so runtime needs no extra network fetch.
RUN uv sync --frozen \
    && bash scripts/setup-third-party.sh

COPY entrypoint.sh /usr/local/bin/oss-crs
RUN chmod +x /usr/local/bin/oss-crs

# cwd is set to the mounted workspace by the caller; the wrapper locates the
# oss-crs project regardless of cwd.
ENTRYPOINT ["/usr/local/bin/oss-crs"]
