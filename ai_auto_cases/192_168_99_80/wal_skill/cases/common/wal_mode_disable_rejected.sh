#!/bin/bash
# ============================================================================
# W-02 负向门禁：IoTConsensus / IoTConsensusV2(stream) 下 `wal_mode=DISABLE` ⇒ **DN 启动失败**，
#                 启动异常文案必须含指定串；同一条 conf 写入路径下 ASYNC 必须能正常起（对照相）
#
# 【用例】W-02（集合 mode；树模型；库名 root.waldis）
#
# 【覆盖需求】
#   · docs/req_sources/design_extract.md §7.1-12（DISABLE 的边界：设计文档**未提及**"流模式下不允许 DISABLE"
#     ⇒ 本条是源码事实而不是文档需求）、§8.2 TP-12。
#   · docs/req_sources/source_grounding.md（**构造方式完全按它**）：
#       §2 校验位置 = `IoTDBStartCheck.validateFirstStart()`（iotdb-core/datanode/.../conf/IoTDBStartCheck.java:150-163），
#          经 DataNode.java:282 pullAndCheckSystemConfigurations → DataNode.java:530 checkSystemConfig() 间接调用；
#          条件 = (`IoTConsensus` 或 (`IoTConsensusV2` 且 `iot_consensus_v2_mode=stream`)) 且 wal_mode=DISABLE；
#          文案 = "Configuring the WALMode as disable is not supported under IoTConsensus and IoTConsensusV2 "
#                 + "stream mode"（DataNodeMiscMessages.java:1353-1355）。
#       §2 **关键触发条件**：`AbstractIoTDBStartCheck.checkSystemConfig()` 里只有 `isFirstStart()` 为真才走
#          `validateFirstStart()`（AbstractIoTDBStartCheck.java:83-88；isFirstStart = 该节点还没有
#          iotdb-system.properties 副本，SystemPropertiesHandler.java:140-142）⇒ **必须"清数据后首启"**；
#          已初始化节点改 DISABLE 重启不会被拒（那一半留给自己/后续用例，本用例只做首启这一支）。
#       §2 IoTConsensusV2 **默认是 batch 模式、允许 DISABLE**（IoTDBConfig.java:1178；
#          常量 ConsensusFactory.java:47-48）⇒ 跑 V2 相时必须额外写 `iot_consensus_v2_mode=stream` 才是有效负向；
#          本用例在 V2 下额外做一相"DISABLE + batch ⇒ 允许（能起）"作对照，避免把"模式分支"误判成"门禁失效"。
#       §2 RatisConsensus 是**强制** DISABLE（DataNode.java:971-974）—— 本环境不用 Ratis，此处仅备注。
#       §2 DISABLE 生效面：WALManager.applyForWALNode 返回 WALFakeNode（WALManager.java:99-105）、
#          IoTDBStartCheck.java:219-225 在 Ratis 或 DISABLE 时**不注册/不创建 WAL 目录** ⇒ "WAL 目录无文件"可作对照信号。
#
# 【判据】
#   相 1（负向，硬）：首启场景下 DN 必须起不来 + 每个 DN 的日志/启动输出必须含指定文案：
#     1) 场景有效性：写 conf 之前，各 DN 的 `$DB_DIR/data` 必须为空/不存在（否则不是首启，校验不会执行）
#        （来源：AbstractIoTDBStartCheck.java:83-88 + SystemPropertiesHandler.java:140-142）
#     2) 场景有效性：各 DN 的 properties 里 `wal_mode=DISABLE`（来源：cluster_write_conf 逐键回读 + wal_props_get）
#     3) 前置条件：CN 必须先就绪（内部端口可连），否则 DN 失败可能只是找不到 CN（本用例用 /dev/tcp 探测 CN 端口）
#     4) **该失败必须失败**：观察窗口结束后，各 DN 上不得有 DataNode 进程存活
#     5) **文案必须命中**：每个 DN 的候选证据文件里必须出现指定英文文案原文（grep -F 精确子串）
#        —— 候选来源：logs/log_datanode_all.log、log_datanode_error.log、log_datanode_wal.log、
#           log_datanode.out、本用例自捕获的 waldis_daemon_*.log / waldis_fg_*.log、$DB_DIR/nohup.out
#   相 2（V2 专有对照，软+硬）：DISABLE + `iot_consensus_v2_mode=batch` ⇒ 集群应正常起（硬：6/6），
#     且 WAL 目录不得有 .wal 文件（硬：DISABLE 不注册 WAL 目录，IoTDBStartCheck.java:219-225）；
#     写入结果只记录（WARN 级），因为 WALFakeNode 的写路径不在本用例门禁范围内。
#   相 3（对照相，硬）：ASYNC（V2 下同时 pin `iot_consensus_v2_mode=stream`，与相 1 只差 wal_mode）
#     ⇒ 集群 6/6 起来 + 写入/读数正确 + WAL 目录确有文件。没有这一相，相 1 的失败无法归因于 DISABLE。
#
# 【注意事项】
#   ⚠ 本脚本**未在集群实跑**（harness 阶段；99.80 正在跑合并长回归，禁止任何启停集群动作）。只做了 `bash -n`。
#   ⚠ 相 1 不能走 `cmp_cluster_prepare`（它的 cluster_start 会因 DN 起不来而 fail，把"预期失败"记成产品缺陷），
#     所以相 1 手工走 stop → pkill → clean（=首启）→ 写 conf → 启 CN → 启 DN → 观察。
#     写配置仍然只用 `EXTRA_CONF="..." cluster_write_conf`（单条命令的前缀环境变量），
#     并用 waldis_strip_keys 摘掉 WAL_EXTRA_DEFAULT 里的同名 wal_mode 键——否则 cluster_write_conf 的
#     逐键回读校验会拿"第一次出现的期望值"比"最后落盘的值"，产生**假 FAIL**（本项目踩过 34 个假 FAIL）。
#   ⚠ 预期异常文案在收尾日志扫描里属**预期噪声**，已用 CMP_LOG_BENIGN_EXTRA 显式排除（否则收尾三件套会自伤）。
#   ⚠ harness 侧缺口（本文件不改 lib/conf）：lib/common.sh 的 cluster_set_conf 引用 TTL 专用变量
#     TTL_CHECK_INTERVAL_MS / MAX_EXPIRED_TIME_MS / EXPIRED_DATA_RATIO，而 WAL 的 conf/env.conf 未定义它们；
#     `set -u` 下会让"写配置"这步直接终止用例 ⇒ 本文件在写配置之前给出安全默认值。
#
#   首轮实跑 watch list（最关键 5 条）：
#     ① 失败文案到底落在哪个文件：本用例按"守护启动（start-datanode.sh -d）"与"前台启动"两轮采集，
#        并把命中的原文行打进 $OUT；首跑要确认真正的落点（决定后续其它负向用例的证据口径）。
#     ② "首启"是否真的成立：`cluster_clean` 必须把 `$DB_DIR/data` 清掉（framework 的 clean_cluster.sh），
#        否则校验走 else 分支、DN 会正常起来 ⇒ 本用例会 FAIL 且信息会指出"不是首启"。
#     ③ CN 是否先就绪：/dev/tcp 探测 CN_INTERNAL_PORT（10710）；若 CN 端口口径不同需现场修正，否则整个负向相无效。
#     ④ V2 相：`iot_consensus_v2_mode=stream` 是否被正确写入并生效（相 1/相 3 都写 stream，只有 wal_mode 不同）。
#     ⑤ 收尾三件套的日志扫描是否被"预期文案"污染：本用例已加 benign，但仍要确认没有残留的
#        `ConfigurationException` 被 COMMON_ERR_PAT 抓到（抓到即要看是不是文案变了）。
#
# 用法： bash cases/common/wal_mode_disable_rejected.sh [--consensus IoTConsensus|IoTConsensusV2]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"

