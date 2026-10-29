#!/bin/bash
# ============================================================================
# CO-40 合并执行的临时态与恢复四分支 + 残留文件/句柄
#        覆盖 D3-1 / D3-2 / D3-3 / D3-4 / D3-5 / D3-7 / D3-9
#        （官方 MG-P10、MG-P15、MG-P16、MG-P21、FC-08）
#
# 为什么必须有这条：合并的"中间态"（临时目标文件、源 mods 迁移、合并日志）
#   与进程被强杀后的恢复分支（回滚 / 重做 / 日志不完整 / 空目标文件）是合并正确性里
#   最容易漏测、也最容易出数据损坏的路径。CO-29 只断言"重启后无残留 + 三副本一致"，
#   没有分支级断言，也没有 mods 迁移 / 孤儿 mods / 已删句柄的判据
#   （见 docs/OFFICIAL_COVERAGE.md §5 第 16~18、35 项）。
#
# ---------------------------------------------------------------------------
# 【首轮复跑验收点（2026-10-16 rc7 V1/V2 各 4 条 FAIL 定性为**用例侧指纹 bug** 后的修复，见 _scratch/CO384041_TRIAGE.md §2.1）】
#   ① `fail_flag=0`；4 处"数据指纹"断言（`cmp_assert_same` 调用点）的 `rows/sum2/sum3` 必须与基线逐字节一致，
#      `head_md5` 只作附加证据（修复前它 8 次测量里每次都不同 ⇒ 4 条同为假 FAIL）。
#   ② 恢复分支判据不得回退（本轮实测基线，全部 PASS）：`all source files exists, delete all target files`
#      回滚分支、`incomplete log file, abort recover` 中止分支、D3-7 的 `3/3` 空目标文件清理、
#      孤儿 `*.mods2=0`、临时文件=0、`无卡死合并线程`。
#   ③ 收尾三件套（sync lag 归零 / 逐个停 DN 副本一致性 / CN+DN 日志异常）必须全 PASS。
#
# ---------------------------------------------------------------------------
# 【2026-10-15 首跑（RC7 v20121rc7_1014_7c61428，fail=5）复盘 —— 全部是用例侧构造缺陷】
#
# 首跑实际数字（results/CO-40_20261015_164726.out + DN 日志）：
#   * 相1 `root.corec-3`：`17:12:04,596 task starts with 5 files, total file size 7 MB`
#     → `17:12:11,268 finishes successfully, time cost is 6.67 s, compaction speed 1.08 MB/s`
#     ⇒ **合并窗口只有 6.67s**（被 1MB/s 读限流卡住，读限流是保证窗口的关键）。
#   * 脚本在 17:12:02 探到 `task starts`（0→6，计数=3 任务×2 个日志文件），
#     随后串行做了 3 个 `cmp_*` 取证 helper（每个 = 3 次 ssh，共 9 次串行 ssh）→ 17:12:05 才发起 kill，
#     **merge 恰在 17:12:05 前提交**（脚本日志：注入前 文件数=15 finishes=6；重启后立刻 文件数=5）
#     ⇒ 注入晚了约 1s，"合并中崩溃"没构造出来。
#   * `MODS0=0`：**用例 glob 写错**。RC7 的删除标记文件是 `<name>.tsfile.mods2`
#     （源码 `ModificationFile.FILE_SUFFIX=".mods2"`），而用例查的是 `-name '*.mods'`（永远 0）。
#     同一次运行的 D3-1 采样里三个 DN 都打印了 `...-1-0-0.tsfile.mods2`（34 字节）⇒ DELETE 确实造出了 mods。
#   * `[D3-4] 停机时没有 .compaction.log 可清空（0）`：**用例 glob 写错**（RC7 的合并日志是
#     `<target>.inner-compaction.log`，源码 `CompactionLogger.INNER_COMPACTION_LOG_NAME_SUFFIX`）
#     ＋ 合并已提交（成功路径 `finally` 会删日志）。
#   * 两条「240s 内未完成合并」是**连带失败**：注入未生效 ⇒ 无残留、无新候选 ⇒ 恢复分支根本没执行。
#
# 本文件的修法（判据取向遵循 docs/OFFICIAL_COVERAGE.md §4.2「诚实标注」+ §5 防误判）：
#   ① **注入时机硬校验 + 把取证压到一次往返**：改成"3 个 DN 并行、一次 ssh 同时取回
#      task starts / finishes / TsFile 数 / 合并日志数 / 临时目标文件数"（原来 9 次串行 ssh 耗掉整个窗口），
#      门成立 → 立刻并行 `kill -9`（`pkill -9`，不再走 lsof 的 `stop-datanode.sh`）。决策延迟 ≈1s。
#   ② **kill 之后立刻量"冻结的崩溃态"**（重启前磁盘不再变化）⇒ D3-1「进行中存在临时目标文件」、
#      D3-4 的「停机窗口里确有合并日志」都变成**硬断言**，不再靠抢时序采样。
#   ③ **分支级判据（有源码出处）**：恢复日志里必须有
#      `[Compaction][Recover] all source files exists, delete all target files.`（D3-5 回滚分支，
#      `CompactionRecoverTask.handleWithAllSourceFilesExist`），或不完整日志分支的
#      `incomplete log file, abort recover`（D3-4）＋ `Recover compaction successfully, delete log file`；
#      不得出现 `Failed to recover compaction`。
#   ④ **分支解耦**：相内先判"注入是否生效"，不生效就 `WARN + 记录` 并**跳过该相后续分支判据**
#      （不再把连带失败算成产品问题）；只有"注入确实生效 ∧ 恢复行为与源码不符"才 FAIL。
#   ⑤ **不可观测/不可构造项一律 WARN + 记录实测**：D3-4 分支下 `.inner`/`.compaction.mods2` 残留
#      （源码上该分支提前 return，不清理目标态文件 ⇒ 不作硬判据）、合并后目标 mods 是否保留等。
#   ⑥ 删掉 `ensure_closed`（本用例里它必然空转：每批已 flush 过，再 flush 不会产生新的
#      `Async close tsfile` 事件 ⇒ 每次都耗满 3×30s 且必然 WARN；逐批的 `cmp_wait_close` 才是有效信号）。
#
# 相 1 root.corec  ：1 个"被删预批"（DELETE 造 .mods2）+ N 批 TEXT 1KB 追加
#                    → 合并**进行中**在 3 个 DN 上同时 kill -9 → 重启
#                    ⇒ D3-5（源文件都在 ⇒ 回滚删目标）＋ D3-1 / D3-2 / D3-3
# 相 2 root.corec2 ：合并进行中 kill -9 → 停机窗口里把该库 `*compaction.log` **清空**
#                    （模拟"日志不完整"）→ 重启 ⇒ D3-4（abort recover、不报错、不阻塞后续合并）
# 相 3 root.corec3 ：先正常合并完成，再在相 2 的同一个停机窗口里于该库真实产物旁造一个
#                    **0 字节 `.tsfile`**（空目标文件）→ 重启 ⇒ D3-7（空目标文件被清理）
#
# 【RC7 版本差异（实测 + 源码）——写判据前必读】
#   * mods 文件：`<tsfile>.mods2`（`ModificationFile.FILE_SUFFIX`）、合并中间态 `<target>.compaction.mods2`
#     （`COMPACTION_FILE_SUFFIX`）；**不存在 `*.mods`** ⇒ lib/cmp.sh 的 `cmp_mods_*`（按 `*.mods` 匹配）
#     在本用例里恒为 0，是 **helper glob 与 RC7 不一致**，不是产品行为。本文件自带按 `.mods2` 匹配的 helper。
#   * 合并日志：`<target>.inner-compaction.log`；**不存在 `*.compaction.log`** ⇒ `cmp_tmp_leftover`
#     （按 `*.compaction.log`/`*.tmp`/`*.merge` 匹配）也恒为 0（原判据是空断言）。本文件自带 `co40_clog_*`。
#   * 临时目标文件：`<target>.inner`（`IoTDBConstant.INNER_COMPACTION_TMP_FILE_SUFFIX=".inner"`）。
#   * 限流键是 **int**（`IoTDBConfig.compactionWriteThroughputMbPerSec=16` / `Read=0`），
#     最小正值为 1 MB/s ⇒ 窗口 ≈ 源字节 / 1MB/s（实测 7MB → 6.67s），无法再用调小限流拉长窗口。
#
# 判据（每段都有 pass/fail 行）：
#   ① D3-1：kill -9 后（冻结态）该库**存在**不以 `.tsfile` 结尾的临时目标文件（`.inner`）；恢复后必须 == 0；
#   ② D3-2/3-3：MODS0>0（场景有效性）⇒ 恢复后无孤儿 `*.mods2`（含合并中间态 `.compaction.mods2`）、
#                被删行不复活（行数不变）；
#   ③ D3-5/3-9：恢复日志出现"all source files exists, delete all target files."（回滚分支）⇒
#                文件数回到崩溃前基线、临时文件/合并日志/compaction mods 归零、数据指纹与崩溃前完全一致，
#                之后重新选文件并跑完合并（出现新的 task starts ＝ MG-P21「不续合」）；
#   ④ D3-4：停机窗口内先证"确有合并日志"（硬）→ 清空 → 重启后必须出现 "incomplete log file, abort recover"
#                ＋ "Recover compaction successfully, delete log file"、不得出现 "Failed to recover compaction"、
#                日志被删、数据不变、后续仍能合并完成；
#   ⑤ D3-7：0 字节 `.tsfile` 在重启后被清理，且该库布局/数据不变；
#   ⑥ 句柄：合并完成 +60s 后每个 DN 的"已删文件句柄"≤ 基线 +2，且 +30s 与 +60s 相同、fd 总数不增长；
#   ⑦ 三副本一致 + cmp_stuck_sum=0 + 收尾三件套。
#
# 时长：≈21~24 分钟（两次"3 DN 同时 kill -9 + 重启" + 收尾逐个停/起 DN）。
#   ⚠️ 首跑 2003s 里有 ≈423s 是纯空转（ensure_closed 333s + MODS 轮询 90s）＋480s 是场景未成立时的连带等待。
# 可调：C40_ROWS / C40_BATCHES / C40_BATCHES2 / C40_INJ_ATT（注入尝试次数，默认 2）。
# 用法： bash co_recovery_branches.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_recovery_branches_${DATA_CONSENSUS}"

