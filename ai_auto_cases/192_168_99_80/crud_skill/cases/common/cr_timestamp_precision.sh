#!/bin/bash
# ============================================================================
# CR-01 时间戳精度检查门禁（tree 模型）
#   覆盖需求点：R-01 / R-02 / R-03 / R-04 / R-07（docs/REQ_MATRIX.md §1、§3 CR-01）
#
#   需求逐字要点：
#     R-01「提供一个配置项，使系统可以检查用户数据时间戳与时间精度配置项不匹配的问题。」
#          （`timestamp_precision_check_enabled` / 布尔 / 默认 true）
#     R-02 ms：13 位时间戳合法；超过即报错并返回"系统当前时间戳精度为 xx，请检查时间戳是否正确"
#     R-03 us：16 位合法；超过即报错（同一文案）
#     R-04 ns：Long.maxValue 已 19 位 ⇒ 用户时间戳不可能超过 19 位，无需额外处理
#     R-07「只用系统管理员可以修改该配置。」
#
#   源码依据（D:\IDEA\timechodb_src\v20121\timechodb，HEAD 67bb5ced，RC7=7c61428 为其祖先）：
#     · 阈值 / ns 短路：node-commons/.../queryengine/utils/TimestampPrecisionUtils.java:66-90
#         ms: `time > 10_000_000_000_000L || time < -10_000_000_000_000L`  ⇒ 抛 SemanticException
#         us: `time > 10_000_000_000_000_000L || time < -10_000_000_000_000L`
#             ★ 负向阈值与 ms 相同（疑似笔误）⇒ us 相只做**正向**硬断言，"负向"只作观察记录
#         ns: 直接 break（不检查）
#     · 报错文案：node-commons/src/main/i18n/en/.../QueryMessages.java:241-245
#         「The timestamp is unexpectedly large, you may forget to set the timestamp precision.」
#          + 「Current system timestamp precision is %s, 」
#          + 「please check whether the timestamp %s is correct.」
#          + 「If you insist to insert this timestamp, please set timestamp_precision_check_enabled=false and restart the server.」
#         （注意原文 "precision." 与 "Current" 之间**没有空格**，断言用 grep -F 分段匹配）
#     · 开关是**每次调用现读**（无 static 缓存）⇒ 可热改：TimestampPrecisionUtils.java:67-71
#     · `timestamp_precision` 在 static 块里只读一次 ⇒ **改精度必须重启**：:28-58
#     · 模板：iotdb-system.properties.template:1554-1564（:1556 first_start、:1562 hot_reload；两键均无
#       `# Privilege:` 标注 ⇒ 见下"权限相"）
#     · INSERT 侧调用点：datanode/.../plan/parser/ASTVisitor.java:2342（树）、
#       .../relational/sql/parser/AstBuilder.java:1202（表）
#
#   两处"文档/矩阵 ↔ 源码"不一致（用例按**源码**断言，并把差异写进日志与 WARN）：
#     ① 边界：源码判据是 `time > 10^13`（不是"位数"）⇒ **恰好 10^13 放行**；文档/模板注释口径为
#        "位数超过 13 位即拒"（10^13 = 10000000000000 是 14 位）⇒ 两条口径在这一点上矛盾。
#     ② 权限相：R-07 要求"只有系统管理员能改"。源码里 SET CONFIGURATION 需要的权限来自配置模板的
#        `# Privilege:` 标注（ConfigurationFileUtils.getConfigurationItemPrivilege:313-322），而
#        `timestamp_precision_check_enabled` **没有**该标注 ⇒ neededPrivileges 为空 ⇒
#        TreeAccessCheckVisitor:1883-1899 + AuthorityChecker:487-493/247-253 直接 SUCCEED。
#        ⇒ 判据以**实际影响**为准：非管理员改完后生效值必须没变（真被改掉 = R-07 未满足 = FAIL）。
#
#   错误码口径（矩阵写 "SemanticException(≈507)"，与源码不符，本用例三者都接受并打印实测值）：
#     TSStatusCode.java:131 `SEMANTIC_ERROR(701)`（SemanticException 默认码）
#     TSStatusCode.java:69  `METADATA_ERROR(507)`；:227 `LOAD_FILE_ERROR(1100)`（load 侧包装码）
#     ⇒ **待实测确认**；实跑输出里会写明"如期被拒 code=xxx"。
#
#   双信号：① 客户端逐字文案条数（每条拒绝都逐字核对四个片段）+ DN 日志
#           `The timestamp is unexpectedly large` 行数增量（**辅**：矩阵 §3 CR-01 场景有效性③
#           明确允许"错误在解析层被挡 ⇒ DN 日志无该条 ⇒ 记 WARN，不判 FAIL"）；
#           ② 数据面：合法写入的行数 / 载荷值逐条一致，被拒的**不落任何行、不覆盖原值**。
#
#   相位：ms（合法/非法/边界/负向）→ 关闭相（热改开关的 A/B 对照）→ us（含权限相）→ ns。
#        改 `timestamp_precision` 必须重启 ⇒ **2 次"停集群 → 写配置 → 启集群"且不 clean**（保留数据）。
#
#   ★★ RC8 首轮实跑暴露的**关键事实**（本用例已据此修，务必别再退回"只改 conf 就重启"）：
#     `timestamp_precision` 是 **first_start** 参数（模板 :1554-1558 逐字：
#     "Once the precision has been set, it can not be changed."）。ConfigNode 在**首次启动**时
#     把该值写进 `data/confignode/system/confignode-system.properties`
#     （SystemPropertiesUtils.storeSystemParameters:320），**之后每次重启都由该文件覆盖**
#     `conf/iotdb-system.properties` 里的值（SystemPropertiesUtils.checkSystemProperties:120-127
#     `setTimestampPrecision(systemProperties.getProperty(TIMESTAMP_PRECISION))`）；
#     DataNode 又从 ConfigNode 拉全局配置（DataNode.java:513 loadGlobalConfig + :542
#     initTimestampPrecision）⇒ 三节点的生效值全部由**CN 的首启快照**决定。
#     RC8 实测：conf 里写 `timestamp_precision=us` 并整集群重启，三节点生效值**仍是 ms**，
#     于是 us/ns 两相全部判"场景未成立"（10 条连带 FAIL）。
#     ⇒ 本用例在 `cluster_stop` 之后**同步改写各节点 CN 首启快照**（不 clean data，数据保留），
#        再 start；然后**轮询**逐节点确认生效值（`show configuration` 的 timestamp_precision 来自
#        CN 全局配置，见 ConfigurationFileUtils.updateAppliedPropertiesFromCN:146-150）。
#   规模/时长：4 相位 + 2 次重启，约 15~20 分钟。
#   用法：bash cases/common/cr_timestamp_precision.sh [--consensus IoTConsensus|IoTConsensusV2]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_timestamp_precision_${DATA_CONSENSUS}"