# ---- harness 侧防御（见头注释；不改 lib/conf）--------------------------------
: "${TTL_CHECK_INTERVAL_MS:=60000}"
: "${MAX_EXPIRED_TIME_MS:=9223372036854775807}"
: "${EXPIRED_DATA_RATIO:=0.000001}"
export TTL_CHECK_INTERVAL_MS MAX_EXPIRED_TIME_MS EXPIRED_DATA_RATIO

cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_mode_disable_rejected_${DATA_CONSENSUS}"

DB=root.waldis
DEVS=${WAL_DEVS:-6}
ROWS=${WAL_ROWS:-300}
NEG_WIN=${WAL_DISABLE_WIN_SEC:-90}
MSG='Configuring the WALMode as disable is not supported under IoTConsensus and IoTConsensusV2 stream mode'

# V2 判定：IoTConsensusV2 默认是 batch 模式、**允许** DISABLE（IoTDBConfig.java:1178），
# 只有 stream 模式才是有效负向 ⇒ 相 1/相 3 都 pin stream，保证两者只差 wal_mode。
V2=0
case "$DATA_CONSENSUS" in
  *IoTConsensusV2*) V2=1 ;;
  *) V2=0 ;;
esac
log "=== W-02 DISABLE 负向门禁：consensus=$DATA_CONSENSUS（V2=$V2）；库 $DB ==="

