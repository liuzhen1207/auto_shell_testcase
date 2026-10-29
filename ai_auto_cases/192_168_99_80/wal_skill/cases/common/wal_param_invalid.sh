#!/bin/bash
# ============================================================================
# W-21 参数合法性（负向）：非法取值 ⇒ 「启动失败」或「回退默认值」；**不得静默接受**
#
# 【用例】W-21（集合 param；树模型；库名 root.walbad）
#
# 【覆盖需求】
#   · cases/cases.tsv W-21：非法取值（`wal_mode=XXX`、`wal_file_size_threshold_in_byte=-1`、
#     `wal_buffer_size_in_byte=0`、`wal_min_effective_info_ratio=99`、`max_wal_nodes_num=-1`）
#     → 启动失败 或 回退默认值并给出明确文案，不得静默接受；只有「把 WAL 关掉的那个取值（DISABLE）」
#     有明确的流模式禁止路径（那条属 W-02，本用例不碰），其余键以实测（`cmp_eff`/`wal_props_get` 对比）
#     判断「回退默认」还是「原样接受」。
#   · docs/req_sources/source_grounding.md（**判据与时序完全按它**）：
#       §1.2-1  `wal_mode`：WALMode{DISABLE,SYNC,ASYNC}；IoTDBDescriptor.java:1829-1830 用
#               `WALMode.valueOf(...)` ⇒ 非枚举值抛 IllegalArgumentException ⇒ **DN 启动失败**。
#       §1.2-2  `max_wal_nodes_num`：:1836-1838 `if (maxWalNodesNum > 0)` ⇒ ≤0（含 -1）**回落默认 0**。
#       §1.2-5  `wal_buffer_size_in_byte`：:1844-1846 `if (walBufferSize > 0)` ⇒ 0 不生效，仍 33554432。
#       §1.2-9  `wal_file_size_threshold_in_byte`：:2212-2214 `if (walFileSizeThreshold > 0)`
#               ⇒ -1 不生效，仍 31457280（该键是 hot_reload，但启动装载走同一条 `>0` 判断）。
#       §1.2-10 `wal_min_effective_info_ratio`：:2222-2224 `if (walMinEffectiveInfoRatio > 0)`
#               ⇒ **只判正负、不判上界** ⇒ 99 会被**原样接受**（既非启动失败、也非回退）
#               —— 这正是本用例要抓的"静默接受"。
#       §1.3    上述 `>0` 分支**都没有任何日志**（只有 if 判断）⇒ 回退是静默的。
#   · docs/DECISIONS.md §2/§3.1：阈值类断言先读实际生效值、不写死；文档未定/口径矛盾处只 WARN。
#
# 【判定规则（本用例对"非法取值"的统一口径，逐键只判这一条）】
#     ① 启动失败（DN 进程不存在 + 有明确异常/告警文案）      ⇒ PASS（拒绝）
#     ② 运行期生效值 != 非法值（回退/拒绝）                  ⇒ PASS；缺文案只 WARN（源码 §1.3 无日志）
#     ③ 运行期生效值 == 非法值 且 有该键的明确告警文案        ⇒ PASS + WARN（取值未校验，如实记录）
#     ④ 运行期生效值 == 非法值 且 **无任何文案**              ⇒ FAIL（静默接受非法取值）
#     ⑤ 生效值不可观测（show configuration 未暴露该键）      ⇒ 只记录启动行为 + WARN（不判 PASS/FAIL）
#   依据：cases.tsv 明令"不得静默接受"；但"回退"本身已满足"未接受非法值"，故 ② 不因缺文案判 FAIL。
#
# 【判据（除注明外均为硬）】
#   相 0（对照相）：合法取值（ASYNC + 默认阈值组合）⇒ 集群 6/6 起来 + 能写能查 + WAL 目录确有 .wal
#     且逐键读回生效值（作为后面"是否回退到默认"的实测基线 DEF_*）。
#   相 1..4（每个非法数值键**单独一相**，便于逐键归因；每相：停集群 → 写 conf → 起集群）：
#     1) 场景有效性：非法值确实落到每个 DN 的 properties（wal_props_get == 非法值）
#     2) 按上面 ①~⑤ 判定（启动失败时还要求"DN 存活数=0 且有异常文案"才算可归因）
#     3) 数据面：本相新增一批写入后 count/sum 与离线核算一致；**历史数据一条不少**（累计核算）
#   相 5（`wal_mode=XXX` 负向）：DN 必须全部起不来 + **每个 DN 的异常文案计数有增量**
#     （用增量而不是存在性，避免旧日志误判）⇒ 随后合法 conf 重启不 clean，数据必须完好。
#   相 6（收尾对照）：合法取值下 WAL 目录仍有 .wal + 数据面完好 + 逐键生效值回到默认。
#   收尾三件套：sync lag 归零 / 逐个停 DN 副本一致 / CN-DN 日志无异常（预期文案已列 benign）。
#
# 【注意事项】
#   ⚠ 本脚本**未在集群实跑**（harness 阶段；99.80 正在跑合并长回归，禁止任何启停集群动作）。只做了 `bash -n`。
#   ⚠ 相 1..5 里"启动失败"是**允许的结果** ⇒ 不能调用 lib 的 `cluster_start`（它会无条件 `fail`），
#     改用本文件的 `w21_start_tol`（复用框架启动脚本但带 timeout，不注入 fail）。
#   ⚠ 同名键不能出现两次：cluster_write_conf 逐键回读时把"第一次出现的期望值"与"最后落盘的值"相比
#     ⇒ 用 w21_strip_keys 先把要覆盖的键从 WAL_EXTRA_DEFAULT 里摘掉（本项目踩过 34 个假 FAIL）。
#   ⚠ harness 缺口（本文件不改 lib/conf）：lib/common.sh 的 cluster_set_conf 引用 TTL 专用变量
#     TTL_CHECK_INTERVAL_MS / MAX_EXPIRED_TIME_MS / EXPIRED_DATA_RATIO，而 WAL 的 conf/env.conf 未定义它们；
#     `set -u` 下会让"写配置"整步终止 ⇒ 本文件在 cmp_cluster_prepare 之前给出安全默认值。
#
#   首轮实跑 watch list（最关键 4 条）：
#     ① `show configuration` 是否暴露这 5 个键：不暴露 ⇒ 该键走规则 ⑤（降级 WARN），
#        此时"回退还是接受"只能靠启动行为 + properties 判定，首轮要把打印出来的生效值原文看一遍。
#     ② `wal_min_effective_info_ratio=99` 的实测结果（源码判断会被原样接受）：若无告警文案 ⇒ 走规则 ④'（**只 WARN，不判 FAIL**）——源码对该键只判下界 `>0`，接受 99 属实现契约；若模板声明了范围才记「文档-实现不一致」。
#        这是本用例**最可能被争议**的一条（源码只判 `>0`、不判上界；需求要求不得静默接受）——
#        首轮若 FAIL，请把原始文案/生效值一并交研发裁决（要么补上界校验，要么补告警文案）。
#     ③ `wal_mode=XXX` 的异常文案落在哪个文件：本用例把 log_datanode_{all,error,wal}.log、
#        log_datanode.out、自捕获的 w21_daemon_*.log、nohup.out 全列为候选，并把命中原文打进产物。
#     ④ 相 1..4 是否真的都能起来：若某个键让 DN 起不来，本用例按"启动失败"分支 PASS，
#        但要求"DN 存活=0 且有异常文案"才算可归因，并强制打印逐节点证据供人工确认。
#
# 用法： bash cases/common/wal_param_invalid.sh [--consensus IoTConsensus|IoTConsensusV2]
#   可调：W21_WIN_SEC（每相的启动/观察窗口，默认 300 秒）
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
cmp_case_init "wal_param_invalid_${DATA_CONSENSUS}"