# ---------------------------------------------------------------- 变量（规模/语料放顶部）
DB=root.cr01
DEV_MS=d1          # ms 相（含边界/负向）
DEV_OFF=d2         # 关闭相（A/B 对照）
DEV_US=d3          # us 相（+ 权限相）
DEV_NS=d4          # ns 相
TS_MS_OK=1693987852987         # 13 位：ms 合法
TS_MS_BAD=16939878529870       # 14 位：ms 非法（R-02 语料）
TS_BOUND_OK=10000000000000     # = 10^13：源码 `>10^13` ⇒ 放行（文档口径应拒 ⇒ 差异①）
TS_BOUND_BAD=10000000000001    # = 10^13+1 ⇒ 拒
TS_NEG_BAD=-10000000000001     # 负向边界（源码 ms 侧 < -10^13）⇒ 拒
TS_US_OK=1693987852987000      # 16 位：us 合法（R-03 语料）
TS_US_BAD=16939878529870000    # 17 位：us 非法
TS_NS_MAX=9223372036854775807  # 19 位 = Long.MAX_VALUE（R-04）
U_NAME="${CR01_USER:-cr01user}"
U_PASS="${CR01_PASS:-CrudPass@2026x}"
BASE_CONF="$CMP_EXTRA_WRITE,timestamp_precision_check_enabled=true"
EVID="$ART/${CASE}.evidence.txt"
: >"$EVID"
REJ_N=0
ACC_N=0

