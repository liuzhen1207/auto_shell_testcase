#!/usr/bin/env bash
# One-click regression entry point for the remove-cn-dn module.
#
#   tools/run_regression.sh               # full matrix with conf/cluster.conf
#   tools/run_regression.sh --case X ...  # forwarded to `rcdn.sh run`
#   tools/run_regression.sh all           # matrix + the three object-heavy confs + TDB-861 probe
#   tools/run_regression.sh selftest      # offline self-test (no cluster needed)
#
# Requires python3 >= 3.9 on the driver machine (no third-party packages) and ssh
# access to every host in conf/cluster.conf.  Results land in results/<run-id>/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN=(bash "$ROOT/scripts/rcdn.sh" --conf "$ROOT/conf/cluster.conf")

case "${1:-}" in
  selftest)
    shift
    exec bash "$ROOT/scripts/rcdn.sh" selftest "$@"
    ;;
  all)
    shift
    set -x
    bash "$ROOT/scripts/rcdn.sh" --conf "$ROOT/conf/cluster.conf" run "$@"
    bash "$ROOT/scripts/rcdn.sh" --conf "$ROOT/conf/cluster.bigobj.conf" run --case dn_object_big_migrate "$@"
    bash "$ROOT/scripts/rcdn.sh" --conf "$ROOT/conf/cluster.manyobj.conf" run --case dn_object_manyfiles_residue "$@"
    bash "$ROOT/scripts/rcdn.sh" --conf "$ROOT/conf/cluster.tdb861.conf" run --case dn_object_delete_residue "$@"
    ;;
  list-cases)
    exec "${RUN[@]}" list-cases "${@:2}"
    ;;
  *)
    exec "${RUN[@]}" run "$@"
    ;;
esac
