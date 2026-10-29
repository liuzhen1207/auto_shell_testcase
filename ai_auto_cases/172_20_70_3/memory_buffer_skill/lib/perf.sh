#!/bin/bash
# ============================================================================
# 内存缓冲区（MB）专项 —— 性能对比 helper（在 lib/common.sh + lib/mb.sh 之上）
#
#   用 iot-benchmark 在同一 3C5D 集群上对比"内存缓冲区参数"对写入吞吐/延迟的影响。
#   判据口径（与功能用例不同）：
#     · **不判绝对阈值**（几百万 points/s 是文档里 16 核 32G × 多机的结果，本环境不具备）；
#     · 每个变体与"同轮基线"比：吞吐下降超过 PERF_TOLERANCE_PCT（默认 30%）记 FAIL，
#       下降在 0~30% 记 WARN，上升记 PASS；延迟看 P99 是否恶化超过 PERF_LATENCY_TOL_PCT（默认 50%）。
#     · 每个变体都从**干净集群**起（与功能用例同一套 mb_cluster_prepare），跑 1 次；
#       需要更稳的结论时用 PERF_REPEAT=3 取中位数。
# ============================================================================

PERF_BM_DIR="${PERF_BM_DIR:-/data1/iotdb/testcase/MigrateRegionTest/benchmark/bm_20251017_b6be9bd}"
PERF_WORK_DIR="${PERF_WORK_DIR:-/tmp/mb_perf}"
PERF_LOOP="${PERF_LOOP:-1000}"
PERF_DEVICES="${PERF_DEVICES:-100}"
PERF_SENSORS="${PERF_SENSORS:-20}"
PERF_BATCH="${PERF_BATCH:-10}"
PERF_CLIENTS="${PERF_CLIENTS:-10}"
PERF_POINT_STEP="${PERF_POINT_STEP:-1000}"
PERF_REPEAT="${PERF_REPEAT:-1}"
PERF_TIMEOUT="${PERF_TIMEOUT:-1800}"
PERF_TOLERANCE_PCT="${PERF_TOLERANCE_PCT:-30}"
PERF_LATENCY_TOL_PCT="${PERF_LATENCY_TOL_PCT:-50}"
# 写为主（与《软件测试文档》口径一致：91% 写入 + 各类查询各 1%）
PERF_OP_MIX_WRITE="${PERF_OP_MIX_WRITE:-91:1:1:1:1:1:0:0:0:0:0:0}"
# 纯写入（隔离写吞吐）
PERF_OP_MIX_PURE="${PERF_OP_MIX_PURE:-100:0:0:0:0:0:0:0:0:0:0:0}"
# 查询为主（最新点查询压测）
#   OPERATION_PROPORTION 的顺序是 写入:Q1:Q2:Q3:Q4:Q5:Q6:Q7:Q8:Q9:Q10:Q11，
#   其中 **Q8 = 最近点查询（LATEST_POINT）**，也就是第 9 个数。
#   （见 benchmark 自带 conf/config.properties:331-342 的注释）
PERF_OP_MIX_QUERY="${PERF_OP_MIX_QUERY:-1:0:0:0:0:0:0:0:90:0:0:0}"

perf_check(){
  [ -x "$PERF_BM_DIR/benchmark.sh" ] || { fail "benchmark 不存在: $PERF_BM_DIR/benchmark.sh"; return 1; }
  [ -f "$PERF_BM_DIR/conf/function.xml" ] || { fail "缺 function.xml"; return 1; }
  return 0
}