# ---------------------------------------------------------------- 本地 helper（只在本用例内定义，不改 lib）
ev(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$EVID"; }
cr01_oneline(){ printf '%s' "$1" | tr '\n\r' '  ' | tr -s ' ' | cut -c1-400; }
# 从 CLI 输出里取错误码（无错误 ⇒ 空）
cr01_code(){ printf '%s\n' "$1" | grep -oE 'IoTDBSQLException: [0-9]+' | head -1 | grep -oE '[0-9]+$'; }
cr01_sql(){ sq "$1"; }
# 以指定用户执行（权限相用；sq 固定用 DB_USER）
cr01_as(){ timeout "$SQL_TIMEOUT_SEC" "$CLI" -h "$QDN" -u "$1" -pw "$2" -timeout 3600 -e "$3" 2>&1; }
# 单设备"原始查询"数行（**不要**用聚合：树方言具体设备路径上的聚合会退化成 Empty set）
cr01_rows(){ sq "select s1 from $DB.$1 order by time;" 2>&1 | table_rows | wc -l | tr -dc '0-9'; }
cr01_vals(){ sq "select s1 from $DB.$1 order by time;" 2>&1 | table_rows | awk -F'|' '{v=$3; gsub(/^[ \t]+|[ \t]+$/,"",v); printf "%s|", v}'; echo; }
cr01_haskey(){ printf '%s' "$2" | tr '|' '\n' | grep -qxF -- "$1"; }
# 轮询等行数达到期望（DELETE/写入走共识，会有短延迟）；回显最后一次观测值
cr01_wait_rows(){ local dev=$1 want=$2 win=$3 got=0
  local dl
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(cr01_rows "$dev")
    [ "$got" = "$want" ] && { echo "$got"; return 0; }
    sleep 3
  done
  echo "${got:-0}"; return 1
}
# DN all 日志里"精度报错文案"行数（全部 DN 求和）
cr01_msgcnt(){ local h s=0 n
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "grep -hc 'The timestamp is unexpectedly large' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done
  echo "$s"
}
# 精度生效值：优先 show configuration，读不到就退回 conf 文件（双证）
cr01_prec(){ local h=$1 v
  v=$(cmp_eff "$h" timestamp_precision)
  if [ -z "$v" ]; then
    v=$(sshx "$h" "grep -E '^timestamp_precision=' $DB_DIR/conf/iotdb-system.properties 2>/dev/null | tail -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r')
  fi
  printf '%s' "${v:-}"
}
cr01_eff_all(){ local k=$1 h out=""
  for h in "${DN[@]}"; do out="$out${h##*.}=$(cmp_eff "$h" "$k") "; done
  printf '%s' "$out"
}
cr01_wait_eff(){ local k=$1 want=$2 win=$3 h v ok
  local dl
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    ok=1
    for h in "${DN[@]}"; do
      v=$(cmp_eff "$h" "$k")
      [ "$v" = "$want" ] || ok=0
    done
    [ "$ok" = 1 ] && { printf '%s' "$(cr01_eff_all "$k")"; return 0; }
    sleep 3
  done
  printf '%s' "$(cr01_eff_all "$k")"; return 1
}
# 期望"被拒"：必须拿到非空错误码 + 四个逐字文案片段
cr01_reject(){ local label=$1 out=$2 ts=$3 prec=${4:-ms} code joined
  REJ_N=$(( REJ_N + 1 ))
  ev "$label | $(cr01_oneline "$out")"
  code=$(cr01_code "$out")
  if [ -z "$code" ]; then
    fail "$label：期望被拒，实际成功（响应：$(cr01_oneline "$out")）"
  else
    case " 1100 507 701 " in
      *" $code "*) pass "$label：如期被拒 code=$code";;
      *) fail "$label：被拒但 code=$code ∉ {1100,507,701}（文档 1100 / 矩阵 507 / 源码 SEMANTIC_ERROR 701 ⇒ 待实测确认）";;
    esac
  fi
  joined=$(printf '%s' "$out" | tr '\n\r' '  ')
  if printf '%s' "$joined" | grep -qF 'The timestamp is unexpectedly large, you may forget to set the timestamp precision'; then
    pass "$label：文案①逐字匹配"
  else
    fail "$label：缺文案①（逐字：The timestamp is unexpectedly large, you may forget to set the timestamp precision）"
  fi
  if printf '%s' "$joined" | grep -qF "Current system timestamp precision is $prec"; then
    pass "$label：文案②含当前精度 $prec"
  else
    fail "$label：缺文案②（期望含 Current system timestamp precision is $prec）"
  fi
  if printf '%s' "$joined" | grep -qF "whether the timestamp $ts is correct"; then
    pass "$label：文案③回显时间戳 $ts"
  else
    fail "$label：缺文案③（期望含 whether the timestamp $ts is correct）"
  fi
  if printf '%s' "$joined" | grep -qF 'please set timestamp_precision_check_enabled=false and restart the server'; then
    pass "$label：文案④逐字匹配"
  else
    fail "$label：缺文案④（逐字：please set timestamp_precision_check_enabled=false and restart the server）"
  fi
}
# 期望"成功"：不得有错误码
cr01_accept(){ local label=$1 out=$2 code
  ACC_N=$(( ACC_N + 1 ))
  ev "$label | $(cr01_oneline "$out")"
  code=$(cr01_code "$out")
  if [ -z "$code" ]; then
    pass "$label：如期写入成功"
  else
    fail "$label：期望成功，实际报错 code=$code（$(cr01_oneline "$out")）"
  fi
}
# 改写 ConfigNode 的**首启快照**里的 timestamp_precision（first_start 参数的唯一有效来源，见头注释）
#   ⚠️ 必须在 cluster_stop 之后调用（进程停稳后再改持久化文件）
#   不 clean data ⇒ 已写数据全部保留；快照文件不存在（真正首次启动）时跳过并记录
cr01_set_prec(){ local prec=$1 h f out
  for h in $(printf '%s\n' "${CN[@]}" "${DN[@]}" | sort -u); do
    f="$DB_DIR/data/confignode/system/confignode-system.properties"
    out=$(sshx "$h" "f='$f'; if [ -f \"\$f\" ]; then if grep -qE '^timestamp_precision=' \"\$f\"; then sed -i -E 's#^timestamp_precision=.*#timestamp_precision=$prec#' \"\$f\"; else printf 'timestamp_precision=%s\n' '$prec' >> \"\$f\"; fi; grep -hE '^timestamp_precision=' \"\$f\"; else echo NOFILE; fi" 2>/dev/null | tr -d '\r')
    log "  [$prec] $h 首启快照 timestamp_precision=[${out:-取不到}]"
  done
}
# 停 → 写 conf（**不 clean**，保留已写数据）→ 改 CN 首启快照 → 启
cr01_restart_prec(){ local prec=$1
  log "--- 切 timestamp_precision=$prec：cluster_stop → 写 conf（不 clean，保留数据）→ 改 CN 首启快照 → cluster_start ---"
  cluster_stop
  EXTRA_CONF="$BASE_CONF,timestamp_precision=$prec" cluster_write_conf
  cr01_set_prec "$prec"
  cluster_start
}
# 逐节点确认生效值（**轮询**：配置经 CN 全局配置下发到 DN，刚启动时可能还没同步过来）
cr01_check_prec(){ local want=$1 label=$2 h got ok dl
  ok=0; dl=$(( $(date +%s) + 90 ))
  while (( $(date +%s) < dl )); do
    ok=1
    for h in "${DN[@]}"; do
      got=$(cr01_prec "$h")
      [ "$got" = "$want" ] || ok=0
    done
    [ "$ok" = 1 ] && break
    sleep 5
  done
  for h in "${DN[@]}"; do
    got=$(cr01_prec "$h")
    log "  [$label] $h timestamp_precision=[${got:-取不到}]（期望 $want）"
    [ "$got" = "$want" ] || ok=0
  done
  if [ "$ok" = 1 ]; then
    pass "场景有效：三节点 timestamp_precision 生效值 = $want"
  else
    fail "场景未成立：$label 下有节点的 timestamp_precision ≠ $want（conf 已写 + CN 首启快照已改；仍不一致请查 CN/DN 是否都重启、快照文件是否被别处覆盖）"
  fi
}

