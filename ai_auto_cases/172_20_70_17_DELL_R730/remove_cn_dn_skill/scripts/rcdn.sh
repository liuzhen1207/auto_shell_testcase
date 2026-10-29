#!/usr/bin/env bash
# Thin wrapper around the rcdn Python package.
#
#   scripts/rcdn.sh --conf conf/cluster.conf doctor
#   scripts/rcdn.sh --conf conf/cluster.conf discover --from-inventory
#   scripts/rcdn.sh --conf conf/cluster.conf prepare
#   scripts/rcdn.sh --conf conf/cluster.conf matrix
#
# Requires python3 >= 3.9 on the driver machine.  No third-party packages.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="${SKILL_DIR}/scripts${PYTHONPATH:+:${PYTHONPATH}}"

PY="${PYTHON:-}"
if [[ -z "${PY}" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PY=python3
  elif command -v python >/dev/null 2>&1; then
    PY=python
  else
    echo "rcdn: python3 is required but was not found on PATH" >&2
    exit 127
  fi
fi

exec "${PY}" -m rcdn "$@"
