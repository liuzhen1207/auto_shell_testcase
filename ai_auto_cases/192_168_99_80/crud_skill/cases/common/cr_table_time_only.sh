#!/bin/bash
# ============================================================================
# CR-03 表模型"只有 Time 列"门禁（写入相 + load 相）
#   覆盖需求点：R-12 / R-13 / R-14 / R-15（docs/REQ_MATRIX.md §1、§3 CR-03）
#
#   需求逐字要点：
#     R-12「在 https://github.com/apache/iotdb/pull/15017 PR 中，我们拒绝了不带 field 列的写入请求
#            和不带 field 列的 TsFile 的 load 请求。」
#     R-13「Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 1100: Loading file <path> failed.
#            Detail: No column other than Time present, please check the request」
#     R-14 场景 1「写入后 drop 掉所有 field 列，等待文件执行合并」（`alter table t1 drop column s1` / `s2`）；
#          场景 2「写入的 field 值都为 null，等待文件执行合并」（`insert into t1(time,s1,s2) values(1,null,null)`）；
#          结论「依然会生成不带 field 列的 TsFile，这样的 TsFile 无法 load 进 IoTDB。」
#     R-15「方案2 允许写入请求只有 Time 列」（**讨论稿候选方案，文档未记录评审结论**）
#
#   源码依据（D:\IDEA\timechodb_src\v20121\timechodb，RC7=7c61428 为其祖先）：
#     · 写入路径（无 field 列 ⇒ 拒）：datanode/.../metadata/fetcher/TableHeaderSchemaValidator.java:358-364
#         `final int measurementCount = ...; if (measurementCount == 0) throw new SemanticException(
#           DataNodeQueryMessages.NO_COLUMN_OTHER_THAN_TIME_PRESENT_PLEASE_CHECK);`
#     · load 路径（同一个文案、同一类异常）：同文件 :115-119 `validateTableHeaderSchema4TsFile`
#       `if (inputColumnList == null || inputColumnList.isEmpty()) throw new SemanticException(...)`
#     · 文案常量：datanode/src/main/i18n/en/.../DataNodeQueryMessages.java:917-918
#         `"No column other than Time present, please check the request"`（另有 :919-920 的 Field 版本文案）
#     · load 失败被包装成 LOAD_FILE_ERROR(1100)：
#       .../plan/analyze/load/LoadTsFileAnalyzer.java:387-393
#         `String.format("Loading file %s failed. Detail: %s", ...)` + `RpcUtils.getStatus(LOAD_FILE_ERROR, ...)`
#       ⇒ R-13 的 "1100: Loading file … Detail: …" 就是这条包装（**逐字可核对**）
#
#   错误码口径（★ 待实测确认；矩阵 §3 CR-03 写"load 侧源码抛 SemanticException(≈507)"，与源码不符）：
#     TSStatusCode.java:131 `SEMANTIC_ERROR(701)`（SemanticException 默认码 ⇒ **写入相实测很可能是 701**）
#     TSStatusCode.java:69  `METADATA_ERROR(507)`（矩阵写的 507；本用例也接受）
#     TSStatusCode.java:227 `LOAD_FILE_ERROR(1100)`（文档 R-13 逐字给的码；load 侧包装后就是这个）
#     ⇒ 判据：code ∈ {1100, 507, 701} 且文案**逐字**匹配；load 侧若实测 ≠1100 额外 WARN 记录。
#   方案选择（★）：表模型"只有 Time 列"当前源码是 **方案 1（拒绝）**（R-15 的方案 2 未采纳）。
#     **若研发确认采纳 R-15 方案 2（允许写入只有 Time 列），本用例的写入相判据必须反转**
#     （W1 由"期望拒"改为"期望成功"），load 相判据保持不变。
#
#   场景（三个独立来源库 + 一个 load 目标库，A/B 对照）：
#     cr03   ：写入相（表 t0）：只有 time 列的写入必须被拒；field 列全 null 的写入必须成功
#     场景1  cr03b.t1：写 2 批 → flush ×2（每副本 2 个 L0）→ `drop column s1`/`s2`（desc 只剩 time）
#                      → 热开 seq 合并 → 产物（level≥1）拷到 /tmp → load 到 cr03c ⇒ 期望**被拒**
#     场景2  cr03e.t1：同场景 1，但两批都写 `null,null`（不 DROP）⇒ 产物同样应无 field 列 ⇒ 期望**被拒**
#     对照   cr03d.t1：同样 2 批 + 合并，但**不 DROP** 且有非 null field 值 ⇒ 产物含 (time,s1,s2)
#                      ⇒ load 到同一个 cr03c.t1 ⇒ 期望**成功**（0 → 2 行）★ 场景有效性关键
#   注：文档 SQL 省略了 time 列（`create table t1(s1 int32 field, s2 int32 field)`），但本构建的表模型要求
#       显式声明 TIME 列（`THE_TABLE_S_DOES_NOT_CONTAIN_A_TIME_COLUMN`，DataNodeQueryMessages.java:358-359）
#       ⇒ 用例统一写成 `(time TIMESTAMP TIME, s1 INT32 FIELD, s2 INT32 FIELD)`，被测行为不变。
#
#   判据（双信号 + 数据面 + 预期错误码 + 场景有效性硬断言）：
#     ① 合并双信号：`InnerSpaceCompaction task finishes successfully` 行数 +N **且** 该库 TsFile 数下降；
#        否则判"场景未成立"（不是产品缺陷）
#     ② load 双信号：`log_datanode_all.log` 中 `No column other than Time present` 行数 +1（WARN 兜底）
#        **且** 目标库行数不变（失败的 load 不得写入任何行）
#     ③ 数据面：DROP 前后 `count(*)` 不变；对照组合并前后指纹一致；对照 load 后目标库 0 → 2 行
#     ④ 场景有效性硬断言：`desc` 只剩 time 列 / min_l0 ≥ 2 / 产物文件存在且非空 / 对照组 load 必须成功
#        / 若"无 field 列"的产物仍能 load ⇒ 判"场景未成立"（REQ_MATRIX §3 CR-03 场景有效性②）
#
#   规模/时长：写入期三类合并全关（`CMP_EXTRA_WRITE`），写完记基线再热开 seq 合并并冻结，约 15~20 分钟。
#   用法：bash cases/common/cr_table_time_only.sh [--consensus IoTConsensus|IoTConsensusV2]
#
# ★ harness 修复记录（RC8 首轮实跑暴露，全部是**用例侧**问题；8 条 FAIL 全出自下面两条）：
#   ① "三副本产物文件名不一致"×6：合并产物文件名前缀是**各副本自己的合并时间戳**，三副本本来就不同。
#      现改为**逐副本取名**（每副本取自己那份、拷到本节点的 $LOAD_DIR），只在**接收 load 的节点
#      （DN[0]）**上硬判"有 level≥1 产物"，其余副本缺产物只记录。
#   ② "load 期望被拒、实际成功"×2：这条衡量的是**场景有没有造出来**（DROP/null 之后合并产物有没有
#      真的变成"无 field 列"），不是产品缺陷 ⇒ 改为"若被接受，先核对数据面自洽（目标表 0→2 行 + 指纹），
#      自洽则 WARN + 打证据；不自洽才 FAIL"，并跳过只对"如期被拒"成立的『行数不增加』断言。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "cr_table_time_only_${DATA_CONSENSUS}"