# ============================================================================
# 集群准备（ms 相）＋ 建库
# ============================================================================
log "--- 集群准备（ms 相；写入期三类合并全关；$BASE_CONF）---"
EXTRA_CONF="$BASE_CONF" cmp_cluster_prepare
cmp_compaction_off
cr01_check_prec ms "ms 相"
assert_eq "  开关生效值 timestamp_precision_check_enabled" "$(cmp_eff "${DN[0]}" timestamp_precision_check_enabled)" "true"

log "--- 建库/建序列：$DB ---"
cr01_sql "create database $DB;" >/dev/null
for d in "$DEV_MS" "$DEV_OFF" "$DEV_US" "$DEV_NS"; do
  cr01_sql "create timeseries $DB.$d.s1 with datatype=INT64;" >/dev/null
done
assert_eq "  场景有效：时序数" "$(cr01_sql "show timeseries $DB.**;" | table_rows | wc -l | tr -dc '0-9')" "4"

# ============================================================================
# 相位 1/4：ms 相（合法 / 非法 / 边界 / 负向）
# ============================================================================
# ⚠️ 双引号字符串里**不要**写反引号：`log "... `time > 10^13` ..."` 会被 bash 当命令替换执行
#    （RC8 首轮实测：日志里那句阈值说明被吃掉、还多出 `real 0m0.000s` 与一个空文件 10^13，该空文件已删除）。
#    下面一律用单引号包代码片段。
log "--- 相位 1/4：ms 相（源码阈值 '>10^13' 才判非法）---"
REJ_N=0; ACC_N=0
MS_LOG0=$(cr01_msgcnt)