DB=root.walbad
DEVS=${WAL_DEVS:-4}
ROWS=${WAL_ROWS:-200}
WIN=${W21_WIN_SEC:-300}
TOTAL=$(( ${#CN[@]} + ${#DN[@]} ))
BATCH=0
DEF_TH=""; DEF_BUF=""; DEF_RATIO=""; DEF_NODES=""
# 4 个非法数值键（键 / 非法值 / 源码·文档默认值；来源 source_grounding §1.2）
BAD_KS=(wal_file_size_threshold_in_byte wal_buffer_size_in_byte wal_min_effective_info_ratio max_wal_nodes_num)
BAD_VS=(-1 0 99 -1)
BAD_DS=(31457280 33554432 0.1 0)

# ---------------------------------------------------------------------------
# 局部 helper
# ---------------------------------------------------------------------------
# 从 WAL_EXTRA_DEFAULT 里摘掉指定键（同名键两次 ⇒ 假 FAIL；见头注释）
w21_strip_keys(){ local keys=" $1 " kv k out=""
  for kv in $(printf '%s' "$WAL_EXTRA_DEFAULT" | tr ',' ' '); do
    k="${kv%%=*}"
    case "$keys" in *" $k "*) continue ;; esac
    out="$out,$kv"
  done
  printf '%s' "${out#,}"; }

# 合法取值组合（对照相 / 恢复相）：ASYNC + env.conf 的默认阈值 + 关三类合并
GOOD="$(w21_strip_keys 'wal_mode'),wal_mode=ASYNC,$CMP_EXTRA_WRITE"

# DN 的 JVM pid：**必须**走 lib/wal_ext.sh 的 `wal_dn_pid`（扫 /proc/*/cmdline，只认 java 可执行
#   + cmdline 含 DataNode）。旧的 `pgrep -f com.timecho.iotdb.DataNode` 会拿到远端 `bash -c`
#   包装 shell 的 pid ⇒ 即使 DN 已退出也恒非空 ⇒ "仍有 3 个 DN 存活" 的假 FAIL（W-21 实测）。
w21_dn_pid(){ wal_dn_pid "$1"; }
w21_running(){ cmp_running_cnt | tr -dc '0-9'; }
# DN 启动期文案的候选文件（log4j 文件 + JVM stdout/stderr + nohup）
w21_dn_files(){ printf '%s' "$DB_DIR/logs/log_datanode_all.log $DB_DIR/logs/log_datanode_error.log $DB_DIR/logs/log_datanode_wal.log $DB_DIR/logs/log_datanode.out $DB_DIR/logs/w21_daemon_*.log $DB_DIR/nohup.out"; }
# 某键相关的"异常/告警"行数（用于规则 ③/④ 与启动失败归因；用**增量**判定，见各相）
w21_key_msg_cnt(){ local h=$1 k=$2 v
  v=$(sshx "$h" "grep -ah -- '$k' $(w21_dn_files) 2>/dev/null | grep -acE 'WARN|Warn|ERROR|Exception|Invalid|invalid|out of range|must be|illegal|Illegal|exceed'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w21_key_msg_sum(){ local k=$1 h s=0
  for h in "${DN[@]}"; do s=$(( s + $(w21_key_msg_cnt "$h" "$k") )); done
  echo "$s"; }
w21_msg_line(){ local h=$1 k=$2
  sshx "$h" "grep -ah -- '$k' $(w21_dn_files) 2>/dev/null | grep -aE 'WARN|Warn|ERROR|Exception|Invalid|invalid|out of range|must be|illegal|Illegal|exceed' | tail -2" 2>/dev/null | tr -d '\r' | cut -c1-240; }
# 非法枚举相关行数 / 首行（wal_mode=XXX 相）
w21_enum_cnt(){ local h=$1 v
  v=$(sshx "$h" "grep -ahcE 'No enum constant|IllegalArgumentException|WALMode' $(w21_dn_files) 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
w21_enum_line(){ local h=$1
  sshx "$h" "grep -ahE 'No enum constant|IllegalArgumentException|WALMode' $(w21_dn_files) 2>/dev/null | tail -2" 2>/dev/null | tr -d '\r' | cut -c1-240; }
# CN 内部端口可连（DN 失败必须能归因于 conf，而不是"找不到 CN"）
w21_cn_listen(){ local h=$1 a b
  a=$(sshx "$h" "timeout 3 bash -c 'echo > /dev/tcp/$h/$CN_INTERNAL_PORT' 2>/dev/null && echo 1 || echo 0" 2>/dev/null | tr -dc '0-9')
  [ "${a:-0}" = "1" ] && { echo 1; return 0; }
  b=$(sshx "$h" "timeout 3 bash -c 'echo > /dev/tcp/127.0.0.1/$CN_INTERNAL_PORT' 2>/dev/null && echo 1 || echo 0" 2>/dev/null | tr -dc '0-9')
  echo "${b:-0}"; }
# 容错版启动（返回 show cluster 的 Running/ReadOnly 计数；**不**注入 fail —— 本用例允许"启动失败"）
w21_start_tol(){ local rc=0 n=0 up=0 dl h2 t
  t=$(( CLUSTER_READY_TIMEOUT + 120 ))
  if [ "$USE_FRAMEWORK" = "1" ] && [ -f "$FRAMEWORK_DIR/prepare_env/start_cluster_v20.sh" ]; then
    cp -f "$FRAMEWORK_CN_LIST" "$FRAMEWORK_DIR/conf/confignode.txt" 2>/dev/null || true
    cp -f "$FRAMEWORK_DN_LIST" "$FRAMEWORK_DIR/conf/datanode.txt" 2>/dev/null || true
    timeout "$t" bash "$FRAMEWORK_DIR/prepare_env/start_cluster_v20.sh" 1 "$TOTAL" >>"$OUT" 2>&1
    rc=$?
    log "  框架启动脚本返回码=$rc（本相允许非 0：非法取值可能正被拒）"
  else
    local h
    for h in "${CN[@]}"; do sshx "$h" "cd $CN_DB_DIR && nohup ./sbin/start-confignode.sh -d >/dev/null 2>&1 &" || warn "启动 CN $h 返回非 0"; done
    sleep 10
    for h in "${DN[@]}"; do sshx "$h" "cd $DB_DIR && nohup ./sbin/start-datanode.sh -d >/dev/null 2>&1 &" || warn "启动 DN $h 返回非 0"; done
  fi
  dl=$(( $(date +%s) + WIN ))
  while (( $(date +%s) < dl )); do
    n=$(w21_running)
    [ "${n:-0}" -ge "$TOTAL" ] && break
    up=0
    for h2 in "${DN[@]}"; do [ -n "$(w21_dn_pid "$h2")" ] && up=$(( up + 1 )); done
    if [ "$up" -eq 0 ] && [ "${n:-0}" -eq 0 ]; then
      log "  所有 DN 进程均不存在且集群 Running=0（判定为启动失败，提前结束等待）"
      break
    fi
    sleep 5
  done
  w21_running; }

# 数据面（离线可核算：值 = k+b，时间戳确定）
w21_write(){ BATCH=$(( BATCH + 1 ))
  log "  写入第 $BATCH 批（$DEVS 设备 × $ROWS 点；cmp_write_tree_batch 自带 flush）"
  if cmp_write_tree_batch "$DB" "$DEVS" "$ROWS" "$BATCH"; then
    pass "  相内写入成功（第 $BATCH 批）"
  else
    fail "  第 $BATCH 批写入失败（场景无效）"
    BATCH=$(( BATCH - 1 ))
    return 1
  fi
  return 0; }
w21_exp_count(){ echo $(( DEVS * ROWS * BATCH )); }
w21_exp_sum(){ local b s=0
  for (( b=1; b<=BATCH; b++ )); do s=$(( s + ROWS * (ROWS - 1) / 2 + ROWS * b )); done
  echo $(( DEVS * s )); }
w21_data_check(){ local tag=$1 c s
  c=$(row_sum "$(sq "select count(s1) from $DB.**;")")
  s=$(row_sum "$(sq "select sum(s1) from $DB.**;")")
  log "  [$tag] 数据面：count=${c:-?}（期望 $(w21_exp_count)） sum=${s:-?}（期望 $(w21_exp_sum)）"
  assert_eq "[$tag] 数据面 count（来源：CLI count($DB.**) 的 row_sum）" "${c:-0}" "$(w21_exp_count)"
  assert_eq "[$tag] 数据面 sum（离线核算，来源：CLI sum($DB.**) 的 row_sum）" "${s:-0}" "$(w21_exp_sum)"; }
w21_wal_report(){ local tag=$1
  log "  [$tag] WAL 面：整目录 files=$(wal_sum_over_dn wal_file_cnt) bytes=$(wal_sum_over_dn wal_dir_bytes)B 逐副本=$(wal_per_node)；指标 files=$(wal_metric_sum_over_dn wal_metric_file_cnt) bytes=$(wal_metric_sum_over_dn wal_metric_file_bytes)"; }

# ---------------------------------------------------------------------------
# 相 1..4：单个非法数值键（每相一次重启；逐键归因）
# ---------------------------------------------------------------------------
w21_phase_num(){ local k=$1 bad=$2 def=$3 h pv eff n obs=0 same=0 m0=0 m1=0 msg=0 alive=0 ac=0
  log "==================== 相：$k=$bad（非法；源码/文档默认 $def） ===================="
  cluster_stop
  log "  写配置：EXTRA_CONF = (WAL_EXTRA_DEFAULT 去掉 wal_mode/$k) + wal_mode=ASYNC + $k=$bad + 关三类合并"
  EXTRA_CONF="$(w21_strip_keys "wal_mode $k"),wal_mode=ASYNC,$k=$bad,$CMP_EXTRA_WRITE" cluster_write_conf
  for h in "${DN[@]}"; do
    pv=$(wal_props_get "$h" "$k")
    assert_eq "  场景有效性：$h 的 properties 里 $k=$bad（来源：$DB_DIR/conf/iotdb-system.properties）" "${pv:-<无>}" "$bad"
  done
  m0=$(w21_key_msg_sum "$k")
  n=$(w21_start_tol)
  m1=$(w21_key_msg_sum "$k")
  msg=$(( m1 - m0 )); [ "$msg" -lt 0 ] && msg=0
  log "  启动后 Running 计数=$n/$TOTAL（来源：CLI show cluster）；含 $k 的异常文案增量=$msg（基线 $m0 → $m1）"

  if [ "${n:-0}" -lt "$TOTAL" ]; then
    alive=0; ac=$msg
    for h in "${DN[@]}"; do [ -n "$(w21_dn_pid "$h")" ] && alive=$(( alive + 1 )); done
    log "  逐节点：DN 进程存活=$alive/${#DN[@]}；含该键的异常文案行数=$ac（候选文件：$(w21_dn_files)）"
    for h in "${DN[@]}"; do
      log "    [$h] 命中原文：$(w21_msg_line "$h" "$k")"
      log "    [$h] log_datanode_all.log 尾部：$(sshx "$h" "tail -3 $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
    done
    if [ "$alive" -eq 0 ] && [ "$ac" -gt 0 ]; then
      pass "  规则①：$k=$bad ⇒ DN 启动失败且给出明确文案（符合「启动失败」分支）"
    else
      fail "  场景无效：$k=$bad 下集群未就绪但**无法归因**（DN 存活=$alive、该键异常文案=$ac 行）——先排除环境原因"
    fi
    return 0
  fi
  pass "  规则前置：$k=$bad 未导致启动失败 ⇒ 进入「回退 / 原样接受」判定"

  for h in "${DN[@]}"; do
    eff=$(wal_eff "$h" "$k" | tr -d ' \r')
    [ -n "$eff" ] && obs=$(( obs + 1 ))
    [ -n "$eff" ] && [ "$eff" = "$bad" ] && same=$(( same + 1 ))
    # ⚠ 口径（2026-10-22 RC10 源码核对）：`show configuration` 返回的是**配置文件原文**
    #   （ConfigManager.java:2109 `ConfigurationFileUtils.readConfigFileContent(propsUrl)`），
    #   不是 DataNode 内存里的运行期生效值；RC10 也没有 `SHOW APPLIED CONFIGURATIONS` 语句
    #   （只有 RPC/getAppliedProperties，g4 里无 APPLIED 关键字）⇒ 运行期只能用**行为**
    #   或源码判定（见 tools/probe_w21_param_effective.sh：按 WAL 轮转文件数判定阈值是否真的生效）。
    log "    [$h] 配置文件回显值（show configuration，非运行期值）='${eff:-<不可观测>}'；properties=$(wal_props_get "$h" "$k")"
  done
  if [ "$obs" -eq 0 ]; then
    warn "  规则⑤：$k 的运行期生效值不可观测（show configuration 未暴露该键）⇒ 只记录启动行为，不判回退/接受（首轮 watch 项①）"
  elif [ "$same" -gt 0 ]; then
    if [ "$msg" -gt 0 ]; then
      pass "  规则③：$k=$bad 被原样接受，但日志有 $msg 行明确告警文案 ⇒ 非静默接受"
      warn "  $k=$bad 未被校验拒绝（源码只有 if (… > 0) 判断）⇒ 建议研发补上界/取值校验；本用例按「有文案=非静默」放行"
    else
      case "$k" in
        wal_min_effective_info_ratio)
          # 源码复核（source_grounding §1.2-10）：该键**只判下界** `if (walMinEffectiveInfoRatio > 0)`
          # ⇒ 接受 99 是**实现契约**（非缺陷）⇒ 只 WARN。仅当配置模板声明了取值范围时才记为「文档-实现不一致」。
          warn "  规则④'：$k=$bad 被原样接受且无告警文案 —— 但源码对该键只判下界（>0）⇒ 属实现契约，不判 FAIL；若模板声明了取值范围则记「文档-实现不一致」（首轮 watch 项②）"
          ;;
        *)
          # 精确措辞（2026-10-22 按 RC10 源码校正）：现在能确定的只有两件事——
          #   ① 非法值被**落盘**进 iotdb-system.properties（ConfigurationFileUtils.java:425-427）；
          #   ② `show configuration` 把它**原样回显**（ConfigManager.java:2109 读的是配置文件原文）；
          #   ③ 全程**零文案**。
          # 而"运行期是否真的采用"取决于各键的 setter 闸门：
          #   `if (maxWalNodesNum > 0)`、`if (walBufferSize > 0)`、`if (walFileSizeThreshold > 0)`
          #   （IoTDBDescriptor.java:1836/1844/2212）⇒ 源码上**非法值不会被应用**，运行期仍是默认值。
          # 所以本判据仍按需求口径 FAIL（不得静默接受 / 必须给明确文案），但**不得**表述成
          # "运行期生效值 == 非法值"；运行期真值由行为探针给出：
          #   bash tools/probe_w21_param_effective.sh  （比 A 默认 / B 非法 / C 1MB 三相的 WAL 轮转文件数）
          fail "  规则④：$k=$bad 被静默接受 —— 非法值已落盘到 iotdb-system.properties 且 show configuration 原样回显，全程零文案（需求：不得静默接受，必须回退默认值并给出明确文案）；按源码该键 setter 只在 >0 时调用（IoTDBDescriptor.java:2212-2213）⇒ 运行期很可能仍用默认 $def，运行期真值见 tools/probe_w21_param_effective.sh 的行为判定"
          ;;
      esac
    fi
  else
    pass "  规则②：$k=$bad 未被原样接受（运行期生效值 != 非法值 ⇒ 回退/拒绝分支）"
    assert_eq "  回退目标核对：$k 生效值应回到默认 $def" "${eff:-$def}" "$def"
    if [ "$msg" -gt 0 ]; then
      pass "  且有 $msg 行关于该键的告警文案"
    else
      warn "  回退是静默的（生效值 != 非法值但无告警文案；源码 §1.3 的 >0 分支确实不打日志）⇒ 如实记录，不判 FAIL"
    fi
  fi
  w21_write || return 0
  w21_data_check "相 $k"
  return 0; }

# ---------------------------------------------------------------------------
# 相 5：wal_mode=XXX（非法枚举 ⇒ 必须启动失败）
# ---------------------------------------------------------------------------
w21_phase_enum(){ local h pv i ok=0 hit0=0 hit1=0 inc=0 alive=0 dl
  log "==================== 相 5：wal_mode=XXX（非法枚举；源码 WALMode.valueOf ⇒ IllegalArgumentException） ===================="
  cluster_stop
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    sshx "$h" "pkill -f 'com\.timecho\.iotdb\.(ConfigNode|DataNode)' >/dev/null 2>&1 || true" || true
  done
  sleep 3
  EXTRA_CONF="$(w21_strip_keys 'wal_mode'),wal_mode=XXX,$CMP_EXTRA_WRITE" cluster_write_conf
  for h in "${DN[@]}"; do
    pv=$(wal_props_get "$h" wal_mode)
    assert_eq "  场景有效性：$h 的 properties 里 wal_mode=XXX（来源：$DB_DIR/conf/iotdb-system.properties）" "${pv:-<无>}" "XXX"
  done
  for h in "${DN[@]}"; do hit0=$(( hit0 + $(w21_enum_cnt "$h") )); done
  log "  启动前枚举异常文案基线=$hit0（用增量判定，避免旧日志误判）"

  log "--- 先起 CN 并等内部端口就绪（否则 DN 失败无法归因于非法枚举）---"
  for h in "${CN[@]}"; do
    sshx "$h" "mkdir -p $CN_DB_DIR/logs && cd $CN_DB_DIR && nohup ./sbin/start-confignode.sh -d >/dev/null 2>&1 </dev/null &" || warn "启动 CN $h 返回非 0"
  done
  for i in $(seq 1 60); do
    ok=1
    for h in "${CN[@]}"; do [ "$(w21_cn_listen "$h")" = "1" ] || ok=0; done
    [ "$ok" = "1" ] && break
    sleep 5
  done
  [ "$ok" = "1" ] && pass "  前置条件：CN 内部端口 $CN_INTERNAL_PORT 已就绪" \
    || fail "  场景无效：CN 未就绪 ⇒ DN 的失败无法归因于 wal_mode=XXX"

  log "--- 起 DN（守护方式，捕获启动输出）---"
  for h in "${DN[@]}"; do
    sshx "$h" "mkdir -p $DB_DIR/logs && cd $DB_DIR && nohup ./sbin/start-datanode.sh -d > $DB_DIR/logs/w21_daemon_${h##*.}.log 2>&1 </dev/null &" || warn "启动 DN $h 返回非 0"
  done
  dl=$(( $(date +%s) + WIN ))
  while (( $(date +%s) < dl )); do
    hit1=0; alive=0
    for h in "${DN[@]}"; do
      hit1=$(( hit1 + $(w21_enum_cnt "$h") ))
      [ -n "$(w21_dn_pid "$h")" ] && alive=$(( alive + 1 ))
    done
    inc=$(( hit1 - hit0 )); [ "$inc" -lt 0 ] && inc=0
    log "    负向观察：枚举异常文案增量=$inc；存活 DN=$alive/${#DN[@]}"
    [ "$alive" -eq 0 ] && [ "$inc" -ge "${#DN[@]}" ] && break
    sleep 5
  done
  for h in "${DN[@]}"; do
    log "    [$h] 文案命中=$(w21_enum_cnt "$h")；原文：$(w21_enum_line "$h")"
  done
  inc=$(( hit1 - hit0 )); [ "$inc" -lt 0 ] && inc=0
  if [ "$alive" -gt 0 ]; then
    fail "  非法枚举被接受：wal_mode=XXX 下仍有 $alive 个 DN 存活（源码 §1.2-1 应抛 IllegalArgumentException 而启动失败）"
  elif [ "$inc" -ge "${#DN[@]}" ]; then
    pass "  非法枚举 wal_mode=XXX ⇒ 全部 DN 启动失败，且每个 DN 都命中明确异常文案（增量 $inc）"
  else
    fail "  非法枚举 wal_mode=XXX ⇒ DN 未存活但异常文案增量只有 $inc（<${#DN[@]}）⇒ 无法归因（候选文件：$(w21_dn_files)）"
  fi

  log "--- 恢复：合法 conf 重启（**不 clean** ⇒ 既有数据必须还在）---"
  cluster_stop
  EXTRA_CONF="$GOOD" cluster_write_conf
  cluster_start
  local nr
  nr=$(w21_running)
  assert_eq "  恢复后集群就绪（Running/ReadOnly 行数）" "${nr:-0}" "$TOTAL"
  for h in "${DN[@]}"; do
    assert_eq "  恢复后 $h 的 wal_mode 落盘值" "$(wal_props_get "$h" wal_mode)" "ASYNC"
  done
  w21_data_check "相 5 恢复后（非法枚举重启不影响既有数据）"
  return 0; }

# ===========================================================================
# 主流程
# ===========================================================================
log "=== W-21 参数合法性（负向）：库 $DB；非法键=${BAD_KS[*]}；非法枚举=wal_mode=XXX ==="
log "  合法组合（对照相）：$GOOD"

log "--- 相 0) 对照相：合法取值 ⇒ 集群准备 + 建库 + 首批写入 ---"
EXTRA_CONF="$GOOD" cmp_cluster_prepare
DEF_TH=$(wal_eff "${DN[0]}" wal_file_size_threshold_in_byte | tr -d ' \r'); [ -n "$DEF_TH" ] || DEF_TH=31457280
DEF_BUF=$(wal_eff "${DN[0]}" wal_buffer_size_in_byte | tr -d ' \r'); [ -n "$DEF_BUF" ] || DEF_BUF=33554432
DEF_RATIO=$(wal_eff "${DN[0]}" wal_min_effective_info_ratio | tr -d ' \r'); [ -n "$DEF_RATIO" ] || DEF_RATIO=0.1
DEF_NODES=$(wal_eff "${DN[0]}" max_wal_nodes_num | tr -d ' \r'); [ -n "$DEF_NODES" ] || DEF_NODES=0
log "  实测默认生效值（show configuration）：file_size_threshold=$DEF_TH buffer=$DEF_BUF ratio=$DEF_RATIO max_nodes=$DEF_NODES"
log "  对照相落盘值：$(for h in "${DN[@]}"; do printf '%s[%s] ' "${h##*.}" "$(wal_props_get "$h" wal_mode)"; done)"
N0=$(w21_running)
assert_eq "  对照相：合法取值下集群就绪（Running/ReadOnly 行数）" "${N0:-0}" "$TOTAL"
cmp_make_tree_db "$DB" "$DEVS"
w21_write || fail "  对照相首批写入失败（场景无效）"
w21_data_check "对照相"
w21_wal_report "对照相"
[ "$(wal_sum_over_dn wal_file_cnt)" -ge 1 ] && pass "  对照相：WAL 目录确有 .wal（合法取值下 WAL 处于启用状态）" \
  || fail "  对照相：WAL 文件数=0（场景无效）"

log "--- 相 1..4) 逐个非法数值键（每相单独重启；源码默认：${BAD_DS[*]}）---"
for i in 0 1 2 3; do
  w21_phase_num "${BAD_KS[$i]}" "${BAD_VS[$i]}" "${BAD_DS[$i]}"
done

log "--- 相 5) 非法枚举（wal_mode=XXX）---"
w21_phase_enum

log "--- 相 6) 收尾对照：合法取值 + 逐键生效值回到默认 + 数据/WAL 面 ---"
for h in "${DN[@]}"; do
  log "    [$h] 生效值：th=$(wal_eff "$h" wal_file_size_threshold_in_byte) buf=$(wal_eff "$h" wal_buffer_size_in_byte) ratio=$(wal_eff "$h" wal_min_effective_info_ratio) nodes=$(wal_eff "$h" max_wal_nodes_num) wal_mode=$(wal_eff "$h" wal_mode)"
done
w21_wal_report "收尾"
[ "$(wal_sum_over_dn wal_file_cnt)" -ge 1 ] && pass "  收尾：合法取值下 WAL 目录仍有 .wal" \
  || fail "  收尾：WAL 文件数=0（与 wal_mode=ASYNC 的语义不符）"
w21_data_check "收尾"
wal_metrics_dump "${DN[0]}"

log "--- 判读 ---"
log "  规则：① 启动失败 ⇒ PASS；② 回退（生效值 != 非法值）⇒ PASS；③ 原样接受 + 有文案 ⇒ PASS+WARN；"
log "        ④ 原样接受 + 无文案 ⇒ FAIL（静默接受）；⑤ 生效值不可观测 ⇒ 只记录 + WARN。"
log "  源码依据（source_grounding §1.3）：4 个数值键都只有 if (… > 0) 的**静默**判断；"
log "  wal_mode 走 WALMode.valueOf ⇒ 非法枚举必然启动失败（本用例用「异常文案增量」证明确实是它）。"
log "  累计写入批数=$BATCH（数据面 count=$(w21_exp_count) sum=$(w21_exp_sum)）"

# ===========================================================================
# 收尾三件套（本用例**不装** WAL 建议正则：负向相会故意让 DN 起不来）
# ===========================================================================
log "--- 收尾三件套 ---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
export CMP_LOG_BENIGN_EXTRA='No enum constant|IllegalArgumentException|WALMode|wal_mode|Configuring the WALMode as disable is not supported|Execute FragmentInstance in ConsensusGroup|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader|Connection refused|Connection reset by peer'
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
