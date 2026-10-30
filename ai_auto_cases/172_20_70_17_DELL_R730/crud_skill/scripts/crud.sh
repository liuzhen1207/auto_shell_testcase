#!/usr/bin/env bash
# Thin wrapper around the crudkit Python package.
#
#   scripts/crud.sh --conf conf/cluster.ttl_rc4.conf selftest
#   scripts/crud.sh --conf conf/cluster.ttl_rc4.conf doctor
#   scripts/crud.sh --conf conf/cluster.ttl_rc4.conf deploy
#   scripts/crud.sh --conf conf/cluster.ttl_rc4.conf prepare
#   scripts/crud.sh --conf conf/cluster.ttl_rc4.conf list-cases
#   scripts/crud.sh --conf conf/cluster.ttl_rc4.conf matrix
#   scripts/crud.sh --conf conf/cluster.ttl_rc4.conf run --case ttl_expire_invisible
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
    echo "crud.sh: python3 is required but was not found on PATH" >&2
    exit 127
  fi
fi

exec "${PY}" -m crudkit "$@"
