#!/bin/bash
# ============================================================================
# selftest.sh —— 校验 harness 自身（不依赖集群的部分全部本地跑）
#
#   "一个什么都不跑却 exit 0 的用例集，看起来和通过一模一样"，
#   所以判定/解析/写配置逻辑必须有自检：
#     1) 所有 .sh 语法；
#     2) 元数据归一化 md_rows/md_digest/md_names（排序、去表头、压空白）；
#     3) 集合断言与错误断言的行为（含"故意失败必须 fail_flag>0"）；
#     4) 用例之间不得重名库/表（重名会通过日志计数互相污染）；
#     5) cluster_set_conf 的 heredoc 在 set -u 下的展开（回归：曾导致整批写配置失败）；
#     6) 静态检查：同一条 local 里"先赋值、后在本行算术展开中引用"（set -u 下 unbound，函数静默返回空）；
#     7) cases.tsv 与实际脚本一一对应、lifecycle 合法；
#     8) 可选：集群在跑时写配置 round-trip。
#
#   bash tools/selftest.sh
#   SELFTEST_NO_CLUSTER=1 bash tools/selftest.sh   # 用例运行中不要动集群配置
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
. "$SKILL/lib/common.sh"

PASS=0; FAILED=0
ok(){  PASS=$((PASS+1));    printf 'ok   %s\n' "$*"; }
bad(){ FAILED=$((FAILED+1)); printf 'FAIL %s\n' "$*"; }
chk(){ if [ "$2" = "$3" ]; then ok "$1 (= $3)"; else bad "$1: 实际=[$2] 期望=[$3]"; fi; }

echo "===== 1) 语法检查 ====="
while IFS= read -r f; do
  if bash -n "$f" 2>/tmp/st.err; then ok "bash -n ${f#$SKILL/}"; else bad "bash -n ${f#$SKILL/}: $(cat /tmp/st.err)"; fi
done < <(find "$SKILL/cases" "$SKILL/tools" "$SKILL/lib" -name '*.sh' 2>/dev/null | sort)

echo "===== 2) 元数据归一化 ====="
FIXTURE=$(printf '%s\n' \
 'TimechoDB> SHOW DATABASES' \
 '+-----------------------------+-------------------------+' \
 '|                      Database|TTL(ms)                  |' \
 '+-----------------------------+-------------------------+' \
 '|                 root.md_t01|  INF                    |' \
 '|        root.md_t01|  4000  |' \
 '|                     root.a|   INF                   |' \
 '+-----------------------------+-------------------------+' \
 'Total line number = 3')
chk "md_rows 行数（排序后，含重复行）" "$(md_rows "$FIXTURE" | wc -l | tr -d ' ')" "3"
chk "md_rows 首行（按整行排序）"          "$(md_rows "$FIXTURE" | head -1)" "| root.a| INF |"
chk "md_names 去重 + 取第 1 列"          "$(md_names "$FIXTURE" | wc -l | tr -d ' ')" "2"
chk "md_names 内容"                      "$(md_names "$FIXTURE" | tr '\n' ',')" "root.a,root.md_t01,"
chk "空输出 -> EMPTY"                    "$(norm_result 'Empty set.')" "EMPTY"
chk "md_last_col 取最后一列"             "$(printf '%s\n' "$FIXTURE" | md_last_col)" "INF"

# 多批次结果：CLI 超过一批（实测 1000 行）会重复打印表头，必须全部丢掉
BATCH=$(printf '%s\n' \
 '+-----------------------------+' \
 '|                      Database|' \
 '+-----------------------------+' \
 '|                     root.b1|' \
 '|                     root.b2|' \
 '+-----------------------------+' \
 '|                      Database|' \
 '+-----------------------------+' \
 '|                     root.b3|' \
 '+-----------------------------+' \
 'Total line number = 3')
chk "多批次表头只算数据行"  "$(md_count "$(md_rows "$BATCH")")" "3"
chk "多批次 md_names 不含表头" "$(md_names "$BATCH" | tr '\n' ',')" "root.b1,root.b2,root.b3,"

echo "===== 3) 断言行为 ====="
OUT=/dev/null; fail_flag=0; v_warnMessage=""; RUN_ID=selftest; ART=/tmp; CASE=selftest
assert_set_eq  "集合相等" "$(printf 'a\nb')" "$(printf 'b\na')"
chk "assert_set_eq 相等不计数" "$fail_flag" "0"
assert_set_eq  "集合不等" "$(printf 'a\nb')" "$(printf 'a\nc')"
chk "assert_set_eq 不等计数"   "$fail_flag" "1"
assert_set_has "含元素"   "$(printf 'a\nb')" "a"
assert_set_lacks "不含元素" "$(printf 'a\nb')" "z"
chk "has/lacks 正确不计数" "$fail_flag" "1"
assert_set_lacks "不应含" "$(printf 'a\nb')" "a"
chk "assert_set_lacks 命中计数" "$fail_flag" "2"

