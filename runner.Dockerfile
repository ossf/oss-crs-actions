# SPDX-FileCopyrightText: Copyright 2026 The OSS-CRS Authors
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
FROM ghcr.io/astral-sh/uv:0.13.4@sha256:9f130421e930bfbdc563c00740466603f8723158e90297d07957c2294640262b AS uv

FROM python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1

LABEL org.opencontainers.image.source="https://github.com/ossf/oss-crs-actions" \
      org.opencontainers.image.licenses="Apache-2.0"

# Pinned component versions and the SHA256 of each downloaded binary
ARG DOCKER_VERSION=27.5.1
ARG DOCKER_SHA256=4f798b3ee1e0140eab5bf30b0edc4e84f4cdb53255a429dc3bbae9524845d640
ARG COMPOSE_VERSION=2.32.4
ARG COMPOSE_SHA256=ed1917fb54db184192ea9d0717bcd59e3662ea79db48bff36d3475516c480a6b
ARG BUILDX_VERSION=0.20.1
ARG BUILDX_SHA256=8c38f60308a895fa570f1410e453c5de11aafd65a99fa99965d96d24b6225a78
# And the OSS-CRS commit.
ARG OSS_CRS_REF=aab5ed87970b9cc1be4a0bae5a8dda59f49d9966

# --- OS deps ----------------------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install the Docker client + compose + buildx plugins, verifying each download
RUN set -eux; \
    curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
        -o /tmp/docker.tgz; \
    echo "${DOCKER_SHA256}  /tmp/docker.tgz" | sha256sum -c -; \
    tar -xzf /tmp/docker.tgz -C /tmp; \
    install -m0755 /tmp/docker/docker /usr/local/bin/docker; \
    rm -rf /tmp/docker /tmp/docker.tgz; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    curl -fsSL "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose; \
    echo "${COMPOSE_SHA256}  /usr/local/lib/docker/cli-plugins/docker-compose" | sha256sum -c -; \
    curl -fsSL "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.linux-amd64" \
        -o /usr/local/lib/docker/cli-plugins/docker-buildx; \
    echo "${BUILDX_SHA256}  /usr/local/lib/docker/cli-plugins/docker-buildx" | sha256sum -c -; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-buildx

# Install uv
COPY --from=uv /uv /uvx /usr/local/bin/

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