# ---------------------------------------------------------------------------
# 局部 helper
# ---------------------------------------------------------------------------
# 从 WAL_EXTRA_DEFAULT 里摘掉指定键（本用例要自己给 wal_mode 定值）。
#   ⚠ 必须摘：`cluster_write_conf` 是"所有节点先写完、再逐键回读校验"，把 EXTRA_CONF 里**第一次**出现的
#     期望值与文件里**最后一个**值相比 ⇒ 同名键出现两次且值不同必然**假 FAIL**（本项目踩过 34 个假 FAIL）。
waldis_strip_keys(){ local keys=" $1 " kv k out=""
  for kv in $(printf '%s' "$WAL_EXTRA_DEFAULT" | tr ',' ' '); do
    k="${kv%%=*}"
    case "$keys" in *" $k "*) continue ;; esac
    out="$out,$kv"
  done
  printf '%s' "${out#,}"; }

# DN 的 JVM pid：**必须**走 lib/wal_ext.sh 的 `wal_dn_pid`（扫 /proc/*/cmdline，只认 java 可执行
#   + cmdline 含 DataNode）。旧的 `pgrep -f com.timecho.iotdb.DataNode` 会拿到远端 `bash -c`
#   包装 shell 的 pid ⇒ 即使 DN 真的没起来也**恒非空** ⇒ "仍有 N 个 DN 存活" 的假 FAIL（W-02 实测）。
waldis_dn_pid(){ wal_dn_pid "$1"; }
# `$DB_DIR/data` 是否为空/不存在（= 首启判定的黑盒等价：没有 iotdb-system.properties 副本）
waldis_data_absent(){ local h=$1 v
  v=$(sshx "$h" "ls -A $DB_DIR/data 2>/dev/null | head -1" 2>/dev/null | tr -d '\r')
  [ -z "$v" ] && echo 1 || echo 0; }
# CN 内部端口是否可连（本用例的 CLI 需要 DN 端点，所以 CN 就绪只能用 TCP 探测；
# 依次试"节点自身地址"与 127.0.0.1，避免 bind 地址口径不同造成假 FAIL）
waldis_cn_listen(){ local h=$1 a b
  a=$(sshx "$h" "timeout 3 bash -c 'echo > /dev/tcp/$h/$CN_INTERNAL_PORT' 2>/dev/null && echo 1 || echo 0" 2>/dev/null | tr -dc '0-9')
  [ "${a:-0}" = "1" ] && { echo 1; return 0; }
  b=$(sshx "$h" "timeout 3 bash -c 'echo > /dev/tcp/127.0.0.1/$CN_INTERNAL_PORT' 2>/dev/null && echo 1 || echo 0" 2>/dev/null | tr -dc '0-9')
  echo "${b:-0}"; }
