#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BM_USER=${BM_USER:-root}
BM_PARENT_DIR=${BM_PARENT_DIR:-/${BM_USER}/benchmark}
HOSTS_FILE=${HOSTS_FILE:-"${SCRIPT_DIR}/benchmark_hosts.conf"}
SOURCE_ROOT=${SOURCE_ROOT:-"${SCRIPT_DIR}/bm_package"}
PACKAGE_PREFIX=${PACKAGE_PREFIX:-bm_20260717_e63efa4_jdk17}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

usage() {
  cat <<'EOF'
Usage:
  ./deploy_benchmark.sh
  BM_USER=liuzhen BM_PARENT_DIR=/home/liuzhen/benchmark ./deploy_benchmark.sh

Optional environment variables:
  BM_USER         Remote operating-system user (default: liuzhen)
  BM_PARENT_DIR   Remote parent directory (default: /home/<BM_USER>/benchmark)
  HOSTS_FILE      Host list file (default: benchmark_hosts.conf)
  SOURCE_ROOT     Local package directory (default: bm_package)
  PACKAGE_PREFIX  Package name without _n1.._n5 suffix
EOF
}

[[ ${1:-} != "-h" && ${1:-} != "--help" ]] || { usage; exit 0; }
[[ -n "${BM_USER}" ]] || { echo "ERROR: BM_USER is empty" >&2; exit 1; }
[[ "${BM_PARENT_DIR}" == /* && "${BM_PARENT_DIR}" != "/" ]] || {
  echo "ERROR: BM_PARENT_DIR must be an absolute path other than /" >&2
  exit 1
}
[[ -r "${HOSTS_FILE}" ]] || { echo "ERROR: cannot read ${HOSTS_FILE}" >&2; exit 1; }

mapfile -t HOSTS < <(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "${HOSTS_FILE}" | grep -v '^$')
[[ ${#HOSTS[@]} -eq 5 ]] || {
  echo "ERROR: ${HOSTS_FILE} must contain exactly 5 hosts; found ${#HOSTS[@]}" >&2
  exit 1
}

for i in 1 2 3 4 5; do
  src="${SOURCE_ROOT}/${PACKAGE_PREFIX}_n${i}"
  [[ -d "${src}" ]] || { echo "ERROR: source directory does not exist: ${src}" >&2; exit 1; }
done

for i in 1 2 3 4 5; do
  host=${HOSTS[$((i - 1))]}
  src="${SOURCE_ROOT}/${PACKAGE_PREFIX}_n${i}"
  target="${BM_PARENT_DIR}/${PACKAGE_PREFIX}_orig"
  staging="${BM_PARENT_DIR}/.${PACKAGE_PREFIX}.deploying.$$"

  echo "[${i}/5] Deploying ${src} -> ${BM_USER}@${host}:${target}"
  ssh "${SSH_OPTS[@]}" "${BM_USER}@${host}" "mkdir -p '${BM_PARENT_DIR}' && rm -rf '${staging}' && mkdir -p '${staging}'"
  scp "${SSH_OPTS[@]}" -r "${src}"/* "${BM_USER}@${host}:${staging}/"
  ssh "${SSH_OPTS[@]}" "${BM_USER}@${host}" "rm -rf '${target}' && mv '${staging}' '${target}'"
  echo "[${i}/5] Done: ${BM_USER}@${host}:${target}"
done

echo "All 5 benchmark packages were deployed successfully."
