#!/usr/bin/env bash
# Entry point for building on a prepared Debian 12 or Ubuntu host.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec bash "$ROOT/build-stealthos-v8.sh" "$@"
