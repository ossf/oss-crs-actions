# SPDX-FileCopyrightText: Copyright 2026 The OSS-CRS authors
# SPDX-License-Identifier: Apache-2.0
#
# Runner image that bundles OSS-CRS (https://github.com/ossf/oss-crs) and its
# toolchain so CI doesn't reinstall it on every run. It packs the oss-crs
# CLI, the Docker client with the compose and buildx plugins. It drives
# the runner's own Docker daemon through a mounted socket (moutned by scan.sh).
#
# This is built in CI by .github/workflows/oss-crs-image.yaml as
# ghcr.io/<owner>/oss-crs-runner so any consumer of this action can pull it
# without authentication.
FROM python:3.12-slim

# Pinned component versions
ARG DOCKER_VERSION=27.5.1
ARG COMPOSE_VERSION=2.32.4
ARG BUILDX_VERSION=0.20.1
ARG UV_VERSION=0.5.29
# And the OSS-CRS commit. Keep in sync with .github/workflows/oss-crs-image.yaml.
ARG OSS_CRS_REF=aab5ed87970b9cc1be4a0bae5a8dda59f49d9966

# --- OS deps ----------------------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install the Docker client + compose + buildx plugins
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

# Install uv
COPY --from=ghcr.io/astral-sh/uv:0.5.29 /uv /uvx /usr/local/bin/

# Clone OSS-CRS from the repo
RUN git clone https://github.com/ossf/oss-crs /opt/oss-crs \
    && git -C /opt/oss-crs checkout "${OSS_CRS_REF}"
WORKDIR /opt/oss-crs

# Resolve the Python environment and bake the oss-fuzz helper scripts
# (base-builder/base-runner) so we dont fetch them at runtime 
RUN uv sync --frozen && bash scripts/setup-third-party.sh

COPY entrypoint.sh /usr/local/bin/oss-crs
RUN chmod +x /usr/local/bin/oss-crs

# cwd is set to the mounted workspace by the calle. The wrapper locates the
# oss-crs project regardless of cwd.
ENTRYPOINT ["/usr/local/bin/oss-crs"]
