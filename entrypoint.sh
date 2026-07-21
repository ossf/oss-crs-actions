#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 The OSS-CRS Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
exec uv run --frozen --project /opt/oss-crs oss-crs "$@"
