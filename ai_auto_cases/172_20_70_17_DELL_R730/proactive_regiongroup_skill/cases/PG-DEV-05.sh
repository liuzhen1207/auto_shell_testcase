#!/bin/bash
set -u
ROOT="${PROACTIVE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONF="${PROACTIVE_CONF:-$ROOT/conf/cluster.pg_2011snap_iot.conf}"
exec bash "$ROOT/scripts/pg.sh" --conf "$CONF" run --case PG-DEV-05 "$@"
