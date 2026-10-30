#!/usr/bin/env bash
# One-click regression entry point for the CRUD module.
#
#   tools/run_regression.sh                    # full matrix with conf/crud.rc5.conf
#   tools/run_regression.sh run --case <id>    # one case
#   tools/run_regression.sh list-cases         # the 75-case matrix
#   tools/run_regression.sh selftest           # offline self-test (no cluster needed)
#   tools/run_regression.sh deploy             # unpack + configure + activate
#   tools/run_regression.sh prepare            # DESTRUCTIVE: wipe data + start (CN first, then DN)
#   tools/run_regression.sh rc1                # matrix on conf/crud.v20131rc1.conf (2.0.13.1 RC1,
#                                              # includes crud_schema_region_group_bootstrap_restart)
#
# Requires python3 >= 3.9 on the driver machine (no third-party packages) and ssh
# access to every host in conf/nodes.conf.  Results land in results/<run-id>/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRUD=(bash "$ROOT/scripts/crud.sh" --conf "$ROOT/conf/crud.rc5.conf")

case "${1:-}" in
  selftest)
    shift
    exec bash "$ROOT/scripts/crud.sh" selftest "$@"
    ;;
  list-cases|deploy|prepare|props|load|run|matrix|report|doctor)
    exec "${CRUD[@]}" "$@"
    ;;
  rc1)
    shift
    exec bash "$ROOT/scripts/crud.sh" --conf "$ROOT/conf/crud.v20131rc1.conf" "${@:-matrix}"
    ;;
  "")
    exec "${CRUD[@]}" matrix
    ;;
  *)
    exec "${CRUD[@]}" "$@"
    ;;
esac
