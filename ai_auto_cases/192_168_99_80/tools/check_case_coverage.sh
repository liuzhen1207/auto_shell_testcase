#!/bin/bash
# ============================================================================
# check_case_coverage.sh —— 回归前/后对账：检查某构建是否有"没跑"的用例
#   用法： bash tools/check_case_coverage.sh [build] [--quiet]
#         默认 build 取清单里固化的目标构建；任意构建都可查（实时扫描各 skill 的 CSV）
#   退出码：0=全覆盖；2=有未跑；1=清单缺失
# ============================================================================
set -u
A=/data/iotdb/autotest
TSV=$A/manifest/skill_cases_manifest.tsv
QUIET=0
BUILD=""
for a in "$@"; do
  case "$a" in
    --quiet) QUIET=1 ;;
    *) BUILD="$a" ;;
  esac
done
if [ -z "${BUILD:-}" ]; then
  BUILD=$(grep -oE 'result_[0-9a-zA-Z_]+' "$TSV" 2>/dev/null | head -1 | sed 's/result_//')
fi
[ -z "${BUILD:-}" ] && BUILD="83183d0"
if [ ! -f "$TSV" ]; then
  echo "清单不存在：$TSV（先跑 bash tools/gen_case_manifest.sh --build $BUILD）" >&2
  exit 1
fi

python3 - "$A" "$TSV" "$BUILD" "$QUIET" <<'PY'
import csv, os, re, sys, glob, collections
A, TSV, BUILD, QUIET = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"

def norm(n):
    n = re.sub(r"\.sh$", "", n.strip())
    return re.sub(r"_(org\.apache\.iotdb\.[A-Za-z0-9_.]+|IoTConsensusV2|IoTConsensus)$", "", n)

# 清单里的期望用例
expected = []
with open(TSV, encoding="utf-8") as f:
    rd = csv.DictReader(f, delimiter="\t")
    for r in rd:
        expected.append((r["skill"], r["id"], r["file"]))

# 每个 skill 在该构建下跑过的用例
ran = collections.defaultdict(set)
for s in sorted({e[0] for e in expected}):
    p = os.path.join(A, s, "results", "test_result.csv")
    if not os.path.exists(p):
        continue
    csv.field_size_limit(10**7)
    with open(p, errors="replace") as fh:
        for row in csv.reader(fh):
            if len(row) < 6 or row[0].strip() in ("Time", ""):
                continue
            if BUILD in row[1]:
                ran[s].add(norm(row[3]))

missing = []
for skill, cid, file in expected:
    if norm(os.path.basename(file)) in ran.get(skill, set()):
        continue
    missing.append((skill, cid, file))

total = len(expected)
if not QUIET:
    print(f"== 覆盖率检查：build={BUILD} ==")
    for skill, cid, file in missing:
        print(f"  未跑  {skill:<18} {cid:<8} {file}")
    print()
print(f"  合计 {total} 条，未跑 {len(missing)} 条，覆盖 {total - len(missing)} 条")
sys.exit(2 if missing else 0)
PY
