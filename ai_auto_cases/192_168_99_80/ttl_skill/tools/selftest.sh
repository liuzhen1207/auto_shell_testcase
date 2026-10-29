#!/bin/bash
# ============================================================================
# selftest.sh —— 校验 harness 自身（不依赖集群的部分全部本地跑）
#
#   参考 remove_cn_dn skill 的做法："一个什么都不跑却 exit 0 的用例集，看起来和通过一模一样"，
#   所以 harness 的解析/计数/写配置逻辑也要有自检。这里覆盖本项目实际踩过的坑：
#     1) 所有用例/工具 bash -n 语法；
#     2) 按库统计的正则能同时匹配树模型（root.xxx-3）与表模型（xxx-3 / root.xxx-3）日志行，
#        且不会误匹配前缀相同的其它库（ttl_x vs ttl_x2）；
#     3) ttl_effective_conf 能解析 `show configuration` 的三列输出；
#     4) 断言框架：fail() 必须让 fail_flag > 0（否则"失败被吞掉"）；
#     5) 用例之间没有重名的库/表（重名会通过日志计数与 TsFile 计数互相污染）；
#     6) cluster_set_conf 的 heredoc 里不得出现未转义的本地变量（曾导致整批写配置失败）；
#     7) 可选：集群在跑时，写配置 round-trip（写 → 逐节点读回）。
#
# 用法： bash tools/selftest.sh [--env conf/env.conf]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
. "$SKILL/lib/common.sh"

PASS=0; FAILED=0
ok(){   PASS=$((PASS+1));   printf 'ok   %s\n' "$*"; }
bad(){  FAILED=$((FAILED+1)); printf 'FAIL %s\n' "$*"; }
chk(){  if [ "$2" = "$3" ]; then ok "$1 (= $3)"; else bad "$1: 实际=[$2] 期望=[$3]"; fi; }

echo "===== 1) 语法检查 ====="
while IFS= read -r f; do
  if bash -n "$f" 2>/tmp/st.err; then ok "bash -n ${f#$SKILL/}"; else bad "bash -n ${f#$SKILL/}: $(cat /tmp/st.err)"; fi
done < <(find "$SKILL/cases" "$SKILL/tools" -name '*.sh' | sort)

echo "===== 2) 按库统计正则（树/表模型 + 不误匹配） ====="
# 与 lib/common.sh 中 settle_task_for_db / ttl_sel_for_db 的正则保持一致
SETTLE_RE='(^|[- ])(root\.)?ttl_x-[0-9]+ \[Compaction\] SettleCompaction task starts with'
SEL_RE='\[TTL\] (root\.)?ttl_x-[0-9]+ Totally select ([1-9][0-9]* all-outdated|[0-9]+ all-outdated files and [1-9][0-9]* partial-outdated)'
FIX="$SKILL/results/.selftest_fixture.log"; mkdir -p "$SKILL/results"; : >"$FIX"
{
  printf '%s\n' "2026-01-01 00:00:00 [x] INFO - root.ttl_x-3 [Compaction] SettleCompaction task starts with 0 fully_dirty files and 1 partially_dirty files."
  printf '%s\n' "2026-01-01 00:00:01 [x] INFO - ttl_x-7 [Compaction] SettleCompaction task starts with 1 fully_dirty files and 0 partially_dirty files."
  printf '%s\n' "2026-01-01 00:00:02 [x] INFO - root.ttl_x2-3 [Compaction] SettleCompaction task starts with 9 fully_dirty files and 0 partially_dirty files."
  printf '%s\n' "2026-01-01 00:00:03 [x] INFO - [TTL] root.ttl_x-3 Totally select 0 all-outdated files and 1 partial-outdated files."
  printf '%s\n' "2026-01-01 00:00:04 [x] INFO - [TTL] ttl_x-4 Totally select 2 all-outdated files and 0 partial-outdated files."
  printf '%s\n' "2026-01-01 00:00:05 [x] INFO - [TTL] root.ttl_x-5 Totally select 0 all-outdated files and 0 partial-outdated files."
} >>"$FIX"
chk "settle 计数（root.ttl_x + ttl_x，排除 ttl_x2）" "$(grep -hcE "$SETTLE_RE" "$FIX")" "2"
chk "TTL 选中计数（只数非 0 候选）"                  "$(grep -hcE "$SEL_RE" "$FIX")" "2"

echo "===== 3) ttl_effective_conf 解析（show configuration 三列） ====="
SC_FIX="$(printf '%s\n' \
 '|                            name|          value|   default_value|' \
 '|                expired_data_ratio|         0.99|             0.3|' \
 '|                  max_expired_time|    3600000|      2592000000|' \
 '|              ttl_check_interval|      15000|         7200000|')"
parse_conf(){ local out="$1" k="$2"; printf '%s\n' "$out" | awk -F'|' -v k="$k" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3)} $2==k{print $3; exit}'; }
chk "解析 expired_data_ratio" "$(parse_conf "$SC_FIX" expired_data_ratio)" "0.99"
chk "解析 max_expired_time"   "$(parse_conf "$SC_FIX" max_expired_time)"   "3600000"
chk "解析 ttl_check_interval" "$(parse_conf "$SC_FIX" ttl_check_interval)" "15000"

