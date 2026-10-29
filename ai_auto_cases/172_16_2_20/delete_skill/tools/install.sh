#!/bin/bash
# install.sh — 把本 skill 部署到测试机约定工作目录，并做 preflight 校验
set -u
SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK_ROOT=${WORK_ROOT:-/data2/iotdb/rc10_matrix}
CONF=$SKILL_DIR/conf/env.conf

echo "[1/4] skill dir = $SKILL_DIR"
echo "[2/4] work root = $WORK_ROOT"
mkdir -p "$WORK_ROOT"/{scripts,cases,results,logs,artifacts,studies,report}

# 用例
cp -r "$SKILL_DIR"/cases/. "$WORK_ROOT"/cases/
cp "$SKILL_DIR"/cases.tsv "$WORK_ROOT"/delete-cases.tsv
cp "$SKILL_DIR"/conf/manifest-*.tsv "$WORK_ROOT"/ 2>/dev/null

# 脚本
cp "$SKILL_DIR"/lib/*.sh "$WORK_ROOT"/scripts/
cp "$SKILL_DIR"/tools/*.sh "$WORK_ROOT"/scripts/
chmod +x "$WORK_ROOT"/scripts/*.sh

# preflight: MANIFEST.md5 校验
echo "[3/4] preflight manifest check"
fail=0
while read -r md5 rel; do
  f="$WORK_ROOT/$rel"
  if [ ! -f "$f" ]; then echo "  MISSING $rel"; fail=$((fail+1)); continue; fi
  cur=$(md5sum "$f" | cut -d' ' -f1)
  [ "$cur" = "$md5" ] || { echo "  MD5 MISMATCH $rel"; fail=$((fail+1)); }
done < "$SKILL_DIR/cases/MANIFEST.md5"
[ "$fail" -eq 0 ] && echo "  all $(wc -l < "$SKILL_DIR/cases/MANIFEST.md5") files OK" || echo "  $fail problem(s)"

# 环境自检
echo "[4/4] env check"
. "$CONF" 2>/dev/null || true
for h in $CN_HOSTS $DN_HOSTS; do
  ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@$h" "true" 2>/dev/null \
    && echo "  ssh ok  $h" || echo "  ssh FAIL $h"
done
[ -x "$CLI" ] && echo "  cli ok  $CLI" || echo "  cli MISSING $CLI (检查 CLIENT_HOME)"
echo "done. 单例验证：bash $WORK_ROOT/scripts/run_round.sh IoTConsensus DEL-MEM-001"
