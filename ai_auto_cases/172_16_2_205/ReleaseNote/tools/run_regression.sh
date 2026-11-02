#!/bin/bash
# ReleaseNote 一键回归：等同 suite_rn.sh，保留统一入口
#   bash tools/run_regression.sh            # 全部
#   bash tools/run_regression.sh RN-002     # 指定用例
# 退出码：0 全通过；10 有已知缺陷失败；3 有新增失败；4 环境异常
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
bash "$BASE/tools/suite_rn.sh" "$@"
rc=$?
case "$rc" in
  0)  echo "[ReleaseNote] 全部通过"; exit 0 ;;
  10) echo "[ReleaseNote] 存在失败用例（详见 results.tsv）"; exit 10 ;;
  4)  echo "[ReleaseNote] 环境异常"; exit 4 ;;
  *)  echo "[ReleaseNote] 失败（rc=$rc）"; exit 3 ;;
esac