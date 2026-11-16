#!/bin/bash
# ============================================================================
# 回归前用例一致性自检（纯 bash，服务器无 python3 也可跑）
#   检查 cases.tsv / cases/*.sh / registry.tsv 三者是否对齐，防止漏跑
#   usage: bash tools/preflight.sh
# ============================================================================
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$BASE" || exit 1

TSV="$BASE/cases.tsv"
REG="$BASE/registry.tsv"
err=0

# 1) cases.tsv 的 ID 集合
tsv_ids=$(awk -F'\t' '$1 ~ /^LB-[0-9]{3}$/ {print $1}' "$TSV" | sort)
tsv_total=$(echo "$tsv_ids" | grep -c . || true)
tsv_uniq=$(echo "$tsv_ids" | sort -u | grep -c . || true)

# 2) 脚本中的 CASES 声明
decl_ids=$(grep -hoE '^"LB-[0-9]{3}\|' "$BASE"/cases/*.sh 2>/dev/null | tr -d '"|' | sort)
decl_total=$(echo "$decl_ids" | grep -c . || true)

# 3) 脚本中的执行函数
func_ids=$(grep -hoE '^case_LB[0-9]{3}\(\)' "$BASE"/cases/*.sh 2>/dev/null | sed -E 's/^case_(LB[0-9]{3})\(\)/\1/' | sort)
func_total=$(echo "$func_ids" | grep -c . || true)

echo "cases.tsv 用例数      : $tsv_total（唯一 $tsv_uniq）"
echo "脚本 CASES 声明数     : $decl_total"
echo "脚本执行函数数        : $func_total"

# 4) 集合比对：cases.tsv vs 声明
missing_decl=$(comm -23 <(echo "$tsv_ids") <(echo "$decl_ids"))
extra_decl=$(comm -13 <(echo "$tsv_ids") <(echo "$decl_ids"))
if [ -n "$missing_decl" ]; then
  echo "[FAIL] cases.tsv 中有、脚本未声明："
  echo "$missing_decl" | sed 's/^/    /'
  err=1
fi
if [ -n "$extra_decl" ]; then
  echo "[FAIL] 脚本已声明、cases.tsv 中缺失："
  echo "$extra_decl" | sed 's/^/    /'
  err=1
fi

# 5) 重复 ID
dup=$(echo "$tsv_ids" | sort | uniq -d)
[ -n "$dup" ] && { echo "[FAIL] cases.tsv 重复 ID：$dup"; err=1; }

# 6) 连续性
nums=$(echo "$tsv_ids" | sed 's/LB-//' | sort -n)
prev=0
for n in $nums; do
  n=$((10#$n))
  if [ $n -ne $((prev + 1)) ]; then
    echo "[FAIL] ID 不连续：缺少 LB-$(printf '%03d' $((prev + 1)))"
    err=1
  fi
  prev=$n
done

# 7) 总账比对
if [ -f "$REG" ]; then
  reg_ids=$(awk -F'\t' '$1 ~ /^LB-[0-9]{3}$/ {print $1}' "$REG" | sort)
  reg_total=$(echo "$reg_ids" | grep -c . || true)
  echo "registry.tsv 记录数   : $reg_total"
  miss_reg=$(comm -23 <(echo "$tsv_ids") <(echo "$reg_ids"))
  extra_reg=$(comm -13 <(echo "$tsv_ids") <(echo "$reg_ids"))
  if [ -n "$miss_reg" ]; then
    echo "[FAIL] 总账遗漏（cases.tsv 有、registry 无）："
    echo "$miss_reg" | sed 's/^/    /'
    err=1
  fi
  if [ -n "$extra_reg" ]; then
    echo "[FAIL] 总账多余（registry 有、cases.tsv 已删）："
    echo "$extra_reg" | sed 's/^/    /'
    err=1
  fi
  # 状态统计
  awk -F'\t' 'NR>1{c[$7]++} END{printf "总账状态              : 执行 %d / 条件执行 %d / 跳过 %d\n", c["执行"], c["条件执行"], c["跳过"]}' "$REG"
else
  echo "[WARN] 未找到 registry.tsv（本地可用 python3 tools/gen_registry.py 生成）"
fi

if [ "$err" = "0" ]; then
  echo "一致性检查通过：cases.tsv / cases/*.sh / registry.tsv 三者对齐。"
  exit 0
else
  echo "发现不一致，请先修正再回归。"
  exit 1
fi