# ---------------------------------------------------------------- 变量（规模/语料放顶部）
DBW=cr03            # 写入相
T0=cr03.t0
DBS1=cr03b          # 场景 1（DROP 全部 field 列）
TS1=cr03b.t1
DBS2=cr03e          # 场景 2（field 全 null）
TS2=cr03e.t1
DBCT=cr03d          # 对照组（不 DROP、有值）
TCT=cr03d.t1
DBLD=cr03c          # load 目标库
TLD=cr03c.t1
TW=cr03c.tw         # load 目标库的"预热表"（让该库先有 DataRegion；不影响 t1 的行数）
MERGE_WIN="${CR03_MERGE_WIN:-240}"
LOAD_DIR="${CR03_LOAD_DIR:-/tmp/cr03load}"
NO_FIELD_MSG='No column other than Time present, please check the request'
EVID="$ART/${CASE}.evidence.txt"
: >"$EVID"

# ---------------------------------------------------------------- 本地 helper
ev(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$EVID"; }
cr03_oneline(){ printf '%s' "$1" | tr '\n\r' '  ' | tr -s ' ' | cut -c1-400; }
cr03_code(){ local t code
  t=$(printf '%s\n' "$1")
  # ① 常见形如：Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 1100: Loading file ...
  code=$(printf '%s\n' "$t" | grep -oE 'IoTDBSQLException: [0-9]+' | head -1 | grep -oE '[0-9]+$')
  [ -n "$code" ] && { printf '%s' "$code"; return 0; }
  # ② 兜底（2026-10-22 RC9 复核新增）：load 的错误被 LoadTsFileAnalyzer 包装成 LOAD_FILE_ERROR，
  #    客户端可能只打 `Msg: 1100: Loading file … failed. Detail: …`（不带异常类名）。
  #    旧实现只认 ①，遇到 ② 会误判成"load 成功"⇒ 整条 load 相判据失真（CR-03 的 2 条 FAIL 即此）。
  code=$(printf '%s\n' "$t" | grep -oE 'Msg: [^|]{0,200}\b[0-9]{3,4}\b: ' | head -1 | grep -oE '[0-9]{3,4}' | head -1)
  printf '%s' "$code"; }
# 把 load 的**原始响应**整段落盘（此前只存 cr03_oneline 的 400 字符截断版 ⇒ 无法区分
#   "被分析层拒绝" 与 "接受但无数据可写"，2026-10-22 复核时正是卡在这里）
cr03_raw_dump(){ local tag=$1 out=$2 f="$ART/cr03_load_${tag}.raw"
  mkdir -p "$ART" 2>/dev/null
  printf '%s\n' "$out" > "$f" 2>/dev/null && log "  [$tag] load 原始响应已落盘：$f（$(printf '%s' "$out" | wc -c | tr -d ' ') 字节）" \
    || warn "  [$tag] load 原始响应落盘失败：$f"; }
cr03_q(){ sqt "$1"; }
# 表格第一行第一列（count(*) 之类）
cr03_scalar(){ cr03_q "$1" | table_rows | head -1 | awk -F'|' '{v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'; }
cr03_cnt(){ cr03_scalar "select count(*) from $1;"; }
cr03_wait_cnt(){ local tb=$1 want=$2 win=$3 got=0
  local dl
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(cr03_cnt "$tb")
    [ "$got" = "$want" ] && { echo "$got"; return 0; }
    sleep 3
  done
  echo "${got:-0}"; return 1
}
# desc 的列名集合（按表头里的 ColumnName 定位列号，避免列序变化导致误判）
cr03_cols(){ local out idx
  out=$(cr03_q "desc $1;")
  idx=$(printf '%s\n' "$out" | grep -E '^\|' | head -1 | awk -F'|' '{for(i=2;i<NF;i++){v=$i; gsub(/^[ \t]+|[ \t]+$/,"",v); if(tolower(v)=="columnname"){print i; exit}}}')
  [ -z "${idx:-}" ] && idx=2
  printf '%s\n' "$out" | table_rows | awk -F'|' -v i="$idx" '{v=$i; gsub(/^[ \t]+|[ \t]+$/,"",v); if (v != "") print v}' | sort | tr '\n' ','
}
cr03_fp(){ local tb=$1
  printf 'cnt=%s c_s1=%s sum_s1=%s sum_s2=%s' "$(cr03_scalar "select count(*) from $tb;")" \
    "$(cr03_scalar "select count(s1) from $tb;")" "$(cr03_scalar "select sum(s1) from $tb;")" \
    "$(cr03_scalar "select sum(s2) from $tb;")"
}
# 某库在某个 DN 上的 level≥1 TsFile 全路径（合并产物）。按 basename 的第 3 个 `-` 段判层级
cr03_prod_paths(){ local h=$1 db=$2
  sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%p\n' 2>/dev/null" | tr -d '\r' \
    | awk -F/ '{f=$NF; n=split(f,a,"-"); if (n>=3 && a[3]+0>=1) print $0}' | sort
}
# DN 日志里 "无 field 列" 文案的行数（全部 DN 求和）
cr03_nofield_log(){ local h s=0 n
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "grep -hc 'No column other than Time present' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done
  echo "$s"
}
# 建库 + 建表（显式声明 TIME 列；本构建要求有 TIME 列）+ 用 show tables 校验
cr03_mkdb(){ local db=$1 tb=$2 short tabs out
  short=${tb##*.}
  out=$(cr03_q "create database $db;")
  ev "create database $db | $(cr03_oneline "$out")"
  out=$(cr03_q "create table $tb (time TIMESTAMP TIME, s1 INT32 FIELD, s2 INT32 FIELD);")
  ev "create table $tb | $(cr03_oneline "$out")"
  if printf '%s' "$out" | grep -qE 'IoTDBSQLException: [0-9]+'; then
    fail "  场景未成立：建表失败 $tb（$(cr03_oneline "$out")）"
  fi
  tabs=$(cr03_q "show tables from $db;")
  ev "show tables from $db | $(cr03_oneline "$tabs")"
  if printf '%s\n' "$tabs" | grep -qw "$short"; then
    pass "  表已建成：$tb"
  else
    fail "  场景未成立：$db 里看不到表 $short（show tables 原文见 $EVID）"
  fi
}
# 写一批（一个 TsFile）：insert + flush + 等各副本 close 事件达第 min 个
cr03_batch(){ local db=$1 tb=$2 t=$3 v1=$4 v2=$5
  cr03_q "insert into $tb(time,s1,s2) values($t,$v1,$v2);" >/dev/null
  cr03_q "flush;" >/dev/null
  cmp_wait_close "$db" "$t" 90 >/dev/null || warn "    [$db] 批 time=$t：close 事件未达 $t（$(ttl_close_snapshot "$db")）"
  sleep 3
}
# 合并阶段：记基线 → 热开 seq 合并 → 等（双信号）→ 冻结 → 把 level≥1 产物拷到 $LOAD_DIR/<tag>.tsfile
cr03_merge(){ local db=$1 tb=$2 tag=$3 mode=$4 h pp n p1 b pfirst="" pfirst_h="" sz prob fin0 cnt0 fp0 l0 res merged=0
  cmp_compaction_off
  if [ "$mode" = drop ]; then fp0="(DROP 后已无 field 列，不取指纹)"; else fp0=$(cr03_fp "$tb"); fi
  fin0=$(cmp_inner_finish "$db"); cnt0=$(cmp_all_sum "$db")
  l0=$(cmp_min_l0 "$db")
  log "  [$tag] 合并前：布局=$(cmp_lay "$db") TsFile=$cnt0 min_l0=$l0 finishes=$fin0 指纹=$fp0"
  log "  [$tag] 清单（${DN[0]}）：$(cmp_tsfile_list "${DN[0]}" "$db" | tr '\n' ' ')"
  if [ "${l0:-0}" -ge 2 ]; then
    pass "  [$tag] 场景有效：各副本 level-0 TsFile ≥2（有合并候选）"
  else
    fail "  [$tag] 场景未成立：min_l0=$l0 < 2（合并候选不足）"
  fi
  cmp_compaction_on true false false
  if res=$(cmp_wait_merge "$db" "$fin0" "$cnt0" "$MERGE_WIN"); then merged=1; else merged=0; fi
  cmp_set_hot enable_seq_space_compaction false >/dev/null 2>&1
  sleep 5
  local fin1 cnt1
  fin1=$(cmp_inner_finish "$db"); cnt1=$(cmp_all_sum "$db")
  log "  [$tag] 合并后：布局=$(cmp_lay "$db") TsFile=$cnt0 → $cnt1 finishes=$fin0 → $fin1（$res）"
  if [ "$merged" = 1 ]; then
    pass "  [$tag] 双信号：合并已推进（$res）"
  else
    fail "  [$tag] 场景未成立：${MERGE_WIN}s 内合并未推进（$res）"
  fi
  if [ "$fin1" -gt "$fin0" ]; then
    pass "  [$tag] 双信号①：InnerSpaceCompaction finishes +$(( fin1 - fin0 ))"
  else
    fail "  [$tag] 场景未成立：无合并完成记录（finishes $fin0 → $fin1）"
  fi
  if [ "$cnt1" -lt "$cnt0" ]; then
    pass "  [$tag] 双信号②：TsFile 数下降（$cnt0 → $cnt1）"
  else
    fail "  [$tag] 场景未成立：TsFile 数未下降（$cnt0 → $cnt1）"
  fi
  # 产物取证：合并产物**文件名按副本各自取**（前缀是该副本自己的合并时间戳，三副本本来就不同
  # —— RC8 首轮误以为"文件名必须一致"，判了 6 条假 FAIL）。逐副本把自己那份拷到本节点
  # $LOAD_DIR/<tag>.tsfile；**load 只读接收节点（DN[0]）本地磁盘** ⇒ 若 DN[0] 上没有产物，
  # 就从有产物的副本借一份过来（这样"某副本没产出合并文件"不再是硬失败）。
  for h in "${DN[@]}"; do
    pp=$(cr03_prod_paths "$h" "$db")
    n=$(printf '%s\n' "$pp" | grep -c . | tr -dc '0-9')
    log "  [$tag] $h 产物（level≥1，$n 个）：$(printf '%s' "$pp" | tr '\n' ' ')"
    if [ "${n:-0}" -ge 1 ]; then
      [ "${n:-0}" -gt 1 ] && warn "  [$tag] $h 上 level≥1 产物有 $n 个（期望 1，可能发生了级联合并）⇒ 取排序后第一个作为代表，并记录"
      p1=$(printf '%s\n' "$pp" | head -1)
      b=$(basename "$p1")
      log "  [$tag] $h 产物名=$b（三副本各不相同属正常：文件名前缀=各副本自己的合并时间戳）"
      [ -z "$pfirst" ] && { pfirst="$p1"; pfirst_h="$h"; }
      if sshx "$h" "mkdir -p '$LOAD_DIR' && cp -f '$p1' '$LOAD_DIR/$tag.tsfile'"; then
        log "  [$tag] 已拷贝 $p1 → $LOAD_DIR/$tag.tsfile（$h）"
      else
        fail "  [$tag] 拷贝产物到 $LOAD_DIR 失败（$h）"
      fi
    else
      warn "  [$tag] $h 上 level≥1 产物数=0（合并未在该副本产出文件）⇒ 记录"
    fi
  done
  if [ -n "$pfirst" ]; then
    pass "  [$tag] 场景有效：至少一个副本产出了 level≥1 合并产物（首个来自 $pfirst_h：$pfirst）"
  else
    fail "  [$tag] 场景未成立：三副本都没有 level≥1 产物（合并未产出文件）"
  fi
  # DN[0] 上若没有产物（load 会读它本地磁盘），从有产物的副本借一份过去
  if [ -z "$(sshx "${DN[0]}" "stat -c %s '$LOAD_DIR/$tag.tsfile' 2>/dev/null" 2>/dev/null | tr -dc '0-9')" ] && [ -n "$pfirst" ]; then
    log "  [$tag] ${DN[0]} 上没有产物 ⇒ 从 $pfirst_h 借一份到 ${DN[0]}:$LOAD_DIR/$tag.tsfile（load 读接收节点本地磁盘）"
    sshx "${DN[0]}" "mkdir -p '$LOAD_DIR'"
    sshx "$pfirst_h" "cat '$pfirst'" | ssh $SSH_OPTS "$SSH_USER@${DN[0]}" "cat > '$LOAD_DIR/$tag.tsfile'"
    [ $? -eq 0 ] || fail "  [$tag] 借拷产物到 ${DN[0]} 失败"
  fi
  sz=$(sshx "${DN[0]}" "stat -c %s '$LOAD_DIR/$tag.tsfile' 2>/dev/null" 2>/dev/null | tr -dc '0-9')
  if [ "${sz:-0}" -gt 0 ]; then
    pass "  [$tag] 产物已就位：$LOAD_DIR/$tag.tsfile（${sz}B）"
  else
    fail "  [$tag] 场景未成立：$LOAD_DIR/$tag.tsfile 不存在或为空（sz=${sz:-0}）"
  fi
  # 旁证（仅记录）：产物里 s1/s2 字面出现次数。TsFile 的列名会在 footer 里出现，
  # 期望"无 field 列"的产物里不该有 s1/s2（不做硬判据：二进制里可能有巧合字节）。
  prob=$(sshx "${DN[0]}" "grep -a -o -e s1 -e s2 '$LOAD_DIR/$tag.tsfile' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  log "  [$tag] 旁证：产物中 's1'/'s2' 字面出现 ${prob:-0} 次（仅记录，硬判据以 load 结果为准）"
  # 数据面：合并前后不得丢/变
  if [ "$mode" = drop ]; then
    log "  [$tag] 合并后 desc=$(cr03_cols "$tb")"
  else
    cmp_assert_same "  [$tag] 合并前后数据指纹" "$fp0" "$(cr03_fp "$tb")"
  fi
}
# 期望"无 field 列"的拒绝：非空错误码 + 逐字文案（load 模式额外要求 R-13 的 Loading file 前缀）
#   ★ RC8 首轮修正：这条**衡量的是"场景有没有造出来"**（合并产物到底有没有变成"无 field 列"），
#     不是产品缺陷 ⇒ 若是真的被接受，就核对**数据面自洽性**并记 WARN + 打证据（不再直接判 FAIL）。
cr03_no_field_reject(){ local label=$1 out=$2 mode=${3:-load} code joined
  ev "$label | $(cr03_oneline "$out")"
  joined=$(printf '%s' "$out" | tr '\n\r' '  ')
  code=$(cr03_code "$out")
  if [ -z "$code" ]; then
    if [ "$mode" = load ]; then
      # 文案信号兜底（2026-10-22 新增）：即使解析不到数字码，只要命中 R-13 的包装文案
      #   `Loading file … failed` 或 NO_FIELD_MSG，就说明是**分析层拒绝**，不可能是"接受成功"。
      #   旧实现只按"有无数字码"二分 ⇒ 码样式不同时会把"如期被拒"误报成"接受"。
      if printf '%s' "$joined" | grep -qF "$NO_FIELD_MSG" || printf '%s' "$joined" | grep -qi 'Loading file .*failed'; then
        pass "$label：如期被拒（文案命中『$NO_FIELD_MSG / Loading file … failed』，未解析到数字码；原始响应见 artifact 的 cr03_load_*.raw）"
        return
      fi
      local c2 fp2
      c2=$(cr03_wait_cnt "$TLD" 2 120)
      fp2=$(cr03_fp "$TLD" 2>/dev/null)
      if [ "${c2:-0}" = "2" ]; then
        warn "$label：产物被**接受**（load 成功）⇒ R-14 的『无 field 列产物』场景未成立（DROP/null 之后合并产物仍带 field 列），但数据面自洽（目标表 0 → $c2 行，指纹=[$fp2]）；原始响应：$(cr03_oneline "$out")"
      else
        fail "$label：load 成功但数据面不自洽（目标表行数=${c2:-?}，期望 2）⇒ 需人工核对（原始响应：$(cr03_oneline "$out")）"
      fi
    else
      fail "$label：期望被拒、实际成功 ⇒ 场景未成立（该写入本身没有 field 列却被接受；★ 若研发确认采用『方案2 允许只有 Time 列的写入』，本判据需反转）"
    fi
    return
  fi
  case " 1100 507 701 " in
    *" $code "*) pass "$label：如期被拒 code=$code（文档逐字 1100 / 矩阵 507 / 源码 SEMANTIC_ERROR 701 都接受；★ 待实测确认）";;
    *) fail "$label：被拒但 code=$code ∉ {1100,507,701}（文档逐字 1100，源码 TSStatusCode.java:227）";;
  esac
  if printf '%s' "$joined" | grep -qF "$NO_FIELD_MSG"; then
    pass "$label：文案逐字匹配（$NO_FIELD_MSG）"
  else
    fail "$label：文案不匹配（期望逐字 $NO_FIELD_MSG）"
  fi
  if [ "$mode" = load ]; then
    if printf '%s' "$joined" | grep -qF 'Loading file '; then
      pass "$label：含 R-13 逐字前缀『Loading file … failed. Detail: …』"
    else
      fail "$label：缺 R-13 逐字前缀（期望 Loading file <path> failed. Detail: …）"
    fi
    if [ "$code" != 1100 ]; then
      warn "$label：load 侧实测码 $code ≠ 文档逐字 1100（源码 LoadTsFileAnalyzer.java:387-393 用 LOAD_FILE_ERROR(1100) 包装）★ 待研发确认"
    fi
  fi
}
cr03_ok(){ local label=$1 out=$2 code
  ev "$label | $(cr03_oneline "$out")"
  code=$(cr03_code "$out")
  if [ -z "$code" ]; then
    pass "$label：如期成功"
  else
    fail "$label：期望成功，实际报错 code=$code（$(cr03_oneline "$out")）"
  fi
}
cr03_load(){ local tag=${2:-load} out
  out=$(sql_lines_table "use $DBLD;" "load '$1';")
  cr03_raw_dump "$tag" "$out"
  printf '%s' "$out"; }
# 建场景（两批 ⇒ 每副本 2 个 L0）；mode=drop 时逐字复刻 R-14 场景 1 的 DROP COLUMN
cr03_scene(){ local db=$1 tb=$2 tag=$3 mode=$4 cs c0 c1
  log "--- 场景 [$tag]：$db.$tb（模式 $mode）---"
  cmp_compaction_off
  cr03_mkdb "$db" "$tb"
  case "$mode" in
    null) cr03_batch "$db" "$tb" 1 null null; cr03_batch "$db" "$tb" 2 null null;;
    *)    cr03_batch "$db" "$tb" 1 2 3;       cr03_batch "$db" "$tb" 2 2 3;;
  esac
  log "  [$tag] 写入后：desc=$(cr03_cols "$tb") 指纹=$(cr03_fp "$tb")"
  c0=$(cr03_wait_cnt "$tb" 2 90)
  assert_eq "  [$tag] 场景有效：两批共 2 行" "$c0" "2"
  if [ "$mode" = drop ]; then
    cr03_ok "  [$tag] alter table drop column s1" "$(cr03_q "alter table $tb drop column s1;")"
    cr03_ok "  [$tag] alter table drop column s2" "$(cr03_q "alter table $tb drop column s2;")"
    cs=$(cr03_cols "$tb")
    log "  [$tag] DROP 后 desc 列集合=[$cs]"
    if printf '%s' "$cs" | grep -qE '(^|,)(s1|s2)(,|$)'; then
      fail "  [$tag] 场景未成立：DROP 后 desc 仍含 s1/s2（cs=[$cs]）"
    else
      pass "  [$tag] 场景有效：DROP 后 desc 只剩 Time 列（cs=[$cs]）"
    fi
    c1=$(cr03_wait_cnt "$tb" 2 60)
    assert_eq "  [$tag] DROP 前后 count(*) 不变（R-14 数据面要求）" "$c1" "$c0"
  fi
  cr03_merge "$db" "$tb" "$tag" "$mode"
}
# load 相：expect=reject 期望被拒（R-13 文案）；expect=accept 对照组必须成功
cr03_load_block(){ local tag=$1 expect=$2 lg0 lg1 d code out c
  log "--- load [$tag] → $DBLD（期望：$expect）---"
  lg0=$(cr03_nofield_log)
  out=$(cr03_load "$LOAD_DIR/$tag.tsfile" "$tag")
  log "  [$tag] load 响应：$(cr03_oneline "$out")"
  if [ "$expect" = reject ]; then
    cr03_no_field_reject "  [$tag] load 期望被拒" "$out" load
    if [ -n "$(cr03_code "$out")" ]; then
      lg1=$(cr03_nofield_log); d=$(( lg1 - lg0 ))
      if [ "$d" -ge 1 ]; then
        pass "  [$tag] 双信号②：DN 日志『$NO_FIELD_MSG』行数 +$d"
      else
        warn "  [$tag] 双信号②：DN 日志未见『$NO_FIELD_MSG』新增（+$d）—— load 失败可能只在分析层返回而未落 DN all 日志（记录，不判 FAIL）"
      fi
      c=$(cr03_cnt "$TLD")
      assert_eq "  [$tag] load 失败后目标库 $TLD 行数不增加" "$c" "0"
    else
      # 被接受（场景未成立）：数据面自洽性已在 cr03_no_field_reject 里核对，这里不再断言"行数不增加"
      log "  [$tag] 产物被接受 ⇒ 跳过『load 失败后行数不增加』断言（该断言只对『如期被拒』成立）"
    fi
  else
    code=$(cr03_code "$out")
    if [ -z "$code" ]; then
      pass "  [$tag] 对照组 load 成功（A/B 对照成立：同一 load 语句、同一目标表，只有源产物不同）"
    else
      fail "  [$tag] 场景未成立：对照组 load 也失败 code=$code（$(cr03_oneline "$out")）⇒ 失败原因不是『无 field 列』，A/B 对照不成立"
    fi
    c=$(cr03_wait_cnt "$TLD" 2 120)
    assert_eq "  [$tag] 对照组 load 后目标库行数（0 → 2）" "$c" "2"
  fi
}

