#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 The OSS-CRS Actions authors
# SPDX-License-Identifier: Apache-2.0
#
# Thin wrapper so `oss-crs ...` works from any working directory: it pins the
# uv project to the baked-in checkout while leaving cwd (the mounted workspace)
# alone, so relative --fuzz-proj-path / --compose-file paths still resolve.
set -euo pipefail
exec uv run --frozen --project /opt/oss-crs oss-crs "$@"
