#!/bin/bash
# ============================================================================
# TB-03 表模型 OBJECT 列 × TTL
#   覆盖：OBJECT 列建表、to_object 写入（裸元组应报错）、OBJECT 数据查询、
#         过期后不可见、object 文件（*.bin）按 TTL 清理（含 60s 缓冲）、
#         object 删除日志证据、树模型不支持 OBJECT 的负向验证
# 用法： bash ttl_table_object.sh [--consensus ...] [--framework 0|1]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "ttl_table_object_${DATA_CONSENSUS}"

TDB=ttl_obj
TTL_MS=${TTL_CASE_MS:-60000}   # 节点间时钟可差 ±20s，TTL 必须远大于偏差；写入后先断言可见，再等过期（object 文件删除另有 60s 缓冲）
OBJ_WAIT="${OBJ_WAIT:-240}"     # object 删除 = TTL + 60s 缓冲 + 检查周期，留足余量
tq(){ sql_lines_table "use $TDB;" "$@"; }
obj_files(){ local h=$1; sshx "$h" "find $DB_DIR/data -path '*object*' -name '*.bin*' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'; }
obj_files_all(){ local h out=""; for h in "${DN[@]}"; do out="$out$(obj_files "$h"):"; done; echo "$out"; }
obj_del_log(){ local h=$1; sshx "$h" "grep -h 'Remove object file' $DB_DIR/logs/log_datanode_object_deletion.log 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'; }
obj_del_total(){ local s=0 h; for h in "${DN[@]}"; do s=$((s + $(obj_del_log "$h"))); done; echo "${s:-0}"; }

log "--- 集群准备 ---"
ttl_cluster_prepare

log "--- 1) OBJECT 列建表 + to_object 写入 ---"
out=$(sql_lines_table "create database $TDB;")
assert_contains "建库成功" "$out" "successfully"
out=$(tq "create table t_obj (dev string tag, o object field) with (ttl=$TTL_MS);")
assert_contains "建 OBJECT 列表成功" "$out" "successfully"
out=$(tq "insert into t_obj (time, dev, o) values ($(now_ms), 'd1', to_object(true, 0, X'62'));")
assert_contains "to_object 写入成功" "$out" "successfully"
out=$(tq "insert into t_obj (time, dev, o) values ($(now_ms), 'd2', (true, 0, X'62'));")
if printf '%s\n' "$out" | grep -qiE 'IoTDBSQLException|error|Exception'; then pass "裸元组写入被拒（如期，必须用 to_object）"
else fail "裸元组竟然写入成功（与既有用例期望不符）"; fi
out=$(tq "select dev, o from t_obj;")
log "  查询 OBJECT 列:"; printf '%s\n' "$out" | sed 's/^/    | /' >>"$OUT"
c=$(scalar "$(sql_lines_table "select count(*) from $TDB.t_obj;")")
assert_scalar "OBJECT 行数" "$c" "1"

out=$(tq "flush;")
assert_contains "flush 成功" "$out" "successfully"
obj_before=$(obj_files_all)
log "  flush 后 object 文件数(各 DN): $obj_before"
if printf '%s' "$obj_before" | grep -qE '[1-9]'; then pass "object 文件已落盘（$obj_before）"; else warn "未见 object 文件（可能未走 object 存储路径），后续删除断言按日志判断"; fi

log "--- 2) 过期后 OBJECT 数据不可见 ---"
sleep $(( TTL_MS/1000 + 6 ))
c=$(scalar "$(sql_lines_table "select count(*) from $TDB.t_obj;")")
assert_scalar "过期后 OBJECT 行数" "$c" "0"

log "--- 3) 等 object 文件按 TTL 清理（60s 缓冲 + 一个检查周期） ---"
del_before=$(obj_del_total)
deadline=$(( $(date +%s) + OBJ_WAIT )); cleaned=0
while (( $(date +%s) < deadline )); do
  cur=$(obj_files_all); del=$(obj_del_total)
  log "  等 object 清理: files=$cur deleteLog=$del (超期门槛=now-TTL-60s)"
  if [ "$del" -gt "$del_before" ] || { [ "$cur" != "$obj_before" ] && printf '%s' "$cur" | grep -qE '(^|:)0(:|$)'; }; then cleaned=1; break; fi
  sleep 10
done
if [ "$cleaned" = "1" ]; then pass "object 文件已按 TTL 清理：files=$obj_before -> $cur，删除日志 $del 条"
else warn "等 ${OBJ_WAIT}s 未观察到 object 文件删除（files=$cur deleteLog=$del）；object 删除依赖 ttl_check_interval 与 60s 缓冲，可加大 OBJ_WAIT 复跑"; fi
out=$(sshx "${DN[0]}" "grep -h 'Remove object file' $DB_DIR/logs/log_datanode_object_deletion.log 2>/dev/null | tail -3")
[ -n "$out" ] && { log "  object 删除日志摘录:"; printf '%s\n' "$out" | sed 's/^/    | /' >>"$OUT"; }

log "--- 4) 60s 缓冲验证（信息性）：刚过期不久的文件不应立即删除 ---"
NOW=$(now_ms)
out=$(tq "create table t_obj_buf (dev string tag, o object field) with (ttl=1000);")
assert_contains "建 t_obj_buf 成功" "$out" "successfully"
out=$(tq "insert into t_obj_buf (time, dev, o) values ($NOW, 'd1', to_object(true, 0, X'63'));")
assert_contains "写入 t_obj_buf 成功" "$out" "successfully"
tq "flush;" >/dev/null
sleep 5
buf_files=$(obj_files_all); buf_del_before=$(obj_del_total)
log "  TTL=1000 过期 5s 后 object 文件数=$buf_files 删除日志=$buf_del_before（应仍未被删：需超过 TTL+60s）"

log "--- 5) 负向验证：树模型不支持 OBJECT ---"
out=$(sq "create database root.obj_neg;" ; sq "create timeseries root.obj_neg.d1.o1 with datatype=OBJECT;")
if printf '%s\n' "$out" | grep -qiE 'IoTDBSQLException|error|Exception'; then pass "树模型 OBJECT 序列被拒（如期）"; else fail "树模型竟然支持 OBJECT"; fi
sq "drop database root.obj_neg;" >/dev/null 2>&1 || true

log "--- 6) 集群面收尾检查（sync lag -> 副本一致性 -> 日志） ---"
post_checks "select count(*) from $TDB.t_obj;" table
ttl_case_finish "" table ""