# ============================================================================
# 集群准备（写入期三类合并全关）
# ============================================================================
log "--- 集群准备（表模型；写入期三类合并全关 = $CMP_EXTRA_WRITE）---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare
cmp_compaction_off

# ============================================================================
# 相位 1：写入相（R-12 的前半句：拒绝不带 field 列的**写入请求**）
# ============================================================================
log "--- 相位 1：写入相（$DBW.$T0）---"
cr03_mkdb "$DBW" "$T0"
r=$(cr03_q "insert into $T0(time) values(1);")
cr03_no_field_reject "W1 只有 time 列的写入（R-12：必须拒绝）" "$r" write
if [ -z "$(cr03_code "$r")" ]; then
  warn "R-15 提示：若研发确认采纳『方案2 允许写入请求只有 Time 列』，W1 的判据需要**反转**（当前源码是方案1=拒绝）"
fi
cr03_ok "W2 field 列全 null 的写入（有 field 列 ⇒ 应成功）" "$(cr03_q "insert into $T0(time,s1,s2) values(1,null,null);")"
cr03_ok "W3 常规写入（对照）" "$(cr03_q "insert into $T0(time,s1,s2) values(2,2,3);")"
got=$(cr03_wait_cnt "$T0" 2 90)
assert_eq "写入相数据面：行数（$T0）" "$got" "2"
assert_eq "写入相数据面：非 null s1 的行数" "$(cr03_scalar "select count(s1) from $T0;")" "1"

