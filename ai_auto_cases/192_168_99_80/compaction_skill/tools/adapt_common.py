#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把通用 harness（lib/common.sh，源自 TTL skill）适配成合并 skill 版本：
   1) 异常正则：补 OOM / 越界 / overlap 等（用户要求）
   2) TTL 专项异常 → 合并专项异常
   3) check_logs 的"正证据"从 TTL 检查次数改为合并完成行数
   4) 入口函数改名 ttl_* → cmp_*
   5) 追加 consistency_check_on / post_checks_on（可指定节点子集，供 REMOVE DN 用例用）
"""
import re
import sys

path = sys.argv[1]
src = open(path, encoding='utf-8').read()
orig = src

# 1) 通用异常正则
src = re.sub(
    r"^COMMON_ERR_PAT=.*$",
    "COMMON_ERR_PAT='NullPointerException|OutOfMemoryError|Java heap space|GC overhead limit exceeded"
    "|BufferUnderflowException|IndexOutOfBoundsException|ArrayIndexOutOfBoundsException"
    "|NegativeArraySizeException|NumberFormatException|has overlapped data|overlapped data"
    "|CompactionTableSchemaNotMatchException|DataTypeInconsistentException|StatisticsClassException"
    "|is not in tsFileMetaData|but return HAS_MORE_STATE'",
    src, count=1, flags=re.M)

# 2) TTL 专项异常 → 合并专项异常
src = re.sub(
    r"^TTL_ERR_PAT=.*$",
    "CMP_ERR_PAT='Compaction[^|]*(failed|Failed|FAILED|error|Error)|Failed to (compaction|compact|merge)"
    "|task (is )?(killed|aborted)|CompactionException|Failed to recover compaction'",
    src, count=1, flags=re.M)

# 3) check_logs 里引用改名
src = src.replace('pat="$COMMON_ERR_PAT|$TTL_ERR_PAT${extra:+|$extra}"',
                  'pat="$COMMON_ERR_PAT|$CMP_ERR_PAT${extra:+|$extra}"')

# 4) 正证据：TTL 检查次数 → 合并完成行数
src = re.sub(
    r"  # TTL 检查任务是否真的跑过（正证据）\n(?:.*\n)*?.*TTL 检查任务累计启动次数.*\n",
    "  # 合并任务是否真的跑过（正证据）：全部 DN 上 inner/cross/settle 的 starts / finishes 行数\n"
    "  local started finished\n"
    "  started=$(sum_over cmp_start_cnt_all)\n"
    "  finished=$(sum_over cmp_finish_cnt_all)\n"
    "  log \"  合并任务累计（全部 DN、全部库）：starts=${started:-0} finishes=${finished:-0}\"\n",
    src, count=1)

# 5) 入口函数改名
for a, b in (('ttl_load_env', 'cmp_load_env'), ('ttl_parse_args', 'cmp_parse_args'),
             ('ttl_case_init', 'cmp_case_init'), ('ttl_cluster_prepare', 'cmp_cluster_prepare'),
             ('ttl_case_finish', 'cmp_case_finish')):
    src = src.replace(a, b)

# 6) 追加：可指定节点子集的收尾（REMOVE DN 场景）
src += '''

# ---------------------------------------------------------------------------
# 收尾（可指定节点子集）：REMOVE DATANODE / CONFIGNODE 之后集群节点数变了，
# 一致性只能按"仍在集群里的 DataNode"来比。
#   consistency_check_on "<节点,空格分隔>" <SQL> <tree|table>
# ---------------------------------------------------------------------------
consistency_check_on(){
  local nodes_str=$1 sql=$2 dialect=${3:-tree} h on cur base
  local nodes=(); read -ra nodes <<<"$nodes_str"
  log "=== 副本一致性校验（${dialect}，节点: ${nodes[*]}）: $sql ==="
  base=$(query_result "${nodes[0]}" "$dialect" "$sql")
  log "  基准(经 ${nodes[0]}): [$(printf '%s' "$base" | tr '\\n' ' ')]"
  for h in "${nodes[@]}"; do
    [ "$h" = "${nodes[0]}" ] && continue
    cur=$(query_result "$h" "$dialect" "$sql")
    [ "$cur" = "$base" ] && pass "全部在线: $h 与基准一致" \\
      || fail "全部在线副本不一致: $h=[$(printf '%s' "$cur" | tr '\\n' ' ')] 基准=[$(printf '%s' "$base" | tr '\\n' ' ')]"
  done
  for h in "${nodes[@]}"; do
    log "  --- 停 DataNode $h ---"
    sshx "$h" "$DB_DIR/sbin/stop-datanode.sh -f >/dev/null 2>&1 || true; pkill -f 'com\\\\.timecho\\\\.iotdb\\\\.DataNode' >/dev/null 2>&1 || true" || true
    wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "停 $h 后集群仍显示 Running"
    for on in "${nodes[@]}"; do
      [ "$on" = "$h" ] && continue
      cur=$(query_result "$on" "$dialect" "$sql")
      [ "$cur" = "$base" ] && pass "停 $h 时经 $on 查询一致" \\
        || fail "停 $h 后经 $on 查询与基准不一致: [$(printf '%s' "$cur" | tr '\\n' ' ')] vs [$(printf '%s' "$base" | tr '\\n' ' ')]"
    done
    sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}.log 2>&1 </dev/null &" || true
    wait_dn_state "$h" running "$DN_RECOVER_WAIT_SEC" || fail "DataNode $h 未恢复 Running"
  done
}
'''

open(path, 'w', encoding='utf-8').write(src)
print('changed:', src != orig)
for pat in ('COMMON_ERR_PAT=', 'CMP_ERR_PAT=', 'finishes=', 'cmp_load_env', 'consistency_check_on'):
    print(pat, '->', src.count(pat))
