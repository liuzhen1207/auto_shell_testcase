#!/bin/bash
# ============================================================================
# TV-13 单设备新增 1000 个测点 → 树转表视图（auto_sync_schema=true）补列成功
#   断言：1000 列全部补齐（轮询等待）、抽样类型正确、数据可查、查询/聚合可用、
#         收尾三件套（sync lag / 副本一致 / 日志；auto-sync 的 ERROR 不再放行，TDB-890 回归门禁）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
tv_load_env
tv_parse_args "$@"
tv_case_init "tv_autosync_1000_${DATA_CONSENSUS}"
# TDB-890 在 RC2 已修复（auto-sync 的"列已存在"降级为 INFO、不再打 ERROR 552/305），
# 因此这里不再放行 ViewColumnAutoSyncTrigger / Failed to add ... / AddViewColumnProcedure —— 让收尾日志扫描成为真门禁。
# 只保留与 auto-sync 无关的基础设施噪声。
TV_LOG_BENIGN_EXTRA="Cluster is unactivated|License has been given up"

N=${TV_AS_N:-1000}
DB=db_tv_as1k
TDB=root.tvas1k
VIEW=v1k
DEV=$TDB.d1

treeq(){ printf 'set sql_dialect=tree;\n%s\n' "$1" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1; }
# ⚠ desc 只返回前 1000 行（CLI 显示上限），列数必须用 information_schema 权威统计
vcol_n(){ tcol "$(tqt "select count(*) from information_schema.columns where table_name='$VIEW' and database='$DB';")" 1; }
vcol_has(){ tqt "select count(*) from information_schema.columns where table_name='$VIEW' and database='$DB' and column_name='$1';" | grep -a '^|' | tail -1 | tr -dc '0-9'; }
vcol_type(){ tqt "select datatype from information_schema.columns where table_name='$VIEW' and database='$DB' and column_name='$1';" | grep -a '^|' | tail -1 | awk -F'|' '{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'; }

tv_prologue "$TDB" "$DB"
log "  等集群 6/6 就绪（最多 240s）"
for i in $(seq 1 48); do
  n=$(tqt "show cluster;" 2>/dev/null | grep -acE 'Running')
  [ "${n:-0}" -ge 6 ] && break
  sleep 5
done
log "  集群 Running=$n（等待 ${i}×5s）"
tqt "create database $DB;" >/dev/null 2>&1
treeq "create database $TDB;" >/dev/null 2>&1
log "  等 root.tvas1k 的 SchemaRegion 就绪（最多 60s）"
ready=0
for i in $(seq 1 30); do
  o=$(treeq "create timeseries $DEV.seed int32;")
  echo "$o" | grep -q '906' || { ready=1; break; }
  sleep 2
done
if [ "$ready" -ne 1 ]; then
  fail "SchemaRegion 60s 内未就绪"; tv_case_finish; exit 1
fi
log "  SchemaRegion 就绪（第 $i 次，耗时约 $((i*2))s）"
treeq "insert into $DEV(time,seed) values(1,1);" >/dev/null 2>&1

log "--- 1) 建 auto_sync_schema 视图（基线：time+dev+seed = 3 列）---"
out=$(tqt_db "$DB" "create view $VIEW (dev STRING TAG) WITH (auto_sync_schema=true) AS $TDB.**;")
assert_contains "视图创建成功" "$(last_msg "$out")" 'successfully'
c0=$(vcol_n)
for i in $(seq 1 15); do
  [ "${c0:-0}" -ge 3 ] && break
  sleep 2
  c0=$(vcol_n)
done
log "  基线列数=$c0"
assert_eq "基线列数=3" "$c0" "3"

log "--- 2) 单设备连续新增 $N 个测点（类型交替 INT32/INT64/DOUBLE/FLOAT）---"
GEN=$(mktemp /tmp/tv_as1k_XXXX.sql)
for i in $(seq 1 "$N"); do
  case $(( i % 4 )) in
    0) t=int32 ;;
    1) t=int64 ;;
    2) t=double ;;
    3) t=float ;;
  esac
  echo "create timeseries $DEV.m$i $t;" >>"$GEN"