REAL_ERR=$(printf '%s\n' 'Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 500: Database already exists')
assert_error "报错+错误码" "$REAL_ERR" '500'
chk "assert_error 命中不计数" "$fail_flag" "2"
assert_error "报错但码不符" "$REAL_ERR" '701'
chk "assert_error 码不符计数" "$fail_flag" "3"
assert_error "期望报错却成功" "Total line number = 1" '500'
chk "assert_error 未报错计数" "$fail_flag" "4"
assert_ok "成功断言" "Total line number = 1"
chk "assert_ok 成功不计数" "$fail_flag" "4"
assert_ok "成功断言(实际报错)" "$REAL_ERR"
chk "assert_ok 遇错计数" "$fail_flag" "5"
chk "err_code 提取" "$(err_code "$REAL_ERR")" "500"
fail_flag=0

echo "===== 4) 用例之间不得重名库/表 ====="
decls=$(for f in "$SKILL"/cases/*/*.sh; do
  [ -f "$f" ] || continue
  grep -hoE '^[A-Z][A-Z0-9_]*=("?)(root\.)?[a-z][a-z0-9_]*("?)$' "$f" 2>/dev/null | sed -E 's/^[A-Z0-9_]+=//; s/"//g'
done | sort -u)
dups=$(printf '%s\n' "$decls" | sort | uniq -d | grep -vE '^$' | tr '\n' ' ')
if [ -z "$dups" ]; then ok "无跨用例重名库/表（$(printf '%s\n' "$decls" | grep -c .) 个标识）"; else bad "跨用例重名库/表: $dups"; fi

echo "===== 5) cluster_set_conf 在 set -u 下的 heredoc 展开 ====="
dry(){
  md_load_env >/dev/null 2>&1
  ssh(){ cat >/dev/null; }
  sshx(){ :; }
  fail(){ echo "FAIL(in-dryrun) $*" >&2; }
  EXTRA_CONF="${1:-}" cluster_set_conf 192.168.99.77
}
if ( set -u; dry "" ) 2>/tmp/d1.err; then ok "无 EXTRA_CONF：展开正常"; else bad "无 EXTRA_CONF：$(head -1 /tmp/d1.err)"; fi
if ( set -u; dry "enable_last_cache=false,ttl_check_interval=5000" ) 2>/tmp/d2.err; then ok "带 EXTRA_CONF：展开正常"; else bad "带 EXTRA_CONF：$(head -1 /tmp/d2.err)"; fi

echo "===== 6) 静态检查：local 同行"先赋值后引用" ====="
dang=$(awk '
  /^[[:space:]]*local[[:space:]]/ && /\$\(\(/ {
    left=$0; sub(/\$\(\(.*/,"",left); right=$0; sub(/.*\$\(\(/,"",right)
    n=split(left,t,/[^A-Za-z0-9_]/)
    for(i=1;i<=n;i++){ tok=t[i]; if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
        if (left ~ ("(^|[^A-Za-z0-9_])" tok "=") && right ~ ("(^|[^A-Za-z0-9_])" tok "([^A-Za-z0-9_]|$)")) print NR":"tok } }
  }' "$SKILL/lib/common.sh" | sort -u | tr '\n' ' ')
if [ -z "$dang" ]; then ok "lib 无该模式"; else bad "lib 命中危险模式（行:变量）: $dang"; fi

echo "===== 7) cases.tsv 与实际脚本一一对应 ====="
TSV="$SKILL/cases/cases.tsv"
if [ -f "$TSV" ]; then
  miss=""; badlife=""
  while IFS=$'\t' read -r id cset dialect script lifecycle title; do
    case "$id" in ''|'#'*) continue ;; esac
    [ -f "$SKILL/cases/$script" ] || miss="$miss $id"
    case "$lifecycle" in reuse|fresh) ;; *) badlife="$badlife $id($lifecycle)";; esac
  done <"$TSV"
  [ -z "$miss" ]    && ok "所有条目的脚本都存在" || bad "缺脚本:$miss"
  [ -z "$badlife" ] && ok "lifecycle 取值合法"   || bad "非法 lifecycle:$badlife"
  dupid=$(awk -F'\t' 'NR>1 && $1!="" {print $1}' "$TSV" | sort | uniq -d | tr '\n' ' ')
  [ -z "$dupid" ] && ok "用例号唯一" || bad "重复用例号: $dupid"
else
  bad "缺少 $TSV"
fi

echo "===== 8) 集群在跑时：写配置 round-trip ====="
md_load_env >/dev/null 2>&1
if [ "${SELFTEST_NO_CLUSTER:-0}" = "1" ]; then
  echo "skip  SELFTEST_NO_CLUSTER=1"
elif sq 'show cluster;' 2>/dev/null | grep -qE 'Running|ReadOnly'; then
  OUT=/dev/null; fail_flag=0; v_warnMessage=""
  cluster_write_conf >/dev/null 2>&1
  if [ "${fail_flag:-0}" -eq 0 ]; then ok "写配置 + 逐节点读回一致"; else bad "写配置 round-trip 失败（fail_flag=$fail_flag）"; fi
  fail_flag=0
else
  echo "skip  集群未运行，跳过写配置 round-trip"
fi

echo
echo "===== selftest 结束：ok=$PASS failed=$FAILED ====="
[ "$FAILED" -eq 0 ] || exit 1