echo "===== 4) 断言框架：fail() 必须计入 fail_flag ====="
OUT=/dev/null; fail_flag=0; v_warnMessage=""
fail "selftest 故意失败"
[ "$fail_flag" -gt 0 ] && ok "fail() 让 fail_flag=$fail_flag" || bad "fail() 未计入 fail_flag（失败会被吞掉）"
fail_flag=0

echo "===== 5) 用例之间不得重名库/表 ====="
# 只看"声明式赋值"（大写变量 = root.xxx / ttl_xxx），避免把用例内部重复出现当重名
decls=$(for f in "$SKILL"/cases/*/*.sh; do
  grep -hoE '^[A-Z][A-Z0-9_]*=("?)(root\.)?[a-z][a-z0-9_]*("?)$' "$f" 2>/dev/null \
    | sed -E 's/^[A-Z0-9_]+=//; s/"//g'
done | sort -u)
dups=$(printf '%s\n' "$decls" | sort | uniq -d | grep -vE '^$' | tr '\n' ' ')
if [ -z "$dups" ]; then ok "无跨用例重名库/表（$(printf '%s\n' "$decls" | grep -c .) 个标识）"; else bad "跨用例重名库/表（日志/TsFile 计数会互相污染）: $dups"; fi

echo "===== 6) cluster_set_conf 在 set -u 下的本地展开（回归：曾导致整批写配置失败） ====="
dryrun_conf(){
  ttl_load_env                      # 先取 SSH_OPTS/DB_DIR 等环境变量，否则测的是"没 source env"
  ssh(){ cat >/dev/null; }          # 吞掉 heredoc，模拟远端成功
  sshx(){ :; }
  fail(){ echo "FAIL(in-dryrun) $*" >&2; }
  TTL_CHECK_INTERVAL_MS=5000 MAX_EXPIRED_TIME_MS=9223372036854775807 EXPIRED_DATA_RATIO=0.000001 cluster_set_conf 192.168.99.77
}
if ( set -u; dryrun_conf ) 2>/tmp/dry1.err; then ok "无 EXTRA_CONF：heredoc 展开正常"; else bad "无 EXTRA_CONF：$(head -1 /tmp/dry1.err)"; fi
dryrun_conf_extra(){
  ttl_load_env
  ssh(){ cat >/dev/null; }
  sshx(){ :; }
  fail(){ echo "FAIL(in-dryrun) $*" >&2; }
  EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false" \
  TTL_CHECK_INTERVAL_MS=5000 MAX_EXPIRED_TIME_MS=9223372036854775807 EXPIRED_DATA_RATIO=0.000001 cluster_set_conf 192.168.99.77
}
if ( set -u; dryrun_conf_extra ) 2>/tmp/dry2.err; then ok "带 EXTRA_CONF：heredoc 展开正常"; else bad "带 EXTRA_CONF：$(head -1 /tmp/dry2.err)"; fi

echo "===== 6b) 静态检查：同一条 local 里"先赋值、后在本行算术展开中引用"（set -u 下会 unbound） ====="
# 只认"形如 name= 的赋值词"里的 name（排除 local 关键字、${3:-90} 这类展开产生的碎片）
dang=$(awk '
  /^[[:space:]]*local[[:space:]]/ && /\$\(\(/ {
    left=$0; sub(/\$\(\(.*/,"",left); right=$0; sub(/.*\$\(\(/,"",right)
    n=split(left,t,/[^A-Za-z0-9_]/)
    for(i=1;i<=n;i++){ tok=t[i]; if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
        # 该 token 后面紧跟 "=" 才算赋值（用正则回查原串）
        if (left ~ ("(^|[^A-Za-z0-9_])" tok "=") && right ~ ("(^|[^A-Za-z0-9_])" tok "([^A-Za-z0-9_]|$)")) print NR":"tok } }
  }' "$SKILL/lib/common.sh" | sort -u | tr '\n' ' ')
if [ -z "$dang" ]; then ok "lib 无该模式"; else bad "lib 命中危险模式（行:变量）: $dang"; fi

echo "===== 7) 集群在跑时：写配置 round-trip ====="
ttl_load_env
if [ "${SELFTEST_NO_CLUSTER:-0}" = "1" ]; then
  echo "skip  SELFTEST_NO_CLUSTER=1（用例运行中不要动集群配置，避免互相干扰）"
elif sq 'show cluster;' 2>/dev/null | grep -qE 'Running|ReadOnly'; then
  TTL_CHECK_INTERVAL_MS=${TTL_CHECK_INTERVAL_MS:-5000} MAX_EXPIRED_TIME_MS=${MAX_EXPIRED_TIME_MS:-60000} \
  EXPIRED_DATA_RATIO=${EXPIRED_DATA_RATIO:-0.000001} cluster_write_conf >/dev/null 2>&1
  if [ "${fail_flag:-0}" -eq 0 ]; then ok "写配置 + 逐节点读回一致"; else bad "写配置 round-trip 失败（fail_flag=$fail_flag）"; fi
  fail_flag=0
else
  echo "skip  集群未运行，跳过写配置 round-trip（需要时先起集群）"
fi

rm -f "$FIX"
echo
echo "===== selftest 结束：ok=$PASS failed=$FAILED ====="
[ "$FAILED" -eq 0 ] || exit 1