DB=root.corec          # 相 1：kill -9 → 回滚（D3-5）+ 临时态/mods（D3-1/3-2/3-3）
DB2=root.corec2        # 相 2：kill -9 + 清空合并日志（D3-4）
DB3=root.corec3        # 相 3：0 字节空目标文件（D3-7）
DEV=d1
ROWS=${C40_ROWS:-1500}            # 每批行数（每行 1KB TEXT ⇒ 约 1.5MB/批）
BATCHES=${C40_BATCHES:-4}         # 相 1 的追加批数（另有 1 个"被删预批"）⇒ 5 个 L0 ≈ 7MB ⇒ 窗口 ≥6.5s
BATCHES2=${C40_BATCHES2:-4}       # 相 2 批数（4 个 L0 ≈ 5MB ⇒ 窗口 ≥5s）
BATCHES3=${C40_BATCHES3:-2}       # 相 3 批数
PER=${C40_PER:-200}               # 每条 INSERT 的行数
DEL_ROWS=${C40_DEL_ROWS:-500}     # 预批里被 DELETE 掉的行数（造 .mods2）
WIN=${C40_WIN_SEC:-200}           # 等合并/恢复收敛的窗口（秒）
REWIN=${C40_REWIN_SEC:-150}       # 等"恢复后重新选文件并跑完"的窗口（秒）
INJ_WIN=${C40_INJ_WIN:-90}        # 单次注入尝试内等"合并进行中"的窗口（秒）
INJ_ATT=${C40_INJ_ATT:-2}         # 注入尝试次数（第一次没抓住就补一批候选再试一次）
PAYLOAD=$(printf 'q%.0s' $(seq 1 1000))
# 本用例**故意** kill -9 三个 DN ⇒ 停机期间的常见噪声不判为异常（恢复本身仍按硬判据看）
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|Compaction task (is )?killed'

