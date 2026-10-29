#!/bin/bash
# probe_sql.sh —— 只为"摸清语法/行为"的一次性探针（不写 test_result.csv 判定）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
ttl_load_env
ttl_case_init "probe_sql"
ttl_cluster_prepare

try(){ local tag=$1 sql=$2 out; out=$(sq "$sql" 2>&1)
  log "===== [$tag] $sql"
  printf '%s\n' "$out" | strip_echo | sed 's/^/    | /' | tee -a "$OUT" >/dev/null
  printf '%s\n' "$out" | strip_echo | head -12
}

DB=root.probe_scope
try "建库" "create database $DB;"
try "建序列" "create timeseries $DB.d1.s1 with datatype=int64;"
try "写1点" "insert into $DB.d1(time,s1) values($(now_ms), 1);"

log "############ A) 作用域/继承"
try "A1 root.** 设 TTL" "set ttl to root.** 100000;"
try "A2 库级覆盖" "set ttl to $DB 200000;"
try "A3 设备级覆盖" "set ttl to $DB.d1 300000;"
try "A4 SHOW DEVICES" "show devices;"
try "A5 SHOW ALL TTL" "show all ttl;"
try "A6 SHOW TTL ON db" "show ttl on $DB;"
try "A7 设备级 TTL 存在性" "show ttl on $DB.d1;"

log "############ B) 边界/错误码"
try "B1 不存在路径" "set ttl to $DB.nodev.** 1000;"
try "B2 非法 pattern" "set ttl to $DB.d1+.s1 1000;"
try "B3 TTL=0" "set ttl to $DB.d1 0;"
try "B4 TTL=-1" "set ttl to $DB.d1 -1;"
try "B5 TTL=极大" "set ttl to $DB.d1 9223372036854775807;"
try "B6 unset 无规则库" "unset ttl from root.probe_norule;"
try "B7 序列级 TTL" "set ttl to $DB.d1.s1 5000;"

log "############ C) 取消 TTL 后可见性（先关 compaction 免物理删除）"
sq "set configuration 'enable_seq_space_compaction'='false';" >/dev/null
sq "set configuration 'enable_unseq_space_compaction'='false';" >/dev/null
try "C1 设小 TTL" "set ttl to $DB.d1 3000;"
sleep 20
try "C2 过期后可见性" "select count(*) from $DB.d1;"
try "C3 unset 后可见性" "unset ttl from $DB.d1;"
sleep 3
try "C4 unset 后查询" "select count(*) from $DB.d1;"
sq "set configuration 'enable_seq_space_compaction'='true';" >/dev/null
sq "set configuration 'enable_unseq_space_compaction'='true';" >/dev/null

log "############ D) 表模型属性面"
tryt(){ local tag=$1 sql=$2 out; out=$(sqt "$sql" 2>&1)
  log "===== [$tag] $sql"
  printf '%s\n' "$out" | strip_echo | sed 's/^/    | /' | tee -a "$OUT" >/dev/null
  printf '%s\n' "$out" | strip_echo | head -12
}
tryt "D1 建库(库级ttl)" "create database root.probe_tb with (ttl=3000);"
tryt "D2 建表(无ttl)" "use root.probe_tb; create table t1 (time timestamp, dev tag, v int64);"
tryt "D3 建表(ttl=3000)" "use root.probe_tb; create table t2 (time timestamp, dev tag, v int64) with (ttl=3000);"
tryt "D4 写入 t1" "use root.probe_tb; insert into t1 (time, dev, v) values($(now_ms), 'd1', 1);"
tryt "D5 写入 t2" "use root.probe_tb; insert into t2 (time, dev, v) values($(now_ms), 'd1', 1);"
tryt "D6 表属性查询" "select table_name, \"ttl(ms)\" from information_schema.tables where table_name in ('t1','t2');"
tryt "D7 ALTER SET ttl" "use root.probe_tb; alter table t1 set properties ttl=3000;"
tryt "D8 再看属性" "select table_name, \"ttl(ms)\" from information_schema.tables where table_name in ('t1','t2');"
tryt "D9 ttl=INF" "use root.probe_tb; alter table t2 set properties ttl='INF';"
tryt "D10 再看属性" "select table_name, \"ttl(ms)\" from information_schema.tables where table_name in ('t1','t2');"
tryt "D11 ttl=default" "use root.probe_tb; alter table t1 set properties ttl='default';"
tryt "D12 再看属性" "select table_name, \"ttl(ms)\" from information_schema.tables where table_name in ('t1','t2');"
tryt "D13 show tables" "use root.probe_tb; show tables;"

log "############ E) 表模型 OBJECT 语法"
tryt "E1 建表 object" "use root.probe_tb; create table tobj (time timestamp, dev tag, o object);"
tryt "E2 写 object" "use root.probe_tb; insert into tobj (time, dev, o) values($(now_ms), 'd1', to_object(true, 0, X'62'));"
tryt "E3 查询 object" "use root.probe_tb; select count(*) from tobj;"

log "=== 探针结束 ==="
cluster_stop
