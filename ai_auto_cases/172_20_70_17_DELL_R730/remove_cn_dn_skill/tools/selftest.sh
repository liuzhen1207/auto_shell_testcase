#!/usr/bin/env bash
# Offline self-test of the case matrix and the python package (no cluster required).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$ROOT/scripts/rcdn.sh" selftest "$@"