r=$(cr01_sql "insert into $DB.$DEV_MS(time,s1) values($TS_MS_OK,1);")
cr01_accept "A1 ms 13 位合法时间戳 $TS_MS_OK" "$r"

r=$(cr01_sql "insert into $DB.$DEV_MS(time,s1) values($TS_MS_BAD,2);")
cr01_reject "A2 ms 14 位非法时间戳 $TS_MS_BAD" "$r" "$TS_MS_BAD" ms

r=$(cr01_sql "insert into $DB.$DEV_MS(time,s1) values($TS_BOUND_OK,3);")
A3_CODE=$(cr01_code "$r")
ev "A3 边界 10^13 | $(cr01_oneline "$r")"
if [ -z "$A3_CODE" ]; then
  pass "A3 边界 10^13=$TS_BOUND_OK：源码 'time > 10^13' ⇒ 放行"
  warn "文档-源码差异①：10^13（14 位）源码放行，而文档/模板注释（template:1560）口径为'位数超过 13 位即拒' ⇒ 取哪个口径需研发确认（本用例按源码断言放行）"
else
  fail "A3 边界 10^13=$TS_BOUND_OK 被拒（code=$A3_CODE）——与源码 TimestampPrecisionUtils.java:74 的 'time > 10_000_000_000_000L' 不符，需回报研发"
fi

