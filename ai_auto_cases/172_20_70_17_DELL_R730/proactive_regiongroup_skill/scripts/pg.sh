#!/usr/bin/env bash
# Thin wrapper around the pgkit Python package.
#
#   scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf selftest
#   scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf doctor
#   scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf deploy
#   scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf prepare
#   scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf list-cases
#   scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf matrix
#   scripts/pg.sh --conf conf/cluster.pg_2011snap_iot.conf run --case PG-SMK-01
#   scripts/pg.sh report <run-dir>
#
# The skill root is derived from this script's location, so the whole directory
# can be moved (its final home is /data/deepseek/proactive) without edits.
# Set PG_SKILL_DIR to point the package at a copy explicitly.
#
# Requires python3 >= 3.9 on the driver machine.  No third-party packages.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PG_SKILL_DIR="${PG_SKILL_DIR:-${SKILL_DIR}}"
export PYTHONPATH="${SKILL_DIR}/scripts${PYTHONPATH:+:${PYTHONPATH}}"

PY="${PYTHON:-}"
if [[ -z "${PY}" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PY=python3
  elif command -v python >/dev/null 2>&1; then
    PY=python
  else
    echo "pg.sh: python3 is required but was not found on PATH" >&2
    exit 127
  fi
fi

exec "${PY}" -m pgkit "$@"