# 候选证据文件（DN 启动期文案可能落在 log4j 文件，也可能只在 JVM stdout/stderr）
waldis_files(){ printf '%s' "$DB_DIR/logs/log_datanode_all.log $DB_DIR/logs/log_datanode_error.log $DB_DIR/logs/log_datanode_wal.log $DB_DIR/logs/log_datanode.out $DB_DIR/logs/waldis_daemon_*.log $DB_DIR/logs/waldis_fg_*.log $DB_DIR/nohup.out"; }
waldis_text_cnt(){ local h=$1 v
  v=$(sshx "$h" "grep -ahF -- '$MSG' $(waldis_files) 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
waldis_text_line(){ local h=$1
  sshx "$h" "grep -ahF -m1 -- '$MSG' $(waldis_files) 2>/dev/null" 2>/dev/null | tr -d '\r' | cut -c1-240; }
# 启动 DN 并**捕获启动输出**（cluster_clean 删过 logs 目录 ⇒ 必须先 mkdir -p，否则重定向失败、
# 脚本根本不会执行，会变成"DN 没起"的假成立）
waldis_start_daemon(){ local h=$1
  sshx "$h" "mkdir -p $DB_DIR/logs && cd $DB_DIR && nohup ./sbin/start-datanode.sh -d > $DB_DIR/logs/waldis_daemon_${h##*.}.log 2>&1 </dev/null &" || warn "  相 1：$h 的启动命令返回非 0（只记录）"; }
waldis_start_fg(){ local h=$1
  sshx "$h" "mkdir -p $DB_DIR/logs && cd $DB_DIR && nohup ./sbin/start-datanode.sh > $DB_DIR/logs/waldis_fg_${h##*.}.log 2>&1 </dev/null &" || warn "  相 1：$h 的前台启动命令返回非 0（只记录）"; }
waldis_kill_stale(){ local h=$1
  sshx "$h" "pkill -f 'com\.timecho\.iotdb\.DataNode' >/dev/null 2>&1 || true" || true; }
# 一轮观察：起 DN（由调用方先起）→ 等文案齐 / 窗口到；回传 OBS_HIT / OBS_TRANSIENT
waldis_wait_neg(){ local win=$1 hit=0 up=0 h
  local dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    hit=0; up=0
    for h in "${DN[@]}"; do
      [ "$(waldis_text_cnt "$h")" -gt 0 ] && hit=$(( hit + 1 ))
      [ -n "$(waldis_dn_pid "$h")" ] && up=$(( up + 1 ))
    done
    log "    负向观察：命中文案 $hit/${#DN[@]}；当前有 DN 进程 $up/${#DN[@]}（进程态只作过程证据）"
    [ "$hit" -ge "${#DN[@]}" ] && break
    sleep 5
  done
  OBS_HIT=$hit; return 0; }

# ===========================================================================
# 三相的 EXTRA_CONF（都用"摘掉 wal_mode 的基础串 + 本相显式值"构造；见 waldis_strip_keys 注释）
# ===========================================================================
NEG_EXTRA="$(waldis_strip_keys 'wal_mode'),wal_mode=DISABLE"
BATCH_EXTRA="$(waldis_strip_keys 'wal_mode'),wal_mode=DISABLE,iot_consensus_v2_mode=batch"
CTL_EXTRA="$(waldis_strip_keys 'wal_mode'),wal_mode=ASYNC,$CMP_EXTRA_WRITE"
[ "$V2" = "1" ] && { NEG_EXTRA="$NEG_EXTRA,iot_consensus_v2_mode=stream"; CTL_EXTRA="$CTL_EXTRA,iot_consensus_v2_mode=stream"; }
log "  相 1 EXTRA_CONF=$NEG_EXTRA"
[ "$V2" = "1" ] && log "  相 2 EXTRA_CONF=$BATCH_EXTRA"
log "  相 3 EXTRA_CONF=$CTL_EXTRA"

# ===========================================================================
# 相 1：负向（DISABLE + 首启 ⇒ 必须起不来 + 必须命中指定文案）
# ===========================================================================
log "==================== 相 1：首启 + wal_mode=DISABLE（期望 DN 启动失败） ===================="
cluster_stop
for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do waldis_kill_stale "$h"; done
sleep 3
log '--- 1.1) 清数据 + 还原 conf（这一步同时构造「首启」场景）---'
cluster_clean

log "--- 1.2) 场景有效性：各 DN 的 \$DB_DIR/data 必须为空/不存在（= 首启）---"
for h in "${DN[@]}"; do
  da=$(waldis_data_absent "$h")
  [ "$da" = "1" ] && pass "首启场景成立：$h 的 $DB_DIR/data 为空/不存在（来源：AbstractIoTDBStartCheck.java:83-88）" \
    || fail "场景无效：$h 的 $DB_DIR/data 仍非空 ⇒ 不是首启，DISABLE 校验不会执行（来源：SystemPropertiesHandler.java:140-142）"
done

log "--- 1.3) 写配置：EXTRA_CONF = $NEG_EXTRA ---"
EXTRA_CONF="$NEG_EXTRA" cluster_write_conf
for h in "${DN[@]}"; do
  pv=$(wal_props_get "$h" wal_mode)
  assert_eq "配置落盘核对 $h（来源：$DB_DIR/conf/iotdb-system.properties）" "${pv:-<无>}" "DISABLE"
done

log "--- 1.4) 先起 CN 并等内部端口就绪（否则 DN 失败可能只是找不到 CN）---"
for h in "${CN[@]}"; do
  sshx "$h" "mkdir -p $CN_DB_DIR/logs && cd $CN_DB_DIR && nohup ./sbin/start-confignode.sh -d >/dev/null 2>&1 </dev/null &" || warn "启动 CN $h 的返回非 0"
done
cn_ok=0
for i in $(seq 1 60); do
  cn_ok=1
  for h in "${CN[@]}"; do [ "$(waldis_cn_listen "$h")" = "1" ] || cn_ok=0; done
  [ "$cn_ok" = "1" ] && break
  sleep 5
done
[ "$cn_ok" = "1" ] && pass "CN 已就绪：各 CN 的 $CN_INTERNAL_PORT 可连（来源：/dev/tcp 探测）" \
  || fail "场景无效：CN 内部端口未就绪 ⇒ 无法把 DN 的失败归因于 DISABLE（来源：/dev/tcp 探测 $CN_INTERNAL_PORT）"

log "--- 1.5) 起 DN（第一轮：守护方式，并捕获脚本输出）---"
for h in "${DN[@]}"; do waldis_kill_stale "$h"; done
sleep 2
for h in "${DN[@]}"; do waldis_start_daemon "$h"; done
OBS_HIT=0
waldis_wait_neg "$NEG_WIN"
if [ "${OBS_HIT:-0}" -lt "${#DN[@]}" ]; then
  log "  第一轮文案未齐（$OBS_HIT/${#DN[@]}）⇒ 第二轮：前台方式启动，捕获 JVM stdout/stderr 后再观察一次"
  for h in "${DN[@]}"; do waldis_kill_stale "$h"; done
  sleep 2
  for h in "${DN[@]}"; do waldis_start_fg "$h"; done
  waldis_wait_neg "$NEG_WIN"
fi

log "--- 1.6) 断言：该失败必须失败 + 文案必须命中 ---"
for h in "${DN[@]}"; do
  n=$(waldis_text_cnt "$h")
  line=$(waldis_text_line "$h")
  log "  $h 文案命中=$n（候选文件：$(waldis_files)）；首个命中行：${line:-<无>}"
  [ "${n:-0}" -ge 1 ] && pass "负向文案命中 @ $h（来源：DataNodeMiscMessages.java:1353-1355；文件见上）" \
    || fail "负向文案未在 $h 的任何候选文件里出现（期望原文：$MSG）"
done
sleep 10
dn_alive=0
for h in "${DN[@]}"; do
  p=$(waldis_dn_pid "$h")
  st=$(dn_state "$h")
  log "  $h DN 进程=${p:-<无>}；show cluster 状态='${st:-<CLI 不可用或未注册>}'"
  [ -n "$p" ] && dn_alive=$(( dn_alive + 1 ))
done
[ "${dn_alive:-0}" -eq 0 ] && pass "负向门禁成立：DISABLE 下没有任何 DN 存活（来源：wal_dn_pid 扫 /proc/*/cmdline，只认 java + DataNode）" \
  || fail "负向门禁失效：DISABLE 下仍有 ${dn_alive} 个 DN 进程存活（期望：DN 启动失败）"
for h in "${DN[@]}"; do
  log "  $h 启动输出尾部（来源：$DB_DIR/logs/waldis_daemon_${h##*.}.log）：$(sshx "$h" "tail -5 $DB_DIR/logs/waldis_daemon_${h##*.}.log 2>/dev/null" 2>/dev/null | tr '\n' ' ' | cut -c1-240)"
done

# ===========================================================================
# 相 2：V2 专有对照（DISABLE + batch ⇒ 允许；证明门禁是"模式条件"而不是"无条件"）
# ===========================================================================
if [ "$V2" = "1" ]; then
  log "==================== 相 2（V2 对照）：wal_mode=DISABLE + iot_consensus_v2_mode=batch（期望能起） ===================="
  EXTRA_CONF="$BATCH_EXTRA" cmp_cluster_prepare
  n=$(cmp_running_cnt)
  log "  show cluster 里 Running/ReadOnly 行数=$n（来源：CLI 'show cluster'）"
  [ "${n:-0}" -ge $(( ${#CN[@]} + ${#DN[@]} )) ] && pass "相 2：DISABLE+batch 下集群正常就绪 $n/$(( ${#CN[@]} + ${#DN[@]} ))（源码：IoTDBConfig.java:1178 默认 batch ⇒ 允许 DISABLE）" \
    || fail "相 2：DISABLE+batch 下集群未就绪（$n/$(( ${#CN[@]} + ${#DN[@]} ))）"
  wf=$(wal_sum_over_dn wal_file_cnt)
  log "  相 2 WAL 面：files=$wf（来源：<dn_wal_dirs>/**/*.wal）"
  [ "${wf:-0}" -eq 0 ] && pass "相 2：DISABLE 下 WAL 目录无 .wal 文件（来源：IoTDBStartCheck.java:219-225 不注册 WAL 目录）" \
    || fail "相 2：DISABLE 下仍出现 ${wf} 个 .wal 文件（与「不注册 WAL 目录」的源码事实不符）"
  cmp_make_tree_db "$DB" 1
  out=$(sq "insert into $DB.d1(time,s1) values($(now_ms),1);" 2>&1 | tr '\n' ' ')
  log "  相 2 写入返回（DISABLE 下 WALFakeNode 路径，仅记录，不作门禁）：$(printf '%s' "$out" | cut -c1-200)"
  cnt=$(row_sum "$(sq "select count(s1) from $DB.d1;")")
  cnt=${cnt:-0}
  [ "$cnt" -ge 1 ] && pass "相 2：DISABLE 下写入可查（count=$cnt）" \
    || warn "相 2：DISABLE 下写入后查不到数据（count=$cnt；WALFakeNode 写路径不在本用例门禁范围内，只记录）"
else
  log "相 2 跳过：当前共识为 $DATA_CONSENSUS（batch 允许 DISABLE 的分支只对 IoTConsensusV2 有意义）"
fi

# ===========================================================================
# 相 3：对照相（ASYNC ⇒ 必须能正常起 + 能写能查 + WAL 目录确有文件）
# ===========================================================================
log "==================== 相 3（对照）：wal_mode=ASYNC（期望正常起） ===================="
EXTRA_CONF="$CTL_EXTRA" cmp_cluster_prepare
for h in "${DN[@]}"; do
  pv=$(wal_props_get "$h" wal_mode)
  assert_eq "对照相配置落盘核对 $h（来源：$DB_DIR/conf/iotdb-system.properties）" "${pv:-<无>}" "ASYNC"
done
n=$(cmp_running_cnt)
[ "${n:-0}" -ge $(( ${#CN[@]} + ${#DN[@]} )) ] && pass "对照相：ASYNC 下集群正常就绪 $n/$(( ${#CN[@]} + ${#DN[@]} ))（与相 1 只差 wal_mode）" \
  || fail "对照相不成立：ASYNC 下集群未就绪（$n/$(( ${#CN[@]} + ${#DN[@]} ))）"

cmp_make_tree_db "$DB" "$DEVS"
cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" 1 || fail "对照相：写入失败（场景无效）"
got=$(row_sum "$(sq "select count(s1) from $DB.**;")")
assert_eq "对照相写入行数（来源：CLI count($DB.**)）" "${got:-0}" "$(( DEVS * ROWS ))"
wf=$(wal_sum_over_dn wal_file_cnt)
log "  对照相 WAL 面：files=$wf bytes=$(wal_sum_over_dn wal_dir_bytes)B 逐副本=$(wal_per_node)（来源：<dn_wal_dirs>/**/*.wal）"
[ "${wf:-0}" -ge 1 ] && pass "对照相：ASYNC 下 WAL 目录确有 ${wf} 个 .wal（与相 2 的 DISABLE=0 形成对照）" \
  || fail "对照相：ASYNC 下 WAL 文件数=0（场景无效）"
wal_metrics_dump "${DN[0]}"

# ===========================================================================
# 收尾三件套（预期文案与停/重启噪声显式列为 benign）
# ===========================================================================
log "--- 收尾三件套 ---"
wal_install_err_pat
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
export CMP_LOG_BENIGN_EXTRA="Configuring the WALMode as disable is not supported under IoTConsensus and IoTConsensusV2 stream mode|Execute FragmentInstance in ConsensusGroup|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader"
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