r=$(cr01_sql "insert into $DB.$DEV_MS(time,s1) values($TS_BOUND_BAD,4);")
cr01_reject "A4 边界 10^13+1=$TS_BOUND_BAD" "$r" "$TS_BOUND_BAD" ms

r=$(cr01_sql "insert into $DB.$DEV_MS(time,s1) values($TS_NEG_BAD,5);")
cr01_reject "A5 负向边界 $TS_NEG_BAD" "$r" "$TS_NEG_BAD" ms

cr01_sql "flush;" >/dev/null
if [ "$A3_CODE" = "" ]; then
  got=$(cr01_wait_rows "$DEV_MS" 2 90)
  assert_eq "A 相数据面：行数（$DEV_MS）" "$got" "2"
  vals=$(cr01_vals "$DEV_MS")
  if cr01_haskey 1 "$vals" && cr01_haskey 3 "$vals"; then
    pass "A 相数据面：载荷 1、3 都在（被拒的 2/4/5 未落行）"
  else
    fail "A 相数据面异常：$vals（期望只含 1|3）"
  fi
else
  got=$(cr01_wait_rows "$DEV_MS" 1 90)
  assert_eq "A 相数据面：行数（$DEV_MS，A3 未落行）" "$got" "1"
fi
assert_eq "A 相：客户端逐字报错条数" "$REJ_N" "3"
MS_LOG1=$(cr01_msgcnt)
MS_D=$(( MS_LOG1 - MS_LOG0 ))
if [ "$MS_D" -ge 3 ]; then
  pass "A 相双信号①（辅）：DN 日志精度报错行数 +$MS_D（≥3）"
else
  warn "A 相双信号①（辅）：DN 日志 'The timestamp is unexpectedly large' 行数 +$MS_D（期望 ≥3）——错误多半在解析层直接返回而未落 DN all 日志（REQ_MATRIX §3 CR-01 场景有效性③ 明确允许记 WARN）；客户端侧已逐条拿到逐字文案（见 $EVID）"
fi

# ============================================================================
# 相位 2/4：关闭相（热改开关的 A/B 对照；精度仍 ms）
# ============================================================================
log "--- 相位 2/4：关闭相（timestamp_precision_check_enabled 热改 hot_reload）---"
REJ_N=0; ACC_N=0
hot=$(cmp_is_hot_key timestamp_precision_check_enabled false | tail -1)
assert_eq "  开关是否热加载（响应不含 restart is required）" "$hot" "yes"
if cr01_wait_eff timestamp_precision_check_enabled false 90 >/dev/null; then
  pass "场景有效：热改 false 后三节点生效值一致（$(cr01_eff_all timestamp_precision_check_enabled)）"
else
  fail "场景未成立：热改 false 后三节点生效值不一致（$(cr01_eff_all timestamp_precision_check_enabled)）"
fi

r=$(cr01_sql "insert into $DB.$DEV_OFF(time,s1) values($TS_MS_BAD,7);")
cr01_accept "B1 关闭检查后同一 14 位时间戳 $TS_MS_BAD（A2 在开启态被拒）" "$r"
got=$(cr01_wait_rows "$DEV_OFF" 1 90)
assert_eq "B1 数据面：行数（$DEV_OFF）" "$got" "1"

cmp_set_hot timestamp_precision_check_enabled true >/dev/null
if cr01_wait_eff timestamp_precision_check_enabled true 90 >/dev/null; then
  pass "场景有效：置回 true 后三节点生效值一致（$(cr01_eff_all timestamp_precision_check_enabled)）"
else
  fail "场景未成立：置回 true 后三节点生效值不一致（$(cr01_eff_all timestamp_precision_check_enabled)）"
fi
r=$(cr01_sql "insert into $DB.$DEV_OFF(time,s1) values($TS_MS_BAD,8);")
cr01_reject "B2 重新开启后同一时间戳（换载荷重放）" "$r" "$TS_MS_BAD" ms
vals=$(cr01_vals "$DEV_OFF")
assert_eq "B2 数据面：被拒既不落行也不覆盖原值（$DEV_OFF）" "$vals" "7|"
assert_eq "B 相：关闭态放行 / 开启态拒绝 次数" "$ACC_N/$REJ_N" "1/1"