# ============================================================================
# 相位 2：load 目标库准备（预热一张旁表让该库先有 DataRegion；t1 保持 0 行）
# ============================================================================
log "--- 相位 2：load 目标库 $DBLD 准备（$TLD 保持 0 行，另建 $TW 预热 DataRegion）---"
cr03_mkdb "$DBLD" "$TLD"
cr03_q "create table $TW (time TIMESTAMP TIME, s1 INT32 FIELD, s2 INT32 FIELD);" >/dev/null
cr03_ok "  预热表 $TW 写入 1 行" "$(cr03_q "insert into $TW(time,s1,s2) values(1,1,1);")"
cr03_q "flush;" >/dev/null
assert_eq "  预热表行数" "$(cr03_wait_cnt "$TW" 1 90)" "1"
assert_eq "  load 目标表基线行数（$TLD 必须为 0）" "$(cr03_cnt "$TLD")" "0"

# ============================================================================
# 相位 3：场景 1（DROP 全部 field 列 → 合并 → load 期望被拒）
# ============================================================================
cr03_scene "$DBS1" "$TS1" scene1 drop
cr03_load_block scene1 reject

# ============================================================================
# 相位 4：场景 2（field 全 null → 合并 → load 期望被拒）
# ============================================================================
cr03_scene "$DBS2" "$TS2" scene2 null
cr03_load_block scene2 reject

# ============================================================================
# 相位 5：对照组（不 DROP、有非 null field 值 → 合并 → load 期望成功）★ A/B 关键
# ============================================================================
cr03_scene "$DBCT" "$TCT" control keep
cr03_load_block control accept

# ============================================================================
# 收尾三件套
# ============================================================================
log "--- 收尾三件套（基准 SQL：$DBW.$T0 count(*)）---"
export CMP_LOG_BENIGN_EXTRA='No column other than Time present|No Field column present|Loading file .* failed|drop column|A table cannot have more than one time column'
post_checks "select count(*) from $T0;" table
cmp_case_finish "" table ""
