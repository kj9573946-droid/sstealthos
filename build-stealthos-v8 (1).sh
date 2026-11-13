#!/usr/bin/env bash
# Deprecated compatibility entry point. Use build-stealthos-v8.sh directly.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
printf 'NOTICE: deprecated duplicate filename; forwarding to build-stealthos-v8.sh\n' >&2
exec bash "$ROOT/build-stealthos-v8.sh" "$@"