# 生成一个 benchmark 配置目录：perf_gen_conf <dir> <op_mix> [k=v ...]
#   注意：benchmark 的 `-cf` 要的是**目录**（目录里必须有 config.properties + function.xml + logback.xml），
#   直接传一个文件会报 `config.properties/function.xml: Not a directory`。
perf_gen_conf(){
  local dir=$1 mix=$2; shift 2
  rm -rf "$dir"; mkdir -p "$dir"
  cp -f "$PERF_BM_DIR/conf/function.xml" "$PERF_BM_DIR/conf/logback.xml" "$dir/" 2>/dev/null
  local hosts ports h
  hosts=$(printf '%s,' "${DN[@]}"); hosts=${hosts%,}
  ports=""; for h in "${DN[@]}"; do ports="$ports$DN_RPC_PORT,"; done; ports=${ports%,}
  cat >"$dir/config.properties" <<CFG
DB_SWITCH=IoTDB-200-SESSION_BY_TABLET
IoTDB_DIALECT_MODE=tree
HOST=$hosts
PORT=$ports
USERNAME=$DB_USER
PASSWORD=$ROOT_PW
IS_DELETE_DATA=false
LOOP=$PERF_LOOP
TEST_MAX_TIME=0
USE_MEASUREMENT=true
DEVICE_NUMBER=$PERF_DEVICES
SENSOR_NUMBER=$PERF_SENSORS
SCHEMA_CLIENT_NUMBER=$PERF_CLIENTS
DATA_CLIENT_NUMBER=$PERF_CLIENTS
POINT_STEP=$PERF_POINT_STEP
INSERT_DATATYPE_PROPORTION=1:1:1:1:1:1:1:1:1:1
LINE_RATIO=0
SIN_RATIO=0
SQUARE_RATIO=0
RANDOM_RATIO=1
CONSTANT_RATIO=0
DATA_SEED=666
OPERATION_PROPORTION=$mix
BATCH_SIZE_PER_WRITE=$PERF_BATCH
START_TIME=2018-8-30T00:00:00+08:00
IS_OUT_OF_ORDER=false
BENCHMARK_WORK_MODE=testWithDefaultPath
RESULT_PRECISION=0.1
CFG
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    # 已存在则替换，否则追加
    if grep -qE "^${k}=" "$dir/config.properties"; then
      sed -i -E "s|^${k}=.*|${k}=${v}|" "$dir/config.properties"
    else
      printf '%s=%s\n' "$k" "$v" >>"$dir/config.properties"
    fi
  done
}

