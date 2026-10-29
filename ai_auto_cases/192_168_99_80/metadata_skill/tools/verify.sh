#!/bin/bash
cd /data/iotdb/autotest/metadata_skill || exit 1
for f in lib/common.sh tools/run_all.sh cases/common/md_udf_trigger.sh cases/common/md_privilege_matrix.sh cases/common/md_scale_bulk.sh; do
  bash -n "$f" || echo "SYNTAXFAIL $f"
done
echo "syntax OK"
SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh 2>&1 | tail -2