# ============================================================================
# 相位 3/4：us 相（重启）+ 权限相（R-07）
# ============================================================================
log "--- 相位 3/4：us 相（重启到 timestamp_precision=us）---"
cr01_restart_prec us
cr01_check_prec us "us 相"
REJ_N=0; ACC_N=0

r=$(cr01_sql "insert into $DB.$DEV_US(time,s1) values($TS_US_OK,11);")
cr01_accept "C1 us 16 位合法时间戳 $TS_US_OK" "$r"
got=$(cr01_wait_rows "$DEV_US" 1 90)
assert_eq "C1 数据面：行数（$DEV_US）" "$got" "1"

r=$(cr01_sql "insert into $DB.$DEV_US(time,s1) values($TS_US_BAD,12);")
cr01_reject "C2 us 17 位非法时间戳 $TS_US_BAD" "$r" "$TS_US_BAD" us

# 观察项：us 的**负向**阈值在源码里仍是 -10^13（与 ms 相同），与文档"us 只拒超过 16 位"不一致
r=$(cr01_sql "insert into $DB.$DEV_US(time,s1) values($TS_NEG_BAD,13);")
NEG_CODE=$(cr01_code "$r")
ev "us 负向观察 $TS_NEG_BAD | $(cr01_oneline "$r")"
if [ -n "$NEG_CODE" ]; then
  log "  [观察项] us 负向 $TS_NEG_BAD 被判非法（code=$NEG_CODE）：与源码 TimestampPrecisionUtils.java:80 的负向阈值 -10^13 一致；但与文档「us 只拒超过 16 位」不一致（疑似源码笔误）⇒ 记录，不判 FAIL"
else
  log "  [观察项] us 负向 $TS_NEG_BAD 被放行：与文档口径一致，但与源码 :80 负向阈值 -10^13 不符"
  warn "us 负向阈值观察：$TS_NEG_BAD 被放行，与源码 TimestampPrecisionUtils.java:80 的负向阈值 -10^13 不一致（记录，不判 FAIL）"
fi

vals=$(cr01_vals "$DEV_US")
if cr01_haskey 11 "$vals" && ! cr01_haskey 12 "$vals"; then
  pass "C 相数据面：含 11 且不含 12（实际 $vals）"
else
  fail "C 相数据面异常：$vals（期望含 11、不含 12）"
fi
assert_eq "C 相：正向放行 / 非法拒绝 次数" "$ACC_N/$REJ_N" "1/1"

log "  --- 权限相（R-07：非 SYSTEM 用户不得修改该配置）---"
out=$(cr01_sql "create user $U_NAME '$U_PASS';")
ev "create user $U_NAME | $(cr01_oneline "$out")"
out=$(cr01_sql "list user;")
ev "list user | $(cr01_oneline "$out")"
if [ "$(printf '%s\n' "$out" | grep -c "$U_NAME")" -ge 1 ]; then
  pass "权限相场景有效：用户 $U_NAME 已存在"
else
  fail "场景未成立：用户 $U_NAME 未创建成功（LIST USER 原文见 $EVID）"
fi
pout=$(cr01_as "$U_NAME" "$U_PASS" "show databases;")
pcode=$(cr01_code "$pout")
ev "非管理员 show databases | $(cr01_oneline "$pout")"
if [ -z "$pcode" ]; then
  pass "权限相正向对照：非管理员用户可正常登录并执行查询（权限模型确实在生效）"
else
  fail "场景未成立：非管理员用户连查询都报错 code=$pcode ⇒ 无法区分'权限不足'与'登录失败'（$(cr01_oneline "$pout")）"
