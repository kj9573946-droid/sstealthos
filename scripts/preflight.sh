#!/usr/bin/env bash
# Static repository validation and build-host preflight checks.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MODE=${1:---static}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[check] %s\n' "$*"; }

case "$MODE" in
  --static)
    command -v bash >/dev/null 2>&1 || fail 'bash is required'
    for relative_path in \
      'build-stealthos-v8.sh' \
      'build-stealthos-v8 (1).sh' \
      'scripts/build-iso.sh' \
      'scripts/preflight.sh'; do
      file="$ROOT/$relative_path"
      [[ -f "$file" ]] || fail "required file missing: $relative_path"
      bash -n "$file" || fail "shell syntax check failed: $relative_path"
      info "shell syntax OK: $relative_path"
    done
    grep -Fq 'build-stealthos-v8.sh' "$ROOT/build-stealthos-v8 (1).sh" \
      || fail 'duplicate-name wrapper does not call the canonical builder'
    info 'static validation passed'
    ;;
  --build)
    [[ $EUID -eq 0 ]] || fail 'build preflight must run as root (use sudo)'
    [[ -r /etc/os-release ]] || fail 'cannot identify the host operating system'
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
      debian:12*|ubuntu:*) ;;
      *) fail "supported build hosts are Debian 12 or Ubuntu; found ${PRETTY_NAME:-unknown}" ;;
    esac
    for command_name in apt-get df awk ping tee sha256sum; do
      command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command is missing: $command_name"
    done
    available_kb=$(df --output=avail -k /opt | tail -n 1 | tr -dc '0-9')
    [[ ${available_kb:-0} -ge 26214400 ]] \
      || fail "need at least 25 GiB free in /opt; found approximately $(( ${available_kb:-0} / 1048576 )) GiB"
    memory_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    [[ ${memory_kb:-0} -ge 4194304 ]] \
      || fail "need at least 4 GiB RAM; found approximately $(( ${memory_kb:-0} / 1048576 )) GiB"
    ping -c1 -W3 deb.debian.org >/dev/null 2>&1 \
      || fail 'cannot reach deb.debian.org; check network and DNS access'
    info 'build-host preflight passed'
    ;;
  *)
    fail 'usage: scripts/preflight.sh [--static|--build]'
    ;;
esac