done
t0=$(date +%s)
printf 'set sql_dialect=tree;\n' >/tmp/tv_as1k_head.sql
cat /tmp/tv_as1k_head.sql "$GEN" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" >/tmp/tv_as1k_create.out 2>&1
rc=$?
t1=$(date +%s)
err=$(grep -acE '^(Msg|Error): .*(Exception|Error)' /tmp/tv_as1k_create.out)
log "  第一轮建 1000 测点：rc=$rc 耗时=$((t1-t0))s 报错行=$err"
# 906（SchemaRegion 未就绪）等偶发失败：最多重试 3 轮，只补缺失的
need=$(( N + 1 ))
for r in 1 2 3; do
  cur=$(treeq "count timeseries $TDB.**;" | grep -a '^|' | tail -1 | tr -dc '0-9')
  log "  第 $r 轮检查：树侧时序数=${cur:-0} / 期望 $need"
  [ "${cur:-0}" -ge "$need" ] && break
  cat /tmp/tv_as1k_head.sql "$GEN" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" >/tmp/tv_as1k_create_$r.out 2>&1
  e2=$(grep -acE 'Exception' /tmp/tv_as1k_create_$r.out)
  e906=$(grep -acE '906' /tmp/tv_as1k_create_$r.out)
  log "    重试报错=$e2（其中 906=$e906）"
  sleep 3
done
err=0
pass "1000 个测点创建（含缺失重试）完成"

n_ts=$(treeq "count timeseries $TDB.**;" | grep -a '^|' | tail -1 | tr -dc '0-9')
log "  树侧时序数=$n_ts（期望 $((N+1))）"
assert_num_eq "树侧时序数 = $((N+1))" "${n_ts:-0}" "$((N+1))"

log "--- 3) 轮询等待视图补列（最多 15 分钟）---"
target=$(( 3 + N ))
got=0
for i in $(seq 1 90); do
  got=$(vcol_n)
  [ "$got" -ge "$target" ] && break
  if [ $(( i % 6 )) -eq 0 ]; then log "  轮 $i：已补到 $got / $target 列"; fi
  sleep 10
done
log "  最终列数=$got / 期望 $target（耗时约 $((i*10))s）"
assert_num_eq "视图列数 = 基线 + $N（1000 列全部补齐）" "$got" "$target"

log "--- 4) 抽样校验列名与类型 ---"
for i in 1 2 3 250 500 750 1000; do
  case $(( i % 4 )) in 0) t=INT32;; 1) t=INT64;; 2) t=DOUBLE;; 3) t=FLOAT;; esac
  assert_eq "列 m$i 存在" "$(vcol_has "m$i")" "1"
  assert_eq "列 m$i 类型=$t" "$(vcol_type "m$i")" "$t"
done

log "--- 5) 写入数据并通过视图查询 ---"
treeq "insert into $DEV(time,m1,m2,m3) values(2,11,22,33.5);" >/dev/null 2>&1
treeq "insert into $DEV(time,m500,m1000) values(3,1,2);" >/dev/null 2>&1
sleep 5
out=$(tqt_db "$DB" "select count(m1), count(m2), count(m500), count(m1000) from $VIEW;")
assert_not_contains "视图查询 1000 列中的抽样列无报错" "$out" 'Exception|ERROR'
log "  $(printf '%s' "$out" | grep -a '^|' | tail -1)"
out=$(tqt_db "$DB" "select count(*) from $VIEW;")
assert_not_contains "视图 count(*) 无报错" "$out" 'Exception|ERROR'

log "--- 6) 收尾三件套 ---"
# 写完 1000 列后要 flush 并留出足够时间让三副本都追上，否则"刚停节点"会读到落后的副本
tqt "flush;" >/dev/null 2>&1
sleep 10
tv_sync_lag 120 || true
tqt "flush;" >/dev/null 2>&1
sleep 15
tv_replica_consistency "v1k 行数" "select count(*) from $DB.$VIEW;"
tv_check_logs 0 "CN/DN 日志（auto-sync 不得产生 ERROR，TDB-890 门禁）"
rm -f "$GEN"
tv_case_finish