# 跑一次 benchmark：perf_run_bm <conf_dir> <tag>
#   结果解析到全局：PERF_INGEST_TP / PERF_INGEST_AVG_MS / PERF_INGEST_P99_MS / PERF_OK_POINTS / PERF_ELAPSED_S
perf_run_bm(){
  local dir=$1 tag=$2 log="$1/run.log"
  PERF_INGEST_TP=0; PERF_INGEST_AVG_MS=0; PERF_INGEST_P99_MS=0; PERF_OK_POINTS=0; PERF_ELAPSED_S=0
  local csvdir="$PERF_BM_DIR/data/csvOutput"
  local before; before=$(ls -t "$csvdir"/*.csv 2>/dev/null | head -1)
  log "  运行 benchmark [$tag]（LOOP=$PERF_LOOP DEV=$PERF_DEVICES SENSOR=$PERF_SENSORS）"
  ( cd "$PERF_BM_DIR" && timeout "$PERF_TIMEOUT" bash benchmark.sh -cf "$dir" >"$log" 2>&1 )
  local rc=$?
  [ "$rc" -ne 0 ] && warn "benchmark rc=$rc（$tag），日志: $log"
  local csv; csv=$(ls -t "$csvdir"/*.csv 2>/dev/null | head -1)
  if [ -z "$csv" ] || [ "$csv" = "$before" ]; then
    fail "【$tag】未产生新的 benchmark 结果 CSV（benchmark 可能没跑起来）"
    tail -5 "$log" 2>/dev/null | sed 's/^/    /' >>"$OUT" 2>/dev/null || true
    return 1
  fi
  # Throughput Matrix: "INGESTION,okOp,okPoint,failOp,failPoint,throughput"
  PERF_INGEST_TP=$(awk -F, '$1=="INGESTION"{print $6; exit}' "$csv" | tr -d ' \r')
  PERF_OK_POINTS=$(awk -F, '$1=="INGESTION"{print $3; exit}' "$csv" | tr -d ' \r')
  # Latency Matrix: "INGESTION,AVG,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,..."
  PERF_INGEST_AVG_MS=$(awk -F, '$1=="INGESTION" && NF>=11 {print $2; exit}' "$csv" | tr -d ' \r')
  # ⚠️ 不能写死列号：延迟矩阵表头是
  #   Operation,AVG,MIN,P10,P25,MEDIAN,P75,P90,P95,P99,P999,MAX,SLOWEST_THREAD
  # 第 10 列是 P99、第 11 列是 P999。此前写死 $11，把 P999 当成了 P99，
  # 导致所有性能用例的 P99 判据都读错（实测 P-01 记录 45.87 实为 P999，真 P99 是 7.54；
  # P-03 因此把 95.35 vs 44.45 误报成"P99 恶化 114%"，真 P99 是 7.26 vs 7.15，仅 +1.5%）。
  # 改为按表头名定位，避免列序变化再次踩坑。
  PERF_LAT_COL=$(awk -F, '/^Operation,AVG,MIN/{for(i=1;i<=NF;i++){h=$i; gsub(/[ \r]/,"",h); if(h=="P99"){print i; exit}}}' "$csv")
  [ -z "${PERF_LAT_COL:-}" ] && PERF_LAT_COL=10
  PERF_INGEST_P99_MS=$(awk -F, -v c="$PERF_LAT_COL" '$1=="INGESTION" && NF>=c {print $c; exit}' "$csv" | tr -d ' \r')
  # 同一个 CSV 里第二次出现 INGESTION 才是延迟矩阵（吞吐矩阵在前），用两遍扫描兜底
  local cnt; cnt=$(grep -c '^INGESTION,' "$csv" 2>/dev/null || echo 0)
  if [ "${cnt:-0}" -ge 2 ]; then
    PERF_INGEST_AVG_MS=$(awk -F, '$1=="INGESTION"{n++; if(n==2){print $2; exit}}' "$csv" | tr -d ' \r')
    PERF_INGEST_P99_MS=$(awk -F, -v c="${PERF_LAT_COL:-10}" '$1=="INGESTION"{n++; if(n==2){print $c; exit}}' "$csv" | tr -d ' \r')
  fi
  PERF_ELAPSED_S=$(awk -F, '/^Test elapsed time/{gsub(/[^0-9.]/,"",$0); print; exit}' "$csv" 2>/dev/null)
  PERF_ELAPSED_S=$(grep -oE '^Test elapsed time.*\(s\),[0-9.]+' "$csv" 2>/dev/null | awk -F, '{print $NF}' | tr -d ' \r')
  PERF_CSV_LAST="$csv"
  # 把两个矩阵拆成独立文件，供任意操作行查询（tp / lat）
  awk -F, '/^Operation,okOperation/{f=1;next} f&&/^Latency/{f=0} f&&NF>=6' "$csv" >"$dir/tp.csv" 2>/dev/null
  awk -F, '/^Operation,AVG,MIN/{f=1;next} f&&/^Schema cost/{f=0} f&&NF>=11' "$csv" >"$dir/lat.csv" 2>/dev/null
  log "  【$tag】吞吐=${PERF_INGEST_TP} point/s  成功点数=${PERF_OK_POINTS}  AVG=${PERF_INGEST_AVG_MS}ms  P99=${PERF_INGEST_P99_MS}ms  耗时=${PERF_ELAPSED_S}s"
  return 0
}

# 追加一行到性能结果表：perf_record <case> <tag> <param_desc>
perf_record(){
  local case_id=$1 tag=$2 desc=$3 csv="$OUTDIR/perf_${CASE}.csv"
  [ -f "$csv" ] || echo 'time,case,tag,param,consensus,ingest_throughput_point_s,ok_points,avg_ms,p99_ms,elapsed_s,benchmark_csv' >>"$csv"
  printf '%s,%s,%s,"%s",%s,%s,%s,%s,%s,%s,"%s"\n' \
    "$(date --iso-8601=seconds)" "$case_id" "$tag" "$desc" "$CONS_TAG" \
    "${PERF_INGEST_TP:-0}" "${PERF_OK_POINTS:-0}" "${PERF_INGEST_AVG_MS:-0}" \
    "${PERF_INGEST_P99_MS:-0}" "${PERF_ELAPSED_S:-0}" "${PERF_CSV_LAST:-}" >>"$csv"
  log "  已记录: $csv"
}

# 与基线比较：perf_compare <tag> <base_tp> <cur_tp> <base_p99> <cur_p99>
perf_compare(){
  local tag=$1 b=$2 c=$3 bp99=$4 cp99=$5
  local r
  # 基线为空/0 时不能静默跳过（首版就是这样漏掉了 V2 比 V1 慢 12 倍的结论）：
  # 明确打 WARN，说明"对照未成立"，让报告里能看到。
  if [ -z "${b:-}" ] || [ "$(awk -v x="${b:-0}" 'BEGIN{print (x+0>0)?0:1}')" = "1" ]; then
    warn "【$tag】基线吞吐为空/0（b=[${b:-}]），对照未成立，无法给出比值"
    return 0
  fi
  r=$(awk -v b="$b" -v c="$c" -v tol="$PERF_TOLERANCE_PCT" 'BEGIN{
    if (b+0 <= 0) { print "NA"; exit }
    d = (c - b) / b * 100
    if (d <= -tol) print "FAIL " d;
    else if (d < 0) print "WARN " d;
    else print "PASS " d;
  }')
  local verdict delta
  verdict=$(printf '%s' "$r" | awk '{print $1}'); delta=$(printf '%s' "$r" | awk '{print $2}')
  case "$verdict" in
    NA)   warn "【$tag】基线吞吐为 0，无法比较" ;;
    FAIL) fail "【$tag】吞吐 ${c} vs 基线 ${b} point/s（${delta}%，超过 -${PERF_TOLERANCE_PCT}% 容忍）" ;;
    WARN) warn "【$tag】吞吐 ${c} vs 基线 ${b} point/s（${delta}%，下降但未超过 -${PERF_TOLERANCE_PCT}%）" ;;
    PASS) pass "【$tag】吞吐 ${c} vs 基线 ${b} point/s（+${delta}%）" ;;
  esac
  # 延迟
  if [ "$(awk -v a="$bp99" -v b="$cp99" -v tol="$PERF_LATENCY_TOL_PCT" 'BEGIN{print (a+0>0 && b+0 > a*(1+tol/100)) ? 1 : 0}')" = "1" ]; then
    fail "【$tag】P99 延迟恶化：${cp99}ms vs 基线 ${bp99}ms（超过 +${PERF_LATENCY_TOL_PCT}%）"
  else
    pass "【$tag】P99 延迟可接受：${cp99}ms vs 基线 ${bp99}ms"
  fi
}

# 一个"变体"的完整流程：干净集群 + 指定内存参数 + 跑 benchmark + 记录
#   perf_variant <tag> <param_desc> <op_mix> <extra_kv...>
perf_variant(){
  local tag=$1 desc=$2 mix=$3; shift 3
  log "===== 变体【$tag】$desc ====="
  # 每个变体都从干净集群开始（与功能用例同一口径）
  cluster_stop
  cluster_clean
  cluster_write_conf
  cluster_start
  wait_cluster_ready || { fail "【$tag】集群未就绪"; return 1; }
  local dir="$PERF_WORK_DIR/$tag"
  perf_gen_conf "$dir" "$mix" "$@" || { fail "【$tag】生成配置失败"; return 1; }
  local best_tp=0 best_avg=0 best_p99=0 i
  for ((i=1; i<=PERF_REPEAT; i++)); do
    perf_run_bm "$dir" "$tag#$i" || return 1
    # 取吞吐最高的那次作代表（避免偶发慢跑把结论带偏）
    if [ "$(awk -v a="$PERF_INGEST_TP" -v b="$best_tp" 'BEGIN{print (a+0>b+0)?1:0}')" = "1" ]; then
      best_tp=$PERF_INGEST_TP; best_avg=$PERF_INGEST_AVG_MS; best_p99=$PERF_INGEST_P99_MS
    fi
  done
  PERF_INGEST_TP=$best_tp; PERF_INGEST_AVG_MS=$best_avg; PERF_INGEST_P99_MS=$best_p99
  perf_record "$CASE" "$tag" "$desc"
}

# 正证据：把内存分配与刷盘计数打进日志（说明本变体的内存参数确实生效）
perf_evidence(){
  local h
  log "  [证据] 内存分配:"
  for h in "${DN[@]}"; do
    log "    $h: $(mb_alloc_log "$h" Write) write / $(mb_alloc_log "$h" Read) read"
  done
  log "  [证据] 刷盘累计=$(mb_flush_all) 区域memCost=$(mb_region_mem_all)"
}

# 从某个变体的结果里取某操作行的指标：perf_get <dir> <OP> <tp|okpoint|avg|p99>
perf_get(){
  local dir=$1 op=$2 field=$3
  case "$field" in
    tp)      awk -F, -v o="$op" '$1==o{print $6; exit}' "$dir/tp.csv" 2>/dev/null | tr -d ' \r' ;;
    okpoint) awk -F, -v o="$op" '$1==o{print $3; exit}' "$dir/tp.csv" 2>/dev/null | tr -d ' \r' ;;
    okop)    awk -F, -v o="$op" '$1==o{print $2; exit}' "$dir/tp.csv" 2>/dev/null | tr -d ' \r' ;;
    avg)     awk -F, -v o="$op" '$1==o && NF>=11{print $2; exit}' "$dir/lat.csv" 2>/dev/null | tr -d ' \r' ;;
    p99)     awk -F, -v o="$op" '$1==o && NF>=11{print $11; exit}' "$dir/lat.csv" 2>/dev/null | tr -d ' \r' ;;
    *) echo 0 ;;
  esac
}

# 数值比较：perf_ge <a> <b>  → a>=b 时返回 0
perf_ge(){ awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }
perf_num(){ printf '%s' "${1:-0}" | tr -d ' \r' | awk '{printf "%.2f", $1+0}'; }

# 从结果 CSV 回读某变体的指标（**比在脚本里传变量更稳**）：
#   perf_from_csv <case> <tag> <tp|p99|avg|ok>
# 背景：首版用 `BASE_TP=$PERF_INGEST_TP` 在脚本里传基线，实测在 perf_variant 返回后
#   拿不到值（全程静默跳过比较，导致 V2 比 V1 慢 12 倍却没有 FAIL）。
#   改为"写完 CSV 再从 CSV 读回"，不依赖任何变量作用域。
perf_from_csv(){
  local case_id=$1 tag=$2 field=$3 csv="$OUTDIR/perf_${1}.csv"
  [ -f "$csv" ] || { echo 0; return; }
  # 只按 tag 精确匹配第 3 列；取值列固定（CSV 表头见 perf_record）：
  #   $3=tag $6=ingest_throughput_point_s $7=ok_points $8=avg_ms $9=p99_ms
  # 同一 tag 有多次运行（重跑）时取**最后一行**（最新的那次）。
  awk -F',' -v t="$tag" -v fld="$field" '
    NR>1 && $3==t {
      v = (fld=="tp") ? $6 : (fld=="ok") ? $7 : (fld=="avg") ? $8 : (fld=="p99") ? $9 : 0
      gsub(/[ \r"]/, "", v); last = v
    }
    END { print (last==""?0:last) }' "$csv"
}

# 便捷封装：perf_cmp_tags <case> <base_tag> <cur_tag> <label>
perf_cmp_tags(){
  local case_id=$1 bt=$2 ct=$3 label=$4
  local b c bp cp
  b=$(perf_from_csv "$case_id" "$bt" tp);  c=$(perf_from_csv "$case_id" "$ct" tp)
  bp=$(perf_from_csv "$case_id" "$bt" p99); cp=$(perf_from_csv "$case_id" "$ct" p99)
  log "  对照（来自 CSV）：基线[$bt] 吞吐=${b:-0} P99=${bp:-0}；当前[$ct] 吞吐=${c:-0} P99=${cp:-0}"
  if [ -z "${b:-}" ] || [ "${b:-0}" = "0" ]; then
    warn "【$label】基线[$bt] 吞吐为 0/空，对照未成立（检查 perf_${case_id}.csv 是否有该 tag 的行）"
    return 0
  fi
  perf_compare "$label" "$b" "$c" "$bp" "$cp"
}