fi
sout=$(cr01_as "$U_NAME" "$U_PASS" "set configuration 'timestamp_precision_check_enabled'='false';")
scode=$(cr01_code "$sout")
eff_after=$(cmp_eff "${DN[0]}" timestamp_precision_check_enabled)
ev "非管理员 SET CONFIGURATION 'timestamp_precision_check_enabled'='false' | $(cr01_oneline "$sout")"
log "  非管理员 SET 响应 code=[${scode:-无}]，生效值=[${eff_after:-?}]"
if [ -n "$scode" ] && [ "$eff_after" = "true" ]; then
  pass "R-07：非 SYSTEM 用户 $U_NAME 被拒（code=$scode），生效值仍为 true"
elif [ -z "$scode" ] && [ "$eff_after" = "true" ]; then
  pass "R-07：非 SYSTEM 用户 SET 未报权限错、但生效值未变（仍 true）"
  warn "R-07 观察：非管理员 SET 既未报错也未生效（响应：$(cr01_oneline "$sout")）⇒ 是否应显式报无权限，需研发确认"
else
  fail "R-07 未满足：非 SYSTEM 用户 $U_NAME 改动了 timestamp_precision_check_enabled（响应 code='${scode:-无}'，生效值='${eff_after:-?}'）；源码依据：该键在模板里无 '# Privilege:' 标注 ⇒ ConfigurationFileUtils.getConfigurationItemPrivilege:313-322 返回 null ⇒ TreeAccessCheckVisitor:1883-1899 的 neededPrivileges 为空 ⇒ AuthorityChecker:247-253 直接 SUCCEED"
  cmp_set_hot timestamp_precision_check_enabled true >/dev/null 2>&1
  cr01_wait_eff timestamp_precision_check_enabled true 90 >/dev/null || warn "还原 true 失败，请检查（$(cr01_eff_all timestamp_precision_check_enabled)）"
fi
# 功能影响复测：若上一步真被改掉，17 位时间戳应被放行；这里必须仍被拒
r=$(cr01_sql "insert into $DB.$DEV_US(time,s1) values($TS_US_BAD,12);")
if [ -z "$(cr01_code "$r")" ]; then
  fail "R-07 影响面：非管理员改动之后 17 位时间戳被放行（写入成功）⇒ 权限失效已造成实际影响"
else
  pass "R-07 影响面：17 位时间戳仍被拒（code=$(cr01_code "$r")），权限失效未造成实际影响"
fi

# ============================================================================
# 相位 4/4：ns 相（重启）
# ============================================================================
log "--- 相位 4/4：ns 相（重启到 timestamp_precision=ns）---"
cr01_restart_prec ns
cr01_check_prec ns "ns 相"
REJ_N=0; ACC_N=0
NS_LOG0=$(cr01_msgcnt)
r=$(cr01_sql "insert into $DB.$DEV_NS(time,s1) values($TS_NS_MAX,21);")
cr01_accept "D1 ns 19 位时间戳 Long.MAX_VALUE=$TS_NS_MAX" "$r"
got=$(cr01_wait_rows "$DEV_NS" 1 90)
assert_eq "D 相数据面：行数（$DEV_NS）" "$got" "1"
vals=$(cr01_vals "$DEV_NS")
cr01_haskey 21 "$vals" && pass "D 相数据面：载荷 21 在（$vals）" || fail "D 相数据面异常：$vals"
NS_LOG1=$(cr01_msgcnt)
assert_eq "D 相：ns 下不得新增精度报错（源码 ns 分支直接 break）" "$(( NS_LOG1 - NS_LOG0 ))" "0"
assert_eq "D 相：拒绝条数" "$REJ_N" "0"

# ============================================================================
# 收尾三件套
# ============================================================================
log "--- 收尾三件套（基准 SQL：$DB.$DEV_MS 原始查询）---"
export CMP_LOG_BENIGN_EXTRA='The timestamp is unexpectedly large|timestamp_precision_check_enabled|unexpectedly large'
post_checks "select s1 from $DB.$DEV_MS order by time;" tree
cmp_case_finish "" tree ""
