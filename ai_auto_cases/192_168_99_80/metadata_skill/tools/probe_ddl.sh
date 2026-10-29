#!/bin/bash
# ============================================================================
# DDL 探测工具：把"元数据 DDL 全集"逐条打到目标版本上，记录
#   状态(OK/ERR)  错误码  首行消息
# 目的：用例只写被测版本**真实支持**的语法；支持的/不支持的都进
#       docs/DDL_INVENTORY.md（这是"以元数据为测试目的"的第一步：先把 DDL 面摸清）。
#
#   bash tools/probe_ddl.sh [--consensus IoTConsensus|IoTConsensusV2] [--file 清单]
#
# 只读探测（不重启集群、不改配置）；create 出来的对象在结尾统一 drop。
# 清单：docs/ddl_probe_list.tsv（label <TAB> dialect <TAB> SQL），按序执行。
# ============================================================================
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

LIST_FILE="${PROBE_LIST:-$MD_SKILL_DIR/docs/ddl_probe_list.tsv}"
OUT_TSV="${PROBE_OUT:-$MD_SKILL_DIR/docs/DDL_PROBE_RESULT.tsv}"
[ -f "$LIST_FILE" ] || { echo "缺少探测清单 $LIST_FILE"; exit 2; }
mkdir -p "$MD_SKILL_DIR/results" "$(dirname "$OUT_TSV")"

# probe 不走用例脚手架，但要给 log 一个去处
OUT="$MD_SKILL_DIR/results/probe_ddl_$(date +%Y%m%d_%H%M%S).out"
: >"$OUT"
fail_flag=0; v_warnMessage=""; RUN_ID="probe"; ART=""; CASE="probe_ddl"
log "DDL 探测开始：版本=$V_TESTDB 共识=${CONSENSUS_CLASS##*.} 清单=$LIST_FILE"

printf 'label\tdialect\tsql\tstatus\tcode\tmsg\n' >"$OUT_TSV"
n_ok=0; n_err=0
while IFS=$'\t' read -r label dialect sql; do
  case "$label" in ''|'#'*) continue ;; esac
  out=$(sql_on "$QDN" "$dialect" "$sql")
  if is_error "$out"; then
    st=ERR; code=$(err_code "$out")
    msg=$(err_msg "$out")
    [ -z "$msg" ] && msg=$(printf '%s' "$out" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-200)
    n_err=$((n_err+1))
  else
    st=OK; code=""
    msg=$(printf '%s\n' "$out" | table_rows | head -1 | sed -E 's/[[:space:]]+/ /g' | cut -c1-160)
    [ -z "$msg" ] && msg=$(printf '%s\n' "$out" | grep -vE '^$' | tail -1 | cut -c1-120)
    n_ok=$((n_ok+1))
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$dialect" "$sql" "$st" "$code" "$msg" >>"$OUT_TSV"
  printf '%-26s %-5s %-4s %s\n' "$label" "$dialect" "$st" "${code:+[$code] }$msg"
done <"$LIST_FILE"

# ---- 清理 ----
log "--- 清理探测对象 ---"
sql_on "$QDN" tree  'DROP TRIGGER IF EXISTS trg_probe;' >/dev/null 2>&1
sql_on "$QDN" tree  'DROP SCHEMA TEMPLATE IF EXISTS tpl_probe;' >/dev/null 2>&1
sql_on "$QDN" tree  'DROP SCHEMA TEMPLATE IF EXISTS tpl_probe2;' >/dev/null 2>&1
sql_on "$QDN" tree  'DROP DATABASE IF EXISTS root.mdprobe;' >/dev/null 2>&1
sql_on "$QDN" tree  'DROP DATABASE IF EXISTS root.mdprobe2;' >/dev/null 2>&1
sql_on "$QDN" tree  'DROP DATABASE IF EXISTS root.mdprobe3;' >/dev/null 2>&1
sql_on "$QDN" tree  'DROP DATABASE IF EXISTS root.mdprobe4;' >/dev/null 2>&1
sql_on "$QDN" tree  'DROP DATABASE IF EXISTS root.mdprobe6;' >/dev/null 2>&1
sql_on "$QDN" tree  'DROP DATABASE IF EXISTS root.mdprobe7;' >/dev/null 2>&1
sql_on "$QDN" table 'DROP DATABASE IF EXISTS mdprobe_t;' >/dev/null 2>&1

echo
echo "探测完成：OK=$n_ok ERR=$n_err  结果文件=$OUT_TSV"
awk -F'\t' 'NR>1 && $4=="OK"  {printf "  OK  %s\t%s\t%s\n", $1, $2, substr($6,1,70)}' "$OUT_TSV"
awk -F'\t' 'NR>1 && $4=="ERR" {printf "  ERR %s\t%s\t%s\t%s\n", $1, $2, $5, substr($6,1,110)}' "$OUT_TSV"