# ---------------------------------------------------------------------------
# 观测 helper（⚠️ 后缀按 RC7 实测：`.mods2` / `*compaction.log` / `.inner`）
# ---------------------------------------------------------------------------
# "不以 .tsfile 结尾"的临时目标文件（D3-1 的 `.inner`）；排除 .mods2/.resource/合并日志
co40_temp_list(){ local h=$1 db=$2
  sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -type f ! -name '*.tsfile' ! -name '*.mods2' ! -name '*.resource' ! -name '*compaction.log' -printf '%s %p\n' 2>/dev/null | sort" 2>/dev/null; }
co40_temp_cnt(){ local h=$1 db=$2 n
  n=$(co40_temp_list "$h" "$db" | grep -c .)
  echo "${n:-0}"; }
co40_temp_sum(){ local h s=0
  for h in "${DN[@]}"; do s=$(( s + $(co40_temp_cnt "$h" "$1") )); done; echo "$s"; }
# mods 文件（RC7：`<tsfile>.mods2` / `<target>.compaction.mods2`；**没有** `*.mods`）
co40_mods_list(){ local h=$1 db=$2
  sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.mods2' -printf '%s %p\n' 2>/dev/null | sort" 2>/dev/null; }
co40_mods_cnt(){ local h=$1 db=$2 n
  n=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.mods2' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${n:-0}"; }
co40_mods_sum(){ local h s=0
  for h in "${DN[@]}"; do s=$(( s + $(co40_mods_cnt "$h" "$1") )); done; echo "$s"; }
# 孤儿 mods2：没有同名兄弟文件的 mods2（`<t>.tsfile.mods2` 的兄弟是 `<t>.tsfile`；
# 合并中间态 `<t>.compaction.mods2` 的兄弟是 `<t>.compaction`（不存在）⇒ 一并算成"残留"）
co40_orphan_mods(){ local h=$1 db=$2 n
  n=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.mods2' 2>/dev/null | while read -r m; do [ -f \"\${m%.mods2}\" ] || echo x; done | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${n:-0}"; }
co40_orphan_mods_sum(){ local h s=0
  for h in "${DN[@]}"; do s=$(( s + $(co40_orphan_mods "$h" "$1") )); done; echo "$s"; }
# 合并日志（RC7：`<target>.inner-compaction.log`）
co40_clog_list(){ local h=$1 db=$2
  sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*compaction.log' -printf '%s %p\n' 2>/dev/null | sort" 2>/dev/null; }
co40_clog_cnt(){ local h=$1 db=$2 n
  n=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*compaction.log' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9')
  echo "${n:-0}"; }
co40_clog_sum(){ local h s=0
  for h in "${DN[@]}"; do s=$(( s + $(co40_clog_cnt "$h" "$1") )); done; echo "$s"; }
# 把该库（停机窗口内）的合并日志原文抓成证据（含恢复分支要用到的 source/target/stage 行）
co40_clog_dump(){ local db=$1 out=$2 h
  : >"$out"
  for h in "${DN[@]}"; do
    printf '#### %s\n' "$h" >>"$out"
    sshx "$h" "for f in \$(find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*compaction.log' 2>/dev/null); do echo \"--- \$f\"; cat \"\$f\"; done" >>"$out" 2>/dev/null
  done
  log "  [$db] 合并日志证据已存 $out（$(grep -c . "$out") 行）"; }
# 清空（截断为 0 字节）某库的全部合并日志 —— 模拟"日志不完整"；回显被清空的个数
co40_clog_truncate(){ local db=$1 h c n=0
  for h in "${DN[@]}"; do
    c=$(sshx "$h" "n=0; for f in \$(find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*compaction.log' 2>/dev/null); do : > \"\$f\" && n=\$((n+1)); done; echo \$n" 2>/dev/null | tr -dc '0-9')
    n=$(( n + ${c:-0} ))
  done
  echo "$n"; }
# 恢复日志行数（有源码出处的分支标记；命中两个日志文件 ⇒ 值会 ×2，只看 >0 / ==0）
#   用法： co40_recover_cnt <db> <grep -F 的固定串>
#   ⚠️ 归属过滤要兼容两种前缀：CompactionRecoverTask 用 `fullStorageGroupName`（= `root.corec-3`），
#      而 CompactionRecoverManager 的 dir 行只有 `root.corec` ⇒ 正则写成 `<db>(-<region>)? `。
co40_recover_cnt(){ local db=$1 pat=$2 re h s=0 n
  re="(^|[- ])(root\.)?$db(-[0-9]+)? "
  for h in "${DN[@]}"; do
    n=$(sshx "$h" "cat $(cmp_log_files) 2>/dev/null | grep -hF '$pat' | grep -cE '$re'" 2>/dev/null | tr -dc '0-9')
    s=$(( s + ${n:-0} ))
  done
  echo "${s:-0}"; }
# 该 DN 上"已删除但仍被打开"的 fd 数 / fd 总数（不依赖 lsof：直接读 /proc/<pid>/fd）
co40_fd_deleted(){ local h=$1 n
  n=$(sshx "$h" "p=\$(pgrep -f 'com\.timecho\.iotdb\.DataNode' | head -1); if [ -n \"\$p\" ]; then ls -l /proc/\$p/fd 2>/dev/null | grep -c 'deleted'; else echo 0; fi" 2>/dev/null | tr -dc '0-9')
  echo "${n:-0}"; }
co40_fd_total(){ local h=$1 n
  n=$(sshx "$h" "p=\$(pgrep -f 'com\.timecho\.iotdb\.DataNode' | head -1); if [ -n \"\$p\" ]; then ls /proc/\$p/fd 2>/dev/null | wc -l; else echo 0; fi" 2>/dev/null | tr -dc '0-9')
  echo "${n:-0}"; }
# 逐节点快照，形如 "77=3 78=2 79=2 "
co40_fd_snapshot(){ local f=$1 h out=""
  for h in "${DN[@]}"; do out="$out${h##*.}=$($f "$h") "; done; echo "$out"; }
co40_fd_of(){ printf '%s\n' "$1" | tr ' ' '\n' | grep -E "^${2##*.}=" | head -1 | cut -d= -f2; }

# ---------------------------------------------------------------------------
# 注入时机：一次并行往返取证（关键——原实现 9 次串行 ssh 把 6.7s 窗口耗光）
# ---------------------------------------------------------------------------
# 单节点：一次 ssh 同时回显 5 个数字（starts / finishes / tsfile / 合并日志 / 临时目标文件）
co40_probe(){ local h=$1 db=$2
  sshx "$h" "L=\"$DB_DIR/logs/log_datanode_compaction.log $DB_DIR/logs/log_datanode_all.log\"
s=\$(cat \$L 2>/dev/null | grep -hF 'InnerSpaceCompaction task starts with' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+')
f=\$(cat \$L 2>/dev/null | grep -hF 'InnerSpaceCompaction task finishes successfully' | grep -cE '(^|[- ])(root\.)?$db-[0-9]+')
t=\$(find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' 2>/dev/null | wc -l)
c=\$(find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*compaction.log' 2>/dev/null | wc -l)
m=\$(find $DB_DIR/data/datanode/data -path '*/$db/*' -type f ! -name '*.tsfile' ! -name '*.mods2' ! -name '*.resource' ! -name '*compaction.log' 2>/dev/null | wc -l)
echo \"s=\${s:-0} f=\${f:-0} t=\${t:-0} c=\${c:-0} m=\${m:-0}\"" 2>/dev/null | tr -d '\r'; }
# 3 个 DN 并行探测 → 汇总到 P_S / P_F / P_T / P_C / P_M（全局）
co40_probe_all(){ local db=$1 i=0 h
  P_S=0; P_F=0; P_T=0; P_C=0; P_M=0
  rm -f "$ART"/.probe_*
  for h in "${DN[@]}"; do
    i=$(( i + 1 ))
    ( echo "$h $(co40_probe "$h" "$db")" >"$ART/.probe_$i" 2>/dev/null ) &
  done
  wait
  P_RAW=$(cat "$ART"/.probe_* 2>/dev/null | tr '\n' '|')
  read -r P_S P_F P_T P_C P_M <<<"$(printf '%s\n' "$P_RAW" | tr '|' '\n' | awk -F'[= ]' '{for(i=1;i<=NF;i++){if($i=="s")S+=$(i+1); if($i=="f")F+=$(i+1); if($i=="t")T+=$(i+1); if($i=="c")C+=$(i+1); if($i=="m")M+=$(i+1)}} END{print S+0, F+0, T+0, C+0, M+0}')"
  printf '    [注入探测] %s\n' "$P_RAW" >>"$OUT"; }
# 3 个 DN 同时 kill -9（**并行**；`pkill -9` 不走 lsof，最快让进程消失）
co40_kill_all_dn(){ local h
  for h in "${DN[@]}"; do
    ( sshx "$h" "pkill -9 -f '[c]om[.]timecho[.]iotdb[.]DataNode' >/dev/null 2>&1; sleep 1; pkill -9 -f '[c]om[.]timecho[.]iotdb[.]DataNode' >/dev/null 2>&1; true" >/dev/null 2>&1 ) &
  done
  wait
  sleep 3
  for h in "${DN[@]}"; do wait_dn_state "$h" notrunning "$DN_DOWN_WAIT_SEC" || warn "  $h 未进入 notrunning"; done; }
co40_start_all_dn(){ local h
  for h in "${DN[@]}"; do
    sshx "$h" "nohup $DB_DIR/sbin/start-datanode.sh -d >$DB_DIR/start_dn_${RUN_ID}_${h##*.}.log 2>&1 </dev/null &" || true
  done
  for h in "${DN[@]}"; do wait_dn_state "$h" running "$DN_RECOVER_WAIT_SEC" || fail "  $h 未恢复 Running"; done; }
# 注入重试时补一批候选（只有"没抓住"才会走这里）；等到文件数 +3（每 DN 一个新文件）才算落盘
co40_add_file(){ local db=$1 base=$2 n=$3 t0 dl t
  local b=$(( BATCHES + 10 + n ))
  log "  [$db] 注入重试：补写 1 批（批次号 $b）制造新的合并候选"
  co40_write "$db" "$base" "$b"
  sq "flush;" >/dev/null
  dl=$(( $(date +%s) + 90 ))
  while (( $(date +%s) < dl )); do
    t=$(cmp_all_sum "$db")
    [ "${t:-0}" -ge "$(( t0 + 3 ))" ] && { log "  [$db] 补写批已落盘（文件数 $t0 → $t）"; return 0; }
    sq "flush;" >/dev/null; sleep 5
  done
  warn "  [$db] 补写批未落盘（文件数 $t0 → ${t:-?}）"; return 1; }
# kill -9 后（重启前）量"冻结的崩溃态"→ D3-1 / D3-4 的硬证据
co40_freeze_state(){ local db=$1
  FZ_TEMP=$(co40_temp_sum "$db")
  FZ_CLOG=$(co40_clog_sum "$db")
  FZ_MODS=$(co40_mods_sum "$db")
  FZ_TS=$(cmp_all_sum "$db")
  log "  [$db] 崩溃冻结态：临时目标文件=$FZ_TEMP 合并日志=$FZ_CLOG mods2=$FZ_MODS 文件数=$FZ_TS"
  co40_temp_list "${DN[0]}" "$db" | sed 's/^/    .inner@77: /' >>"$OUT"
  co40_mods_list "${DN[0]}" "$db" | sed 's/^/    mods2@77: /' >>"$OUT"; }

# 合并 / 生命周期 helper
# ---------------------------------------------------------------------------
# 等合并收敛：finishes 增加 且 文件数下降 且 连续 2 次采样不变
co40_wait_converge(){ local db=$1 fin0=$2 ts0=$3 win=$4 what=$5 dl f t stab=0 lf="" lt=""
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    sleep 5
    f=$(cmp_inner_finish "$db"); t=$(cmp_all_sum "$db")
    log "    等$what: finishes=$f(基线$fin0) tsfile=$t(基线$ts0)"
    if [ "${f:-0}" -gt "${fin0:-0}" ] && [ "${t:-0}" -lt "${ts0:-0}" ]; then
      if [ "$f" = "$lf" ] && [ "$t" = "$lt" ]; then stab=$(( stab + 1 )); else stab=1; fi
      [ "$stab" -ge 2 ] && return 0
    fi
    lf=$f; lt=$t
  done
  return 1; }
# 崩溃恢复后"重新选文件并跑完"：文件数 < 崩溃前 且 finishes > 崩溃前（连续 2 次稳定）
# ⚠️ 结果写在全局 RM_RES（**不要用 echo**：函数内部 log 会打到 stdout，`$(...)` 会把整段采样日志
#    捕获进 WARN/FAIL 文案，首跑的 v_warnMessage 因此塞了几十条采样行）
co40_wait_remerge(){ local db=$1 start0=$2 fin0=$3 tspre=$4 win=$5 dl t f s stab=0 lt="" ns=0
  RM_RES="files=${tspre:-?} finishes=${fin0:-?} new_start=0（无采样）"
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    sleep 5
    t=$(cmp_all_sum "$db"); f=$(cmp_inner_finish "$db"); s=$(cmp_inner_start "$db")
    log "    等恢复后重新合并: tsfile=$t(崩溃前 $tspre) finishes=$f(崩溃前 $fin0) starts=$s(崩溃前 $start0)"
    [ "${s:-0}" -gt "${start0:-0}" ] && ns=1
    if [ "${t:-0}" -lt "${tspre:-0}" ] && [ "${f:-0}" -gt "${fin0:-0}" ]; then
      if [ "$t" = "$lt" ]; then stab=$(( stab + 1 )); else stab=1; fi
      [ "$stab" -ge 2 ] && { RM_RES="files=$t finishes=$f new_start=$ns"; return 0; }
    fi
    lt=$t
  done
  RM_RES="files=${t:-0} finishes=${f:-0} new_start=$ns"; return 1; }
# D3-7 构造：在某库真实产物旁造一个 0 字节 .tsfile（名字取真实文件名的末段 +7）
# 回显写文件路径到 $ART/stray_paths.txt（每行 "节点 路径"）
co40_stray_create(){ local db=$1 h p
  : >"$ART/stray_paths.txt"
  for h in "${DN[@]}"; do
    p=$(sshx "$h" "set -- \$(find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' 2>/dev/null | head -1); [ -n \"\${1:-}\" ] || { echo NONE; exit 0; }; d=\$(dirname \"\$1\"); f=\$(basename \"\$1\" .tsfile); hd=\${f%-*}; last=\${f##*-}; case \"\$last\" in ''|*[!0-9]*) echo NOFMT; exit 0;; esac; n=\$(( last + 7 )); : > \"\$d/\$hd-\$n.tsfile\" && echo \"\$d/\$hd-\$n.tsfile\"" 2>/dev/null | tr -d '\r')
    printf '%s %s\n' "$h" "$p" >>"$ART/stray_paths.txt"
    case "$p" in NONE|NOFMT|"") warn "  $h 上无法派生空目标文件名（$p）";; *) log "  [D3-7] $h 造 0 字节目标文件：$p";; esac
  done; }
# 回显 "已消失数 总数"
co40_stray_gone(){ local h p n=0 tot=0 v
  while read -r h p; do
    case "$p" in NONE|NOFMT|"") continue;; esac
    tot=$(( tot + 1 ))
    v=$(sshx "$h" "if [ -f '$p' ]; then echo 1; else echo 0; fi" 2>/dev/null | tr -dc '0-9')
    [ "${v:-1}" = "0" ] && n=$(( n + 1 ))
  done <"$ART/stray_paths.txt"
  printf '%s %s' "$n" "$tot"; }

# ---------------------------------------------------------------------------
# 造数据 helper
# ---------------------------------------------------------------------------
co40_mkdb(){ local db=$1
  sq "create database $db;" >/dev/null
  sq "create timeseries $db.$DEV.s1 with datatype=TEXT,   encoding=PLAIN,  compression=UNCOMPRESSED;" >/dev/null
  sq "create timeseries $db.$DEV.s2 with datatype=INT64,  encoding=PLAIN,  compression=SNAPPY;" >/dev/null
  sq "create timeseries $db.$DEV.s3 with datatype=DOUBLE, encoding=GORILLA, compression=SNAPPY;" >/dev/null; }
# 写 1 批（ROWS 行 × 1KB TEXT；ts = base + b*100000 + k*10）
# ⚠️ 大 payload 不能用 `sq -e`（Argument list too long，静默不落盘）⇒ 单会话 stdin 喂语句
co40_write(){ local db=$1 base=$2 b=$3 i=0 k vals="" stmts="" ts t0
  for ((k=1; k<=ROWS; k++)); do
    t0=$(( base + b * 100000 + k * 10 ))
    vals="$vals($t0,'$PAYLOAD',$(( k + b )),$k.250),"
    i=$(( i + 1 ))
    if [ $(( i % PER )) -eq 0 ]; then stmts="${stmts}insert into $db.$DEV(time,s1,s2,s3) values ${vals%,};
"; vals=""; fi
  done
  if [ -n "$vals" ]; then stmts="${stmts}insert into $db.$DEV(time,s1,s2,s3) values ${vals%,};
"; fi
  printf '%s' "$stmts" | session_tree >/dev/null
  sq "flush;" >/dev/null; }
# 本用例的数据指纹：行数 + s2/s3 的 sum + TEXT 载荷的 md5（**不要**原样回显 1KB 载荷：
# 首跑把 2KB 载荷打进了每条日志与 CSV message，2003s 的输出里全是 qqq）
# ⚠️【CO-40 首轮 4 条假 FAIL 的根因 + 修法】指纹前必须**归一化** CLI 原始输出：
#   `sq()` 拿到的是 `... -e "$1"` 的完整回显，除数据行外还有
#   `Total line number = N` 与 **每次都不一样**的 `It costs X.XXXs`（2026-10-16 那轮实测
#   `It costs 0.014s`）⇒ 对原始输出直接 `md5sum`，**同一份数据**两次摘要必然不同
#   （那轮 4 条"数据指纹不一致"的 `rows/sum2/sum3` 逐字节相同，只有 head_md5 变；`root.corec3`
#   在两次比较之间甚至没有任何写入、只重启过）。
#   修法：先过 `norm_result`（lib/common.sh:550-557：只保留 `^\|` 数据行、剔除表头/分隔线/计时行，
#   报错时归一化成 `ERROR:xxx`）再取摘要 —— 与 `cmp_fingerprint`(lib/cmp.sh:155)、
#   `cmp_alter_ts`(lib/cmp.sh:470)、`tools/diag_dt01.sh:12` 的剥除做法完全一致。
#   验收点：同一份数据在"崩溃重启前后"的 head_md5 必须相同；`rows/sum2/sum3` 仍逐字节一致（硬判据）。
co40_fp(){ local db=$1 c s2 s3 hd
  c=$(row_sum "$(sq "select count(s1) from $db.**;")")
  s2=$(row_sum "$(sq "select sum(s2) from $db.**;")")
  s3=$(row_sum "$(sq "select sum(s3) from $db.**;")")
  hd=$(norm_result "$(sq "select s1 from $db.$DEV order by time limit 2")" | md5sum | cut -c1-10)
  printf 'rows=%s sum2=%s sum3=%s head_md5=%s' "$c" "$s2" "$s3" "$hd"; }

# ===========================================================================
log "--- 集群准备：三类合并全关；candidate=2、gap=0；读/写限流各 1MB/s（int 键，1 是最小正值；读限流决定窗口）---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=${CMP_INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,compaction_write_throughput_mb_per_sec=1,compaction_read_throughput_mb_per_sec=1" cmp_cluster_prepare
log "  规模：相1 = $(( BATCHES + 1 )) 批（1 预批被删 $DEL_ROWS 行 + $BATCHES 批追加）× $ROWS 行 × 1KB ≈ $(( (BATCHES + 1) * ROWS / 1024 ))MB（合并窗口 ≈ $(( (BATCHES + 1) * ROWS / 1024 ))s）；相2 = $BATCHES2 批；相3 = $BATCHES3 批"

# ---------------------------------------------------------------------------
log "--- 相 1 造场景：$DB（DELETE 造 .mods2 → 追加批次 → 攒出可合并的 level-0 文件）---"
cmp_compaction_off
co40_mkdb "$DB"
BASE=$(now_ms)
co40_write "$DB" "$BASE" 1
cmp_wait_close "$DB" 1 120 >/dev/null || warn "  [$DB] 预批 close 事件未达 1"
DEL_UNTIL=$(( BASE + 100000 + DEL_ROWS * 10 ))
sq "delete from $DB.$DEV.** where time <= $DEL_UNTIL;" >/dev/null
sq "flush;" >/dev/null
sleep 5
MODS0=0
MODS_DL=$(( $(date +%s) + 60 ))
while (( $(date +%s) < MODS_DL )); do
  MODS0=$(co40_mods_sum "$DB")          # ⚠️ 必须按 RC7 的 `.mods2` 匹配（原实现查 `*.mods` ⇒ 恒 0）
  [ "${MODS0:-0}" -gt 0 ] && break
  sleep 3
done
ROWS_DEL=$(row_sum "$(sq "select count(s1) from $DB.**;")")
log "  [$DB] DELETE 后：.mods2=$MODS0 行数=$ROWS_DEL（DELETE 走共识，已轮询等各副本产生 .mods2）"
log "  [$DB] .mods2 明细（77）：$(co40_mods_list "${DN[0]}" "$DB" | tr '\n' ';')"
[ "${MODS0:-0}" -gt 0 ] && pass "  场景有效性：DELETE 产生了 $MODS0 个 .mods2（>0，D3-2/3-3 的前提）" \
  || fail "  场景无效：DELETE 未产生 .mods2（MODS0=$MODS0）——本用例的 mods 迁移判据无法成立"
for b in $(seq 2 $(( BATCHES + 1 ))); do
  co40_write "$DB" "$BASE" "$b"
  cmp_wait_close "$DB" "$b" 120 >/dev/null || warn "  [$DB] 批$b close 事件未达 $b"
done
ROWS_PRE=$(row_sum "$(sq "select count(s1) from $DB.**;")")
log "  [$DB] 追加批后行数=$ROWS_PRE（DELETE 后 $ROWS_DEL + $BATCHES 批 × $ROWS 行）"
[ "${ROWS_PRE:-0}" -gt "${ROWS_DEL:-0}" ] && pass "  场景有效性：追加批次已落库（$ROWS_DEL → $ROWS_PRE）" \
  || fail "  场景无效：追加批次未生效（$ROWS_DEL → $ROWS_PRE）"
LAY1=$(cmp_lay "$DB")
MINL0=$(cmp_min_l0 "$DB")
log "  [$DB] 起点布局=$LAY1 文件数=$(cmp_all_sum "$DB") 字节=$(cmp_bytes_sum "$DB") min_l0=$MINL0"
[ "${MINL0:-0}" -ge 2 ] && pass "  场景有效性：开合并前各副本 level-0 文件数最小 $MINL0（≥2）" \
  || fail "  场景无效：min_l0=$MINL0（<2，攒不出合并候选）"
[ "$(printf '%s\n' "$(cmp_lay_uni "$LAY1")" | tr ' ' '\n' | grep -c .)" = "1" ] \
  && pass "  场景有效性：三副本布局一致（$(cmp_lay_uni "$LAY1")）" \
  || fail "  场景有效性：三副本布局不一致（$LAY1）"

FP0=$(co40_fp "$DB")
START0=$(cmp_inner_start "$DB")
FIN0=$(cmp_inner_finish "$DB")
TS0=$(cmp_all_sum "$DB")
DEL0=$(co40_fd_snapshot co40_fd_deleted)
TOT0=$(co40_fd_snapshot co40_fd_total)
log "  [$DB] 合并前：指纹[$FP0] 文件=$TS0 starts=$START0 finishes=$FIN0"
log "  [$DB] 合并前句柄：deleted=[$DEL0] fd=[$TOT0]"

log "--- 相 1 注入：合并**进行中**在 3 个 DN 上同时 kill -9（一次并行取证 + 立刻 kill，决策延迟 ≈1s）---"
cmp_compaction_on true true false
# ===== 注入时机硬校验（三条同时成立才注入）=====
#   ① 该库出现新的 `task starts with`（合并已开始）
#   ② TsFile 数**未下降**（合并尚未提交——这是"没提交"的真正守卫；finishes 只作证据记录）
#   ③ 合并日志 `<target>.inner-compaction.log` 或临时目标文件 `<target>.inner` 已出现（真的在写）
#   三条都满足 ⇒ 立刻并行 kill -9；不满足但已有 finishes 增加（本轮已提交）⇒ 补一批候选重试一轮。
SCENE1=0
TS_PRE=$TS0; FIN_PRE=$FIN0; START_PRE=$START0
INJ_EVID="（未探测）"
att=1
while [ "$att" -le "$INJ_ATT" ]; do
  dl=$(( $(date +%s) + INJ_WIN ))
  inj=0
  while (( $(date +%s) < dl )); do
    co40_probe_all "$DB"
    INJ_EVID="att=$att s=$P_S(基线$START0) f=$P_F(基线$FIN0) tsfile=$P_T(基线$TS0) clog=$P_C inner=$P_M"
    log "  [相1 注入时机] $INJ_EVID"
    if [ "${P_S:-0}" -gt "${START0:-0}" ] && [ "${P_T:-0}" -ge "${TS0:-0}" ] \
       && [ $(( ${P_C:-0} + ${P_M:-0} )) -ge 1 ]; then
      inj=1; break
    fi
    if [ "${P_F:-0}" -gt "${FIN0:-0}" ]; then break; fi          # 本轮合并已提交 ⇒ 换一轮候选
    sleep 0.5
  done
  [ "$inj" = 1 ] && { SCENE1=1; break; }
  warn "  [相1] 第 $att 次未抓住注入时机（$INJ_EVID）"
  [ "$att" -ge "$INJ_ATT" ] && break
  att=$(( att + 1 ))
  TS_TMP=$(cmp_all_sum "$DB")
  co40_add_file "$DB" "$BASE" "$att" "$TS_TMP"
  START0=$(cmp_inner_start "$DB"); FIN0=$(cmp_inner_finish "$DB"); TS0=$(cmp_all_sum "$DB")
  log "  [$DB] 重试基线：starts=$START0 finishes=$FIN0 文件=$TS0"
done
if [ "$SCENE1" = 1 ]; then
  pass "  场景有效性：注入时机成立（三条同时满足：task starts 已出现、文件数尚未下降、临时目标文件/合并日志已出现）[$INJ_EVID]"
  TS_PRE=$P_T; FIN_PRE=$P_F; START_PRE=$P_S
  co40_kill_all_dn
  co40_freeze_state "$DB"
  # 竞态兜底：探测→kill 之间合并若已提交，冻结态会出现"文件数下降 + 合并日志已被删"。
  # 此时本相没测到「合并中崩溃」，如实判"场景无效"并**跳过**后续分支判据（不产生连带 FAIL）。
  if [ "${FZ_TS:-0}" -lt "${TS_PRE:-0}" ] || [ "${FZ_CLOG:-0}" -eq 0 ]; then
    SCENE1=0
    fail "  场景无效：kill 与合并提交发生竞态（冻结态 文件数=$FZ_TS vs 注入前 $TS_PRE、合并日志=$FZ_CLOG）⇒ 未构造出「合并中崩溃」，本相分支判据跳过（不计连带 FAIL；属构造/时序问题，不是产品行为判定）"
  else
    # D3-1：合并进行中**存在**不以 .tsfile 结尾的临时目标文件（冻结态硬证据）
    [ "${FZ_TEMP:-0}" -ge 1 ] && pass "  [D3-1] kill -9 后（重启前）该库存在 $FZ_TEMP 个不以 .tsfile 结尾的临时目标文件（合并进行中的硬证据）" \
      || fail "  [D3-1] kill -9 后未见不以 .tsfile 结尾的临时目标文件（$FZ_TEMP）——D3-1 的「过程中存在」无证据"
    co40_clog_dump "$DB" "$ART/inject_phase1_clog.txt"
  fi
  co40_start_all_dn
  check_sync_lag || fail "  相 1 重启后 sync lag 未归零"
  sleep 5
else
  fail "  场景无效：$(( INJ_WIN * INJ_ATT ))s 内未抓住「合并进行中」的注入时机（$INJ_EVID）⇒ 本相未构造出「合并中崩溃」，后续分支判据跳过（不计连带 FAIL）；未注入 ⇒ 不重启"
fi
TSA=$(cmp_all_sum "$DB")
FP1=$(co40_fp "$DB")

if [ "$SCENE1" = 1 ]; then
  log "--- 相 1 判据：D3-5/D3-9（回滚 / 重做）+ D3-1/3-2/3-3 的残留与数据 ---"
  TMP1=$(co40_temp_sum "$DB")
  CLOG1=$(co40_clog_sum "$DB")
  ORPH1=$(co40_orphan_mods_sum "$DB")
  ROWS1=$(row_sum "$(sq "select count(s1) from $DB.**;")")
  RC_ROLLBACK=$(co40_recover_cnt "$DB" '[Compaction][Recover] all source files exists, delete all target files')
  RC_DEL=$(co40_recover_cnt "$DB" '[Compaction][Recover] Recover compaction successfully, delete log file')
  RC_FAIL=$(co40_recover_cnt "$DB" '[Compaction][Recover] Failed to recover compaction')
  log "  [$DB] 恢复分支标记：all_source_exist=$RC_ROLLBACK delete_log=$RC_DEL recover_failed=$RC_FAIL"
  log "  [$DB] 恢复后：文件数=$TSA（崩溃前 $TS_PRE）临时文件=$TMP1 合并日志=$CLOG1 孤儿mods2=$ORPH1"
  log "  [$DB] 说明：lib 的 cmp_tmp_leftover 按 '*.compaction.log' 匹配，RC7 的日志名是 '<target>.inner-compaction.log' ⇒ 它恒为 0（仅记录：$(cmp_tmp_leftover "$DB")）"
  # ① 分支标记（源码：CompactionRecoverTask.handleWithAllSourceFilesExist）
  [ "${RC_ROLLBACK:-0}" -ge 1 ] && pass "  [$DB] 恢复走了回滚分支（D3-5：源文件都在 ⇒ 删除全部目标文件）" \
    || { [ "${TSA:-0}" -lt "${TS_PRE:-0}" ] \
           && warn "  [$DB] 未见回滚标记但文件数已下降（$TS_PRE → $TSA）⇒ 走了前滚/重做路径（记录，不作硬判据）" \
           || fail "  [$DB] 恢复日志既无回滚标记、文件数也未下降（$TS_PRE → $TSA）⇒ 恢复分支未按源码预期执行"; }
  assert_eq "  [$DB] 恢复失败标记 [Compaction][Recover] Failed to recover compaction" "${RC_FAIL:-0}" "0"
  # ② 残留与数据（D3-1/3-5/3-9）
  assert_eq "  [$DB] 恢复后不以 .tsfile 结尾的临时目标文件数（D3-1 完成态）" "${TMP1:-0}" "0"
  assert_eq "  [$DB] 恢复后合并日志数（D3-5/3-9 无残留）" "${CLOG1:-0}" "0"
  assert_eq "  [$DB] 恢复后孤儿 *.mods2（含 .compaction.mods2）数（D3-2/3-3）" "${ORPH1:-0}" "0"
  assert_eq "  [$DB] 被删行未复活（恢复后行数 = 合并前全部写入的行数）" "${ROWS1:-0}" "${ROWS_PRE:-0}"
  cmp_assert_same "  [$DB] 崩溃重启后数据指纹（与崩溃前完全一致）" "$FP0" "$FP1"
  log "  [$DB] 回滚语义核对：崩溃前文件数 $TS_PRE → 重启后立刻 $TSA（回滚 ⇒ 源文件还原到 level-0，不下降为正常）"
  # ③ 恢复后重新选文件并跑完（D3-5/3-9 + MG-P21「不续合」）
  if [ "${TSA:-0}" -ge 2 ]; then
    if co40_wait_remerge "$DB" "$START_PRE" "$FIN_PRE" "$TS_PRE" "$REWIN"; then
      pass "  [$DB] 恢复后重新选文件并跑完合并：$RM_RES"
      case "$RM_RES" in *new_start=1*) pass "  [$DB] 重启后**不续合**：出现新的 task starts（D3-5/3-9 与 MG-P21）";;
        *) warn "  [$DB] 重启后未见新的 task starts，但文件数已下降、finishes 已增加（恢复走了重做路径，记录）";; esac
    else
      fail "  [$DB] 恢复后 ${REWIN}s 内未观察到重新合并完成（$RM_RES）"
    fi
  else
    warn "  [$DB] 崩溃后文件数 $TSA <2，没有可再选的候选 ⇒ 「重新选文件」无证据（记录）"
  fi
  assert_eq "  [$DB] 合并完成后孤儿 *.mods2 数" "$(co40_orphan_mods_sum "$DB")" "0"
  assert_eq "  [$DB] 合并完成后不以 .tsfile 结尾的临时文件数" "$(co40_temp_sum "$DB")" "0"
  log "  [$DB] 终态：布局=$(cmp_lay "$DB") 文件数=$(cmp_all_sum "$DB") .mods2=$(co40_mods_sum "$DB") 字节=$(cmp_bytes_sum "$DB")"
  log "  [$DB] 终态 mods2 明细（77）：$(co40_mods_list "${DN[0]}" "$DB" | tr '\n' ';')（D3-2：源 mods 已迁移/随源文件删除，目标 mods 是否保留属实现细节，仅记录）"
else
  log "--- 相 1：场景未成立 ⇒ 跳过 D3-5/3-9 与 mods 迁移的分支判据（记录实测：文件数 $TS_PRE → $TSA，starts $START_PRE finishes $FIN_PRE）---"
  warn "  [$DB] 场景未成立，分支判据已跳过（数据指纹仍校验：$( [ "$FP0" = "$FP1" ] && echo 一致 || echo "不一致 $FP0 vs $FP1" )）"
  cmp_assert_same "  [$DB] 崩溃重启后数据指纹（场景未成立时仍必须一致）" "$FP0" "$FP1"
fi

# ---------------------------------------------------------------------------
log "--- 相 3 前置：$DB3 正常合并完成（为 D3-7 的空目标文件准备一个「已合并」的库）---"
cmp_compaction_off
co40_mkdb "$DB3"
BASE3=$(now_ms)
for b in $(seq 1 "$BATCHES3"); do
  co40_write "$DB3" "$BASE3" "$b"
  cmp_wait_close "$DB3" "$b" 120 >/dev/null || warn "  [$DB3] 批$b close 事件未达 $b"
done
TS30=$(cmp_all_sum "$DB3")
FIN30=$(cmp_inner_finish "$DB3")
FP3=$(co40_fp "$DB3")
[ "${TS30:-0}" -ge 2 ] && pass "  场景有效性：[$DB3] 合并前文件数 $TS30（≥2）" || fail "  场景无效：[$DB3] 文件数=$TS30（<2）"
cmp_compaction_on true true false
if co40_wait_converge "$DB3" "$FIN30" "$TS30" "$WIN" "相3 合并"; then
  pass "  [$DB3] 正常合并完成（文件数 $TS30 → $(cmp_all_sum "$DB3")）"
else
  fail "  [$DB3] ${WIN}s 内合并未收敛"
fi
LAY3=$(cmp_lay "$DB3")
FP3B=$(co40_fp "$DB3")
cmp_assert_same "  [$DB3] 合并前后指纹" "$FP3" "$FP3B"
log "  [$DB3] 合并后布局=$LAY3 文件数=$(cmp_all_sum "$DB3")"

# ---------------------------------------------------------------------------
log "--- 相 2 造场景：$DB2（合并进行中 kill -9 → 清空合并日志 ⇒ D3-4）---"
cmp_compaction_off
co40_mkdb "$DB2"
BASE2=$(now_ms)
for b in $(seq 1 "$BATCHES2"); do
  co40_write "$DB2" "$BASE2" "$b"
  cmp_wait_close "$DB2" "$b" 120 >/dev/null || warn "  [$DB2] 批$b close 事件未达 $b"
done
MINL02=$(cmp_min_l0 "$DB2")
TS2_PRE=$(cmp_all_sum "$DB2")
FIN2_PRE=$(cmp_inner_finish "$DB2")
START2_PRE=$(cmp_inner_start "$DB2")
FP2=$(co40_fp "$DB2")
[ "${MINL02:-0}" -ge 2 ] && pass "  场景有效性：[$DB2] min_l0=$MINL02（≥2）" || fail "  场景无效：[$DB2] min_l0=$MINL02（<2）"
log "  [$DB2] 合并前：指纹[$FP2] 文件=$TS2_PRE starts=$START2_PRE finishes=$FIN2_PRE"
cmp_compaction_on true true false
SCENE2=0
TS2B=$TS2_PRE; FIN2B=$FIN2_PRE; START2B=$START2_PRE
INJ2_EVID="（未探测）"
att=1
while [ "$att" -le "$INJ_ATT" ]; do
  dl=$(( $(date +%s) + INJ_WIN ))
  inj=0
  while (( $(date +%s) < dl )); do
    co40_probe_all "$DB2"
    INJ2_EVID="att=$att s=$P_S(基线$START2_PRE) f=$P_F(基线$FIN2_PRE) tsfile=$P_T(基线$TS2_PRE) clog=$P_C inner=$P_M"
    log "  [相2 注入时机] $INJ2_EVID"
    if [ "${P_S:-0}" -gt "${START2_PRE:-0}" ] && [ "${P_T:-0}" -ge "${TS2_PRE:-0}" ] \
       && [ $(( ${P_C:-0} + ${P_M:-0} )) -ge 1 ]; then
      inj=1; break
    fi
    if [ "${P_F:-0}" -gt "${FIN2_PRE:-0}" ]; then break; fi
    sleep 0.5
  done
  [ "$inj" = 1 ] && { SCENE2=1; break; }
  warn "  [相2] 第 $att 次未抓住注入时机（$INJ2_EVID）"
  [ "$att" -ge "$INJ_ATT" ] && break
  att=$(( att + 1 ))
  TS2_TMP=$(cmp_all_sum "$DB2")
  co40_add_file "$DB2" "$BASE2" "$att" "$TS2_TMP"
  START2_PRE=$(cmp_inner_start "$DB2"); FIN2_PRE=$(cmp_inner_finish "$DB2"); TS2_PRE=$(cmp_all_sum "$DB2")
  log "  [$DB2] 重试基线：starts=$START2_PRE finishes=$FIN2_PRE 文件=$TS2_PRE"
done
if [ "$SCENE2" = 1 ]; then
  pass "  场景有效性：注入时机成立（合并进行中）[$INJ2_EVID]"
  TS2B=$P_T; FIN2B=$P_F; START2B=$P_S
else
  fail "  场景无效：$(( INJ_WIN * INJ_ATT ))s 内未抓住「合并进行中」的注入时机（$INJ2_EVID）⇒ D3-4 分支未构造，后续 D3-4 判据跳过（不计连带 FAIL）"
fi
# 不论场景是否成立都做一次 3 DN kill -9 + 重启：D3-7 需要这次重启（SCENE2=0 时它只是普通重启，不注入）
co40_kill_all_dn
co40_freeze_state "$DB2"
if [ "$SCENE2" = 1 ]; then
  co40_clog_dump "$DB2" "$ART/inject_phase2_clog_before_truncate.txt"
  [ "${FZ_TEMP:-0}" -ge 1 ] && pass "  [D3-1] $DB2 kill -9 后存在 $FZ_TEMP 个临时目标文件（合并进行中）" \
    || warn "  [D3-1] $DB2 kill -9 后未见临时目标文件（$FZ_TEMP，记录）"
  # D3-4 的前提：停机窗口里**确有**合并日志可清空（原来是错 glob + 合并已提交 ⇒ 恒 0）
  if [ "${FZ_CLOG:-0}" -lt 1 ]; then
    SCENE2=0
    fail "  场景无效：[D3-4] 停机时没有合并日志可清空（$FZ_CLOG，冻结态文件数=$FZ_TS vs 注入前 $TS2_PRE）⇒ 日志不完整分支没被构造出来，D3-4 分支判据跳过（不计连带 FAIL；属构造/时序问题）"
  else
    pass "  场景有效性：[D3-4] 停机时该库确有 $FZ_CLOG 个合并日志（$(co40_clog_list "${DN[0]}" "$DB2" | head -1 | cut -d' ' -f2-)）"
    CLOGN=$(co40_clog_truncate "$DB2")
    log "  [D3-4] 停机窗口内把 $DB2 的合并日志清空（$CLOGN 个）"
    [ "${CLOGN:-0}" -ge 1 ] && pass "  场景有效性：[D3-4] 已清空 $CLOGN 个合并日志（注入真的生效）" \
      || { SCENE2=0; fail "  场景无效：[D3-4] 没有合并日志被清空（$CLOGN）⇒ 日志不完整分支没被构造出来，D3-4 分支判据跳过"; }
  fi
else
  log "  [D3-4] 场景未成立 ⇒ 不清空日志（本次 kill -9 仅用于给 D3-7 提供一次重启）"
fi
co40_stray_create "$DB3"
co40_start_all_dn
check_sync_lag || fail "  相 2 重启后 sync lag 未归零"
sleep 5

log "--- 相 2 判据：D3-4（日志不完整 ⇒ abort recover、不报错、不阻塞后续合并）---"
if [ "$SCENE2" = 1 ]; then
  RC_ABORT=$(co40_recover_cnt "$DB2" '[Compaction][Recover] incomplete log file, abort recover')
  RC_DEL2=$(co40_recover_cnt "$DB2" '[Compaction][Recover] Recover compaction successfully, delete log file')
  RC_FAIL2=$(co40_recover_cnt "$DB2" '[Compaction][Recover] Failed to recover compaction')
  CLOG2=$(co40_clog_sum "$DB2")
  TMP2=$(co40_temp_sum "$DB2")
  ORPH2=$(co40_orphan_mods_sum "$DB2")
  log "  [$DB2] 恢复分支标记：incomplete_abort=$RC_ABORT delete_log=$RC_DEL2 recover_failed=$RC_FAIL2"
  # 源码：CompactionRecoverTask —— 日志不完整 ⇒ 打 "incomplete log file, abort recover" 后 return，
  #       finally 里 recoverSuccess=true ⇒ 删日志文件并打 "Recover compaction successfully, delete log file"
  [ "${RC_ABORT:-0}" -ge 1 ] && pass "  [$DB2] 命中「日志不完整 ⇒ 中止恢复」分支（D3-4）" \
    || fail "  [$DB2] 未见 [Compaction][Recover] incomplete log file, abort recover ⇒ 日志不完整分支未按源码执行"
  [ "${RC_DEL2:-0}" -ge 1 ] && pass "  [$DB2] 不完整日志被删除且恢复被标记成功（Recover compaction successfully, delete log file）" \
    || fail "  [$DB2] 未见「Recover compaction successfully, delete log file」⇒ 恢复未正常返回（D3-4）"
  assert_eq "  [$DB2] 恢复失败标记 [Compaction][Recover] Failed to recover compaction" "${RC_FAIL2:-0}" "0"
  assert_eq "  [$DB2] 重启后合并日志文件数（应被恢复路径删除）" "${CLOG2:-0}" "0"
  cmp_assert_same "  [$DB2] 崩溃重启后数据指纹" "$FP2" "$(co40_fp "$DB2")"
  # 本分支源码上"提前 return、不清理目标态文件" ⇒ 残留只记录不判 FAIL（诚实标注）
  warn "  [$DB2] [D3-4 记录] 残留（该分支源码上不清理目标态文件，不作硬判据）：临时文件=$TMP2 孤儿mods2=$ORPH2"
  if [ "${TS2B:-0}" -ge 2 ]; then
    if co40_wait_remerge "$DB2" "$START2B" "$FIN2B" "$TS2B" "$REWIN"; then
      pass "  [$DB2] 清空日志后仍能合并完成（D3-4：不阻塞后续合并）：$RM_RES"
    else
      fail "  [$DB2] 清空日志后 ${REWIN}s 内未完成合并（D3-4：不完整日志阻塞了后续合并）：$RM_RES（残留：临时文件=$TMP2 孤儿mods2=$ORPH2——需人工核对是否被残留 .inner/.compaction.mods2 挡住）"
    fi
  else
    warn "  [$DB2] 崩溃后文件数 $TS2B <2，没有可再选的候选 ⇒ 「不阻塞后续合并」无证据（记录）"
  fi
else
  log "--- 相 2：场景未成立 ⇒ 跳过 D3-4 分支判据（记录实测：合并日志数见上）---"
  cmp_assert_same "  [$DB2] 崩溃重启后数据指纹（场景未成立时仍必须一致）" "$FP2" "$(co40_fp "$DB2")"
fi

log "--- 相 3 判据：D3-7（0 字节空目标文件被清理）---"
read -r GONE TOT <<<"$(co40_stray_gone)"
if [ "${TOT:-0}" -eq 0 ]; then
  warn "  场景无效：未能造出 0 字节目标文件（$DB3 无真实产物可派生文件名），D3-7 本项无证据"
else
  assert_eq "  [$DB3] 0 字节目标文件已被清理（$GONE/$TOT 消失）" "$GONE" "$TOT"
fi
cmp_assert_same "  [$DB3] 重启后数据指纹（空目标文件处理不影响数据）" "$FP3B" "$(co40_fp "$DB3")"
assert_eq "  [$DB3] 重启后布局不变" "$(cmp_lay_uni "$(cmp_lay "$DB3")")" "$(cmp_lay_uni "$LAY3")"

# ---------------------------------------------------------------------------
log "--- 句柄/fd 判据：合并完成 +30s / +60s（MG-P15/P16、FC-13）---"
sleep 30
DEL30=$(co40_fd_snapshot co40_fd_deleted); TOT30=$(co40_fd_snapshot co40_fd_total)
sleep 30
DEL60=$(co40_fd_snapshot co40_fd_deleted); TOT60=$(co40_fd_snapshot co40_fd_total)
log "  deleted 句柄：合并前[$DEL0] +30s[$DEL30] +60s[$DEL60]"
log "  fd 总数    ：合并前[$TOT0] +30s[$TOT30] +60s[$TOT60]"
for h in "${DN[@]}"; do
  d0=$(co40_fd_of "$DEL0" "$h"); d30=$(co40_fd_of "$DEL30" "$h"); d60=$(co40_fd_of "$DEL60" "$h")
  t0=$(co40_fd_of "$TOT0" "$h"); t30=$(co40_fd_of "$TOT30" "$h"); t60=$(co40_fd_of "$TOT60" "$h")
  [ "${d60:-0}" -le "$(( ${d0:-0} + 2 ))" ] && pass "  [$h] 已删句柄 +60s = $d60 ≤ 基线 $d0 + 2" \
    || fail "  [$h] 已删句柄泄漏：+60s = $d60 > 基线 $d0 + 2（合并未释放源文件/日志句柄）"
  [ "${d30:-0}" = "${d60:-0}" ] && pass "  [$h] 已删句柄 +30s = +60s = $d60（已稳定）" \
    || warn "  [$h] 已删句柄仍在变化：+30s=$d30 → +60s=$d60（记录）"
  [ "${t60:-0}" -le "$(( ${t0:-0} + 20 ))" ] && pass "  [$h] fd 总数 +60s = $t60（基线 $t0，未持续增长）" \
    || warn "  [$h] fd 总数增长较多：$t0 → +30s$t30 → +60s$t60（记录）"
done

STUCK=$(cmp_stuck_sum)
cmp_assert_no_stuck "无合并线程卡死（TsFileResource.writeLock）"

log "--- 收尾三件套 ---"
post_checks "select count(s1) from $DB.**;" tree
cmp_case_finish "" tree ""
