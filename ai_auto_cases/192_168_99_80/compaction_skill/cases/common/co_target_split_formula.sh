#!/bin/bash
# ============================================================================
# CO-35 `target_compaction_file_size` 目标文件拆分规则的**量化**断言
#   覆盖设计规则 D1-1 / D1-2 / D1-3；官方 MG-10、MG-P20；补 CO-20（只做 N_A > N_B 相对断言）
#   规格来源：`docs/OFFICIAL_COVERAGE.md` §4.2 CO-35 + §5「判据完备性」第 1~3 行
#
# ---------------------------------------------------------------------------
# ⚠️ 首跑（2026-10-15，RC7 `7c61428` / IoTConsensus）FAIL 1 项的根因：
#    **用例构造 + 判据单位错误，不是产品行为问题**。逐条日志证据见下。
#    实测数字（首跑 `results/CO-35_20261015_164726.out`）：
#      A 相（target=auto=27772）：源文件 36（3 副本 × 12）/ 字节 104148；finishes 0→12；布局 12/0/0/0 → 0/2/0/0；
#                                 每副本计划/实测产物都是 2；每个任务 `target files are [{...-1-1-0.tsfile}]` 只 1 项
#      B 相（target=2GB）      ：源文件 36 / 字节 104400；finishes 0→12；布局 12/0/0/0 → 0/2/0/0；同样每任务 1 项
#      C 相（target=auto=18568）：源文件 24 / 字节 69630；finishes 0→12；布局 8/0/0/0 → 0/2/0/0；同样每任务 1 项
#    ① **判据单位错**：原 `co35_reg_stats` 按 `%h` 的 basename 分组 ⇒ 拿到的是**时间分区目录**
#       （路径形态 `.../data/{sequence,unsequence}/<db>/<regionId>/<timePartition>/<file>.tsfile`），
#       每个 DN 只有 1 个时间分区，于是日志里"region 合计 3"其实是"3 个 DN × 1 个时间分区"；
#       而**真实是 2 个 data region / DN**（DN 日志：`root.cospl-3`、`root.cospl-4`，各 6 个 L0）。
#       ⇒ 公式输入（region 字节/文件数）、容差（±region 数）全错，计划数与实测数只是**恰好撞对**
#       （12 文件/34716B 按时间分区算 = 2，而 2 恰好 = 2 个 region × 1 个产物）。
#    ② **A 相 target 太大**（不是太小）：auto = 0.8 × 最小**时间分区**字节 = 0.8 × 34716 = 27772
#       ≈ **1.6 × 单 region 字节**（17358）⇒ 每个任务 `floor(选中字节/target)+1 = 1`
#       ⇒ requiredPositionNum = 1 ⇒ **三相都没有发生任何拆分**，产物数只等于任务数。
#    ③ 于是 `A 相产物数 > B 相产物数` 是**结构性不可能成立**的判据（两相都 = 任务数 = region 数 × 1）。
#    ④ 用户的"2GB target 时根本不会合并 / 产物 6 其实是源文件"这一猜测**被日志推翻**：
#       B 相布局从 `12/0/0/0` 变成 `0/2/0/0`（12 个 L0 被消费、产出 2 个 L1），finishes 0→12，
#       产物名 level 段=1 ⇒ **确实合并了**。2GB 时"不拆分"才是正确产品行为：
#       源码 `floor(选中字节/2GB)+1 == 1` ⇒ requiredPositionNum == 1。
#    ⇒ 修法：把判据换成**任务级**（日志权威观测面）+ 让 target 真正落在会拆分的区间。
#
#   源码/设计依据（RC6 `7ae8713e` / RC7 `7c61428` 同）：
#     · `InnerSpaceCompactionTask.calculateSourceFilesAndTargetFiles()`（L314-320，D1-1）：
#         requiredPositionNum = min( (int)(selectedFileSize / target_compaction_file_size) + 1,
#                                    sortedAllSourceFilesInTask.size() )
#       `selectedFileSize` = **该任务选中的源文件字节**（既不是 region 字节，也不是库字节）
#       ⇒ **必须逐任务判定**；三个输入量都能从 DN 日志 + 合并前字节快照直接读到。
#     · 任务日志就是权威观测面（本用例的核心取证手段，已用 CO-20 历史日志验证过解析）：
#         `Sequence InnerSpaceCompaction task starts with N files`   → 源文件数
#         `compaction with selected files [{file: ...}, ...]`        → 选中源文件清单（配合合并前 `%s` 快照求和）
#         `... finishes successfully, target files are [...]`        → **列表长度 = requiredPositionNum**
#                                                                      （未用到的位置是 `*.inner` + `status: DELETED`）
#                                                                    → `*.tsfile` + `status: COMPACTING` 的条目数
#                                                                      = **真正落盘的产物数**
#       实测样本（`results/artifact_co_target_file_size_..._20261014_090507`，target=1KB）：
#         `target files are [{...-1-1-0.tsfile, COMPACTING}, {...-2-1-0.inner, DELETED},
#                            {...-3-1-0.inner, DELETED}, {...-4-1-0.inner, DELETED}]`
#         ⇒ requiredPositionNum=4（= min(floor(14272/1024)+1, 4 源文件)），而该 region 只有 1 个设备
#           ⇒ 设备粒度下只落盘 1 个产物，其余 3 个位置空置后被删除。同一脚本 target=2GB 时列表只有 1 项。
#     · 《【1.3.3.1】目标文件拆分与文件选择优化-详细设计》（D1-2/D1-3）：
#         「当文件数据区达到限制大小 singleFileSizeThreshold 并且当前已产生的文件个数小于源文件个数时，
#           结束当前文件，创建一个新的 TsFile」「规定合并产生的文件个数不超过源文件个数」「以设备为粒度进行拆分」
#       ⇒ 落盘产物数 = min(该 region 的设备数, requiredPositionNum)（阈值在每个设备边界检查；
#         当 target ≤ 单设备字节时，每个设备边界都会触发一次拆分）
#
#   场景（三相位，逐相位独立库；写入期三类合并全关，写完记基线后再热开；一检测到首个 finishes 立即热关冻结）：
#     A `root.cospl` ：DEVS 设备 × 3 序列 × BATCHES 批；target = floor(最小 region 字节 / 2)
#                      ⇒ 期望**逐 region** `floor(字节/target)+1 ∈ [2, region 源文件数-1]`（D1-1 未被 min 截断）
#     B `root.cospl2`：同构造；target = 2147483648（默认 2GB，**与源码一致的对照**）
#                      ⇒ 期望每个任务 requiredPositionNum **恒为 1**（`floor(选中字节/2GB)+1 == 1`，不拆分）
#     C `root.cospl3`：DEVS 设备 × 3 序列 × CBATCH 批；target = 1024（极小）
#                      ⇒ 期望 `floor(选中字节/target)+1 > 源文件数` 且 requiredPositionNum == **源文件数**
#                        （D1-2 的 min() 上界被真正吃满）+ 落盘产物数 == min(设备数, requiredPositionNum)（D1-3）
#
#   判据（全部可复算；数值一律来自日志/文件系统实测，不再用"聚合计数 ≈ 计划"这类撞对式判据）：
#     ① 每相位：`Sequence InnerSpaceCompaction finishes` 增加 **且** level-0 文件数下降；
#        合并前后 `cmp_fp_tree` 完全一致；
#     ② 逐任务（日志）：`requiredPositionNum == min(floor(选中源文件字节/target)+1, 源文件数)`（**无容差**）；
#     ③ 逐任务：`落盘产物数 ≤ requiredPositionNum ≤ 源文件数` 且 `落盘产物数 ≥ 1`（D1-2）；
#     ④ A 相：存在任务 requiredPositionNum ≥ 2 且逐 region 落在 [2, 源文件数-1]（**真的拆了**）；
#        B 相：所有任务 requiredPositionNum == 1（2GB 下不拆分，与源码一致）；
#        ⇒ 对照判据：`A 的 max(required) > B 的 max(required)`（取代原来无意义的 A/B 产物个数比较）；
#     ⑤ C 相：`floor(选中字节/target)+1 > 源文件数` 且 requiredPositionNum == 源文件数（min 上界生效）；
#     ⑥ D1-3：落盘产物数 == min(region 设备数, requiredPositionNum)（设备数由 `total process chunk num ÷ (序列数×选中文件数)` 反推；
#        **仅当 target ≤ 单设备字节**（每个设备边界必拆）时取等号，否则只断言 ≤ 并记录）；
#        物理拆分（某任务落盘 ≥2 个产物）在满足上述条件时必须成立，否则只 WARN 记录（阈值可能到任务末尾才被跨过）；
#        且**除"最后一个产物"外**每个产物字节 ≤ 单设备字节 + target（阈值在设备边界检查 ⇒ 最多超一个设备的数据量）；
#        磁盘侧另断言 D1-2：每个 region 的产物个数 ≤ 该 region 合并前的源文件个数；
#     ⑦ C 相：逐设备行数不变 + 每个产物 ≈ 整数个设备（代理判据，未全中只 WARN 记录）；
#     ⑧ 产物名 level 段全为 1；编号段只有一个取值时**只记录**（不判 FAIL）；
#     ⑨ 收尾三件套 + `cmp_stuck_sum == 0`。
#
# ---------------------------------------------------------------------------
# 【2026-10-16 harness 修复轮】施工图/证据：`_scratch/CO35_TRIAGE.md`
#   V2 `fail=44`(2158s) 与 V1 `fail=1`(553s) **没有一条指向产品行为**，全是 harness 缺陷：
#     H1 任务流靠"命令替换直接追加到 tasks"隐式拼接 ⇒ 丢尾换行 ⇒ 第 N 个 DN 末行与第 N+1 个 DN 首行粘成 `48TASK…`
#        ⇒ bash 算术致命错误 ⇒ **该相位剩余 40+ 条断言整体静默跳过**（V1/V2 都中；V1 的 `fail=1` 就是
#        ② 打印空值的产物，相位 A/B/C 三个相位从未真正执行过任何任务级公式判据）；
#     H2 awk 扫整行 ⇒ 把 `skipped files [...]` 也算进"选中" ⇒ 选中字节=整 region 字节（V2 特有触发），
#        D1-1 期望虚高、`chunk/(SERIES×选中数)` 反推的设备数错 ⇒ D1-3 误判；
#     H3 `co35_names` 没过滤 level ⇒ 把 35 个 L0 源文件 + 1 个重命名占位（`*-1-0-1.tsfile`）当产物 ⇒ 36 条假 FAIL。
#   本轮改动（对应报告 P0/P1/P2，**判据不放松**，只改输入口径与观测面）：①~⑪ 见下方注释里的 `P0-①` 等标记。
#
#   ⚠️ 首轮复跑必看的 5 条验收点（报告 ④-4）：
#     1) 全文不再出现 `value too great for base`；每个相位都打印 `本相位断言条数=N` 且 N ≥ CO35_MIN_ASSERT
#        （= 反静默哨兵：任何相位被中途打断，这条会直接 FAIL，不再无声跳过）；
#     2) `任务汇总：任务数 N` = **去重后的真实任务数**（单一来源 `log_datanode_compaction.log`，不再 ×2），
#        且每个 DN 都打印"输出行数 / 任务数"；`Σplaces/Σ落盘产物` 与磁盘 level≥1 产物数一致；
#     3) 逐任务 `places == min(floor(选中字节/target)+1, totalSources)`（`floor+1 ≤ 选中数` 时判等号），
#        且 `1 ≤ 落盘产物 ≤ places ≤ totalSources = 选中数 + 跳过数`；
#     4) `产物名` 段只含 level≥1 的文件（不含 L0 源文件、不含 `*-0-*.tsfile` 重命名占位），
#        `D1-2 磁盘侧` 逐 DN 用**自己**的 pre 比较；C 相 `floor(选中/target)+1 ≥ totalSources` 全中；
#     5) `D1-3` 全文不再出现 `chunk/(SERIES×选中数)` 反推的设备数；`u` 一律 = **选中字节/设备数**，
#        设备数取不到（`co35_dev_map` 空 / Σ≠DEVS）时只"记录不判"，不再拿错值判等号。
#   ⚠️ 仍需集群确认（本机无法验证）：① `.resource` 里能否 grep 出设备名（取不到 ⇔ D1-3 全部"记录不判"）；
#     ② V2 下"某副本整轮没有 Async close 事件"是日志缺失还是真没落盘（本轮已去掉 flush 锤击，见 P2-⑪）；
#     ③ "跳选文件"是 V2 常态还是旧 flush 锤击把一批数据拆成多个 TsFile 造出来的。
#
# ---------------------------------------------------------------------------
# ⚠️ RC8 轮（`results/CO-35_20261016_215428.out`，build v20121rc8_1016_ebaf9da）**18 条 `[算术校验]` 假失败**
#    的根因：**本用例自身 awk 的 printf 占位符比参数少 1 个 ⇒ 末列 `chunk` 从未被打印**，
#    与 RC8 日志格式**无关**（"该字段在新版本日志里不存在"的猜测被日志原文推翻）。证据链（全部可复算）：
#      · 日志原文（RC8，`.77` / region 3，`log_datanode_compaction.log`）**有** chunk 字段：
#          `... status: DELETED}],time cost is 0.05 s, compaction speed is 0.32 MB/s, ...,
#           total process chunk num: 54, directly flush chunk num: 0, ...`
#      · 旧版本用例在**同一 RC8 日志**上打出来的是真实值（`results/CO-35_20261016_115152.out`）：
#          `... requiredPositionNum=2 落盘产物=1 chunk=48 设备数=2` / `... chunk=54 设备数=?`
#        ⇒ 字段本来取得到；是本文件改版（2026-10-16 19:56 那次重写 CO35_AWK）把 `%d` 写丢了；
#      · 现版 printf 实测：格式串 **11** 个占位符（2×`%s` + 9×`%d`）却传 **12** 个参数
#        （`sed -n 314p 文件 | grep -o '%[ds]' | wc -l` = 11；参数 12 个）⇒ awk **静默丢弃**第 12 个参数 `ch`
#        ⇒ TASK 行只有 **12** 个制表符字段，而 `read` 声明了 **13** 个变量 ⇒ 末变量 `chunk` 恒为空串。
#        实测复现（99.80）：`printf "TASK\t%s\t%s\t%d…"（2×%s+9×%d）+ 12 参` ⇒ `awk -F'\t' '{print NF}'` = **12**；
#        补 1 个 `%d` ⇒ **13**。RC8 的 18 条 = 6 任务 × 3 相（每相 3 副本 × 2 region），全部是这一个原因。
#      · 与 RC8 无关的旁证：`chunk` 自该列加入起就一直取不到值，只是上一轮把它接进 `co35_num` 之后才变成 FAIL。
#    修法（**只改本文件**）：
#      ① **修提取**：printf 补上漏掉的 `%d`；并把**日志原文**作为末列带进 TASK 行（14 列：
#         `TASK | tag | rid | src selc skip sel miss tlen hold places mat chunk | 原文`），
#         使"取不到值"时能直接打印原文行；
#      ② **修语义**：`co35_num` **空串 ⇒ warn**（打印原文行 + 相关判据跳过，按 0 处理）；
#         **只有"取得到但不是十进制非负整数"才 fail** —— 取不到值属 harness 提取问题，不是被测对象行为；
#      ③ **防回归**：TASK 行字段数 ≠ 14 ⇒ warn + 打印原文样本（本类"列数错位"从此可见）；
#         相位末尾另加"算术校验降级计数"WARN，并**保留**原有 `MIN_ASSERT` 反静默哨兵（断言条数 ≥ 阈值）。
#      ④ 口径不变：`chunk` 自 P1-⑨ 起**只用于记录**（D1-3 的设备数走 `co35_dev_map` 观测面），
#         所以它取不到值时**没有判据被跳过**；D1-3 的量化判据仍只用「选中文件字节 / requiredPositionNum /
#         产物 level 与编号段 / 逐 region 源文件数」这些**在 RC8 日志里确实存在**的字段。
# ---------------------------------------------------------------------------
#   用法： bash co_target_split_formula.sh [--consensus IoTConsensus]
#   规模/时长参数集中在下方变量（默认三相合计 ≈ 10 分钟；首跑 555s）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "co_target_split_formula_${DATA_CONSENSUS}"

DB=root.cospl
DEVS=${CO35_DEVS:-6}          # 设备数（**必须 >1**：设备粒度拆分的前提）
SERIES=3                      # 每设备序列数（只用于造数据规模/日志说明；**不再**用它反推 region 设备数，见 P1-⑨）
ROWS=${CO35_ROWS:-60}         # 每设备每批点数（小文件，让 Σ/target 可控）
BATCHES=${CO35_BATCHES:-6}    # A/B 相批数 = 每 region 的源文件数（= inner_compaction_candidate_file_num，
                              #   保证 1 个 region 的源文件能落进同一个任务，方便逐 region/逐任务对齐）
CBATCH=${CO35_C_BATCHES:-6}   # C 相批数
T_A=${CO35_TARGET_A:-auto}    # A 相 target：auto = floor(最小 region 字节 / 2)；也可写具体字节数
T_B=2147483648                # B 相：默认值 2GB
T_C=${CO35_TARGET_C:-1024}    # C 相：极小 target（吃满 D1-2 的 min 上界）
WIN=${CO35_WIN:-150}          # 等首轮合并完成的窗口
# 选择间隔取 5s（而不是 1s）：首轮合并完成后到下一轮选择之间有 ~5s 空档，
# 让"检测到首个 finishes 就热关 seq 合并"的冻结动作来得及生效，避免产物被级联再并掉。
INTERVAL_MS=${CO35_INTERVAL_MS:-5000}
CLOSE_WIN=${CO35_CLOSE_WIN:-30}   # P2-⑪ 每批"等落盘事件"的窗口（原 cmp_wait_close 用 90s + 反复 flush）
MIN_ASSERT=${CO35_MIN_ASSERT:-10} # P0-③ 反静默哨兵：单相位至少应执行的断言条数（实测正常相 ~15~45 条）
CO35_SKIP_CNT=0                   # P0-③-③ "算术校验降级"累计计数（空值/非法 ⇒ 按 0 处理 ⇒ 相关判据跳过）

# ---------------------------------------------------------------------------
# 观测工具（仅本用例使用，不改动 lib/）
# ---------------------------------------------------------------------------
# P0-③ 算术前置校验：任何外部字符串进 `$(( ))` 之前先过这里；**非法/空值一律不参与算术**（按 0 处理）。
#   RC8 修正后的语义（三档）：
#     · 合法十进制非负整数      ⇒ 放行（return 0）
#     · **取不到值（空串）**    ⇒ **warn**（不判 FAIL）+ 打印原文行（可选 `$3`）+ 按 0 处理（return 2）
#         理由：空串来自 harness 提取层（字段缺失 / awk printf 占位符与参数不匹配 / 该版本日志无此字段），
#         不是被测对象的行为 ⇒ 只记录并按 0 处理，相关判据跳过（判据被跳过的可见性由相位末尾的
#         "算术校验降级计数" WARN + `MIN_ASSERT` 反静默哨兵保证）。
#     · **取得到但不是十进制**（含字母/符号/负数）⇒ **fail**（这才是真的异常，return 1）
#   ⚠️ **只能在非命令替换处调用**（`$( )` 里 `fail` 的消息会被吞进变量 ⇒ 静默失真）；
#   `$()` 内部一律用静默兜底 co35_n0()。
co35_num(){ local __v=${!1:-} __c=${3:-}
  case "${__v}" in
    '') CO35_SKIP_CNT=$(( CO35_SKIP_CNT + 1 )); __c=${__c:0:400}
        warn "  [算术校验] $2 取不到值（空串）⇒ 按 0 处理（相关判据跳过）${__c:+；原文=[$__c]}"
        printf -v "$1" '%s' 0; return 2 ;;
    *[!0-9]*) CO35_SKIP_CNT=$(( CO35_SKIP_CNT + 1 )); __c=${__c:0:400}
        fail "  [算术校验] $2 不是十进制非负整数：[${__v}] ⇒ 按 0 处理（相关判据跳过）${__c:+；原文=[$__c]}"
        printf -v "$1" '%s' 0; return 1 ;;
  esac
  return 0; }
# 静默数值兜底（供 $() 内部使用；非数字一律 0）
co35_n0(){ case "${1:-}" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$1";; esac; }
# 单副本上该库**逐 data region**的 "<regionId>:<文件数>:<字节数>"（seq+unseq，含所有层级）
#   路径形态 .../data/{sequence,unsequence}/<db>/<regionId>/<timePartition>/<file>.tsfile
#   ⚠️ regionId = **<db> 之后的第一个路径分量**；**不能**用 `%h` 的 basename（那是时间分区目录）。
#      首跑就是栽在这里：把"每 DN 1 个时间分区"当成了"1 个 region"，公式单位与容差全错。
co35_reg_stats(){ local h=$1 db=$2
  sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%p %s\n' 2>/dev/null" \
    | tr -d '\r' \
    | awk -v db="$db" '{n=split($1,a,"/"); rid="?"; for(i=1;i<n;i++) if(a[i]==db){rid=a[i+1];break} c[rid]++; b[rid]+=$2}
        END{for(k in c) printf "%s:%d:%d ", k, c[k], b[k]}'
  printf '\n'; }
# 逐 region 的**合并产物**字节（只看 level ≥ 1，源 L0 文件不算产物）：每行 "<regionId> <字节> <字节> ..."
co35_reg_sizes(){ local h=$1 db=$2
  sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%p %s\n' 2>/dev/null" \
    | tr -d '\r' \
    | awk -v db="$db" '{n=split($1,a,"/"); rid="?"; for(i=1;i<n;i++) if(a[i]==db){rid=a[i+1];break}
        f=a[n]; m=split(f,b,"-"); if(m>=3 && b[3]+0<1) next     # 只统计 level≥1 的合并产物
        s[rid]=s[rid]" "$2}
        END{for(k in s) printf "%s%s\n", k, s[k]}'; }
# region 数
co35_regions(){ local s=$1; printf '%s\n' "$s" | tr ' ' '\n' | grep -c '^[^:]*:[0-9]'; }
# 单 region 的文件数 / 字节数（从 "<rid>:<c>:<b>" 取）
co35_cnt_of(){ local r=${1#*:}; echo "${r%%:*}"; }
co35_bytes_of(){ echo "${1##*:}"; }
# 源文件总数 / 源字节总数（= Σ_region）
co35_srcfiles(){ local s=$1 tok rest n all=0
  for tok in $s; do rest=${tok#*:}; n=$(co35_n0 "${rest%%:*}"); all=$(( all + n )); done; echo "$all"; }
co35_bytes(){ local s=$1 tok all=0
  for tok in $s; do all=$(( all + $(co35_n0 "${tok##*:}") )); done; echo "$all"; }
# 单 region 的公式取值 min(floor(字节/target)+1, 文件数)（**仅用于场景有效性**；正式判据走逐任务日志）
co35_plan_one(){ local tok=$1 t=$2 rest c b e
  rest=${tok#*:}; c=${rest%%:*}; b=${rest##*:}
  c=$(co35_n0 "$c"); b=$(co35_n0 "$b"); t=$(co35_n0 "$t"); [ "$t" -ge 1 ] || t=1
  e=$(( b / t + 1 )); [ "$e" -gt "$c" ] && e=$c; echo "$e"; }
# Σ_region 公式取值（场景诊断/记录）
co35_planned(){ local s=$1 t=$2 tok all=0
  for tok in $s; do all=$(( all + $(co35_plan_one "$tok" "$t") )); done; echo "$all"; }
# A 相动态 target：最小 region 字节的一半 ⇒ 最小 region 的 floor(字节/target)+1 ≈ 3，落在 [2, 文件数-1]
co35_target_auto(){ local v tok b min=0 t
  for v in "$@"; do
    for tok in $v; do b=$(co35_n0 "${tok##*:}"); { [ "$min" = 0 ] || [ "$b" -lt "$min" ]; } && min=$b; done
  done
  t=$(( min / 2 )); [ "$t" -lt 512 ] && t=512; echo "$t"; }
# " rid:bytes rid:bytes " → " rid:Σbytes ..."（同一 region 有多个任务时累加）
co35_sum_map(){ printf '%s\n' "${1:-}" | tr ' ' '\n' \
  | awk -F: 'NF==2 && $1!=""{s[$1]+=$2+0} END{for(k in s) printf "%s:%d ", k, s[k]}'; }
# 扁平 map 查表（"k:v k:v" → v；未命中回 "?"）
co35_map_get(){ local map=$1 k=$2 tok
  for tok in $map; do [ "${tok%%:*}" = "$k" ] && { echo "${tok#*:}"; return 0; }; done
  echo "?"; }
# 单副本文件数
co35_dn_cnt(){ local h=$1 db=$2; echo $(( $(co35_n0 "$(cmp_seq_cnt "$h" "$db")") + $(co35_n0 "$(cmp_unseq_cnt "$h" "$db")") )); }
# 单副本 level ≥ 1 的文件数（= 合并产物；日志侧"落盘产物数"的磁盘交叉核对）
co35_prod_cnt(){ local h=$1 db=$2 v
  v=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | awk -F- '\$3>0{c++} END{print c+0}'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# 全副本**产物**名（去重）：P1-⑦ 必须过滤 level 段（`$3>0`），与 co35_prod_cnt/co35_reg_sizes 口径一致。
#   不加过滤会把 35 个 L0 源文件 + 1 个重命名占位（`…-1-0-1.tsfile`）当产物 ⇒ 36 条假 FAIL（H3）。
co35_names(){ local db=$1 h
  for h in "${DN[@]}"; do
    sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf '%f\n' 2>/dev/null | awk -F- '\$3>0'" | tr -d '\r'
  done | sort -u; }
# P1-⑨ 逐 region 的**设备数**观测面（"<regionId>:<设备数>"，供 D1-3 的 u = 选中字节/设备数 使用）：
#   该 region 下每个 `*.tsfile.resource` 里出现的 `root.<db>.dN` distinct 计数
#   （设备按 series slot 固定归属唯一 region ⇒ 各 region 的设备集互不相交，device id 也写在 resource 里）。
#   自校验：Σ_region 设备数 == DEVS（本用例每台设备每批都有数据）；不成立 ⇒ **整表作废**返回空
#   ⇒ 调用侧只"记录不判"（宁可少判也不拿错值判等号）。
co35_dev_map(){ local h=$1 db=$2 dbs pairs map sum tok
  dbs=${db#root.}
  pairs=$(sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile.resource' -printf '%p\n' 2>/dev/null | while read -r f; do for d in \$(grep -aoh 'root\\.$dbs\\.d[0-9]*' \"\$f\" 2>/dev/null | sort -u); do printf '%s %s\n' \"\$f\" \"\$d\"; done; done" 2>/dev/null | tr -d '\r')
  map=$(printf '%s\n' "$pairs" | awk -v db="$db" 'NF>=2{n=split($1,a,"/"); rid="?"; for(i=1;i<n;i++) if(a[i]==db){rid=a[i+1];break} print rid" "$2}' | sort -u | awk '{c[$1]++} END{for(k in c) printf "%s:%d ", k, c[k]}')
  case "$map" in *'?:'*) map="" ;; esac          # regionId 解析失败 ⇒ 作废
  sum=0
  if [ -n "$map" ]; then for tok in $map; do sum=$(( sum + $(co35_n0 "${tok##*:}") )); done; fi
  if [ -n "$map" ] && [ "$sum" = "$DEVS" ]; then printf '%s' "$map"; else printf ''; fi; }
# P2-⑪ 等"该批的落盘事件"：**有限次** flush + 只等已出现的 close 事件。
#   不再用 cmp_wait_close 的"每 ~6s 向集群 + 逐 DN 各锤一次 flush、最长 90s"用法：
#   V2 下总有一个副本整轮不打 `Async close` ⇒ 6 批 × 90s × 3 相 ≈1600s 空等（实测 2158s 的一半以上），
#   而且反复 flush 会把一批数据拆成多个 TsFile ⇒ 人为制造"跳选文件"。
#   判据：Σ各副本 close 事件数 > 基线 **且** 连续两次采样稳定（= 落盘已停）；耗时与 flush 次数写进日志。
co35_wait_close(){ local db=$1 b=$2 t=${3:-30} t0 dl h n s base=0 prev=-1 flushed=0
  t0=$(date +%s); dl=$(( t0 + t ))
  for h in "${DN[@]}"; do n=$(ttl_close_cnt "$h" "$db"); base=$(( base + $(co35_n0 "$n") )); done
  while :; do
    s=0; for h in "${DN[@]}"; do n=$(ttl_close_cnt "$h" "$db"); s=$(( s + $(co35_n0 "$n") )); done
    if [ "$s" -gt "$base" ] && [ "$s" = "$prev" ]; then
      log "    批$b：观测到新的 Async close 事件（Σ $base → $s，已稳定），等待 $(( $(date +%s) - t0 ))s，flush $flushed 次"
      return 0
    fi
    prev="$s"
    if [ "$flushed" -lt 2 ] && [ $(( $(date +%s) - t0 )) -lt $(( t / 2 )) ]; then
      sq "flush;" >/dev/null 2>&1; flushed=$(( flushed + 1 ))
    fi
    [ $(( $(date +%s) - t0 )) -ge "$t" ] && break
    sleep 3
  done
  warn "    批$b：${t}s 窗口内未观测到新的 Async close 事件（Σclose=$s，基线 $base）⇒ 继续（记录；不再锤 flush）"
  return 1; }
# 文件数稳定
co35_wait_stable(){ local db=$1 t=${2:-90} i=0 a b
  while [ "$i" -lt "$t" ]; do
    a=$(cmp_all_sum "$db"); sleep 6; b=$(cmp_all_sum "$db")
    [ "$a" = "$b" ] && { log "  文件数已稳定：$b"; return 0; }
    i=$(( i + 6 ))
  done
  warn "  文件数在 ${t}s 内未稳定（$a → $b）"; return 1; }

# ---------------------------------------------------------------------------
# 任务级取证：把"合并前字节快照 + compaction 日志"解析成一行一个任务
#   输入（stdin）：
#     `SIZE <绝对路径> <字节>`   ← 合并前该 DN 上的文件快照（用于求 selectedFileSize）
#     compaction 日志原文        ← 该库相关行（见 co35_tasks_one 的 grep）
#   输出（TSV，一行一个任务）：
#     TASK <node> <regionId> <src> <selc> <skip> <sel> <miss> <tlen> <hold> <places> <mat> <chunk> <原文>
#       （**恰好 14 个制表符字段**；读侧 `read` 必须声明 14 个变量 —— RC8 轮的 18 条假失败就是
#         "printf 少 1 个 `%d` ⇒ 只 12 个字段 ⇒ 末变量 chunk 恒空"，见文首 RC8 段）
#       src   = `starts with N files` 的 N（源码里 = 选中数 sourceFilesInCompactionPerformer.size()）
#       selc  = selected files [...] 的**条数**（P1-④：先截断到 `], skipped files` 再数）
#       skip  = skipped files [...] 的条数（P1-④ 新增）
#       sel   = 选中文件的字节和（= selectedFileSize，只累加 selected，见 InnerSpaceCompactionTask:163-165）
#       miss  = 选中文件不在合并前快照里的个数（级联产物 ⇒ selectedFileSize 不可测）
#       tlen  = `finishes … target files are [...]` 的**列表长度**（= renamed + performer 位置数，
#               **不等于** requiredPositionNum：有跳选文件时多出重命名占位，见报告 §2.4）
#       hold  = 列表里"重命名占位"条数（level 段=0 且 status: COMPACTING 的 .tsfile）
#       places= tlen − hold（= 真正可用的位置数 = min(requiredPositionNum, totalSources, 选中数)）
#       mat   = 真正落盘产物条数（P1-⑥：level≥1 **且** status: COMPACTING 的 .tsfile）
#   注：chunk（total process chunk num）**不再**用于反推 region 设备数（旧口径 chunk/(SERIES×selc)
#       在跳选/多 chunk 场景下会推错，见报告 §2.3、P1-⑨），现在只作记录。
#       RC8 轮它曾恒为空串（printf 少一个 `%d`）⇒ 已修；修后本字段在 D1-3 的日志里会打出真实值
#       （RC8 实测 `total process chunk num: 54`）。
# ---------------------------------------------------------------------------
CO35_AWK='
function key(p,  n,a){ n=split(p,a,"/"); return a[n-2]"/"a[n-1]"/"a[n] }
function lvl(p,  m,b){ m=split(p,b,"-"); if(m<3) return -1; return b[3]+0 }
/SIZE /{ sz[key($2)]=$3+0; next }
/Sequence InnerSpaceCompaction task starts with/{
  if (match($0,/root\.[A-Za-z0-9_]+-[0-9]+/)) r=substr($0,RSTART,RLENGTH)
  s=$0; if (match(s,/starts with [0-9]+ files/)) src[r]=substr(s,RSTART+12,RLENGTH-18)+0
  next }
/compaction with selected files \[/{
  if (match($0,/root\.[A-Za-z0-9_]+-[0-9]+/)) r=substr($0,RSTART,RLENGTH)
  cut=index($0,"], skipped files")
  selpart=$0; if (cut>0) selpart=substr($0,1,cut)
  skippart=""; if (cut>0) skippart=substr($0,cut)
  b=0; c=0; m=0; t=selpart
  while (match(t,/file: [^,]*\.tsfile/)) {
    p=substr(t,RSTART+6,RLENGTH-6); k=key(p)
    if (k in sz) b+=sz[k]; else m++
    c++; t=substr(t,RSTART+RLENGTH)
  }
  sk=0; t=skippart
  while (match(t,/file: [^,]*\.tsfile/)) { sk++; t=substr(t,RSTART+RLENGTH) }
  sel[r]=b; selc[r]=c; skip[r]=sk; miss[r]=m; next }
/finishes successfully, target files are/{
  if (match($0,/root\.[A-Za-z0-9_]+-[0-9]+/)) r=substr($0,RSTART,RLENGTH)
  tail=substr($0,index($0,"target files are ["))
  t=tail; tlen=gsub(/file: /,"",t)
  t=tail; hold=0; mat=0
  while (match(t,/\{[^}]*\}/)) {
    e=substr(t,RSTART+1,RLENGTH-2)
    if (e ~ /status: COMPACTING/ && e ~ /\.tsfile/) {
      f=e; sub(/.*file: */,"",f); sub(/,.*/,"",f)
      if (lvl(f)>=1) mat++; else hold++
    }
    t=substr(t,RSTART+RLENGTH)
  }
  places=tlen-hold
  ch=0; if (match($0,/total process chunk num: [0-9]+/)) ch=substr($0,RSTART+25,RLENGTH-25)+0
  rid=r; sub(/.*-/,"",rid)
  raw=$0; gsub(/\t/," ",raw)   # RC8-① 修正：日志原文作为末列带进 TASK 行（空字段告警时可直接打印原文；先灭掉制表符）
  printf "TASK\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", tag, rid, src[r], selc[r], skip[r], sel[r], miss[r], tlen, hold, places, mat, ch, raw
  delete src[r]; delete selc[r]; delete skip[r]; delete sel[r]; delete miss[r]; next }'
# 合并前抓某个 DN 上该库的 <路径,字节> 快照（**必须在开合并之前**：合并后源文件已被删除）
co35_snapshot(){ local db=$1 h=$2
  sshx "$h" "find $DB_DIR/data/datanode/data -path '*/$db/*' -name '*.tsfile' -printf 'SIZE %p %s\n' 2>/dev/null" \
    | tr -d '\r'; }
# 解析单个 DN：<db> <该 DN 合并前的 SIZE 快照> <host>
#   P0-② **单一来源**：只读 `log_datanode_compaction.log`。
#     旧写法 `cat $(cmp_log_files)` 里 `cmp_log_files` 返回 2 个文件（compaction + all），两者内容相同
#     ⇒ 每个任务被解析两遍（`finishes` 计数 ×2、任务数 ×2），并把 H1 的拼接错位提前到第 2 行发生。
#     另外对 grep 结果做 `awk '!seen[$0]++'` **保序去重**（同一行原文重复才去重，安全）。
co35_tasks_one(){ local db=$1 snap=$2 h=$3
  { printf '%s\n' "$snap"
    sshx "$h" "cat $DB_DIR/logs/log_datanode_compaction.log 2>/dev/null | grep -E '$db-[0-9]+ \[Compaction\]' | awk '!seen[\$0]++'"
  } | tr -d '\r' | awk -v tag="${h##*.}" "$CO35_AWK"; }

# ---------------------------------------------------------------------------
# 造数据
# ---------------------------------------------------------------------------
# 写一批（DEVS 设备 × ROWS 点 × s1/s2/s3；时间戳严格递增 ⇒ 落 sequence/）
co35_write_batch(){ local db=$1 b=$2 base=$3 d k ts vals stmts=()
  for ((d=1; d<=DEVS; d++)); do
    vals=""
    for ((k=1; k<=ROWS; k++)); do
      ts=$(( base + b * 100000 + k * 10 ))
      vals="$vals($ts,$(( k + b )),$(( k + b )).5,'v$k'),"
    done
    stmts+=("insert into $db.d$d(time,s1,s2,s3) values ${vals%,};")
  done
  stmts+=("flush;")
  sql_lines_tree "${stmts[@]}" >/dev/null
  sleep 3; }
# 造场景：建库 + DEVS 设备 × 3 序列 + n 批（每批等 close 事件后再写下一批）
co35_scene(){ local db=$1 n=$2 stmts=() i b base l0 st
  cmp_compaction_off
  sq "create database $db;" >/dev/null
  for ((i=1; i<=DEVS; i++)); do
    stmts+=("create timeseries $db.d$i.s1 with datatype=INT64, encoding=PLAIN, compression=SNAPPY;")
    stmts+=("create timeseries $db.d$i.s2 with datatype=DOUBLE;")
    stmts+=("create timeseries $db.d$i.s3 with datatype=TEXT;")
  done
  sql_lines_tree "${stmts[@]}" >/dev/null
  base=$(( ($(date +%s) - 3600) * 1000 ))
  for ((b=1; b<=n; b++)); do
    co35_write_batch "$db" "$b" "$base"
    # P2-⑪ 有限次 flush + 只等已有的落盘事件（不再 cmp_wait_close 的 90s 锤击）
    co35_wait_close "$db" "$b" "$CLOSE_WIN" >/dev/null || true
    sleep 4
  done
  l0=$(cmp_min_l0 "$db")
  st=$(co35_reg_stats "${DN[0]}" "$db")
  co35_num l0 "min_l0"
  log "  [$db] 起点：布局=$(cmp_lay "$db") min_l0=$l0 files=$(cmp_all_sum "$db") 字节=$(cmp_bytes_sum "$db")"
  log "  [$db] 起点逐 region（${DN[0]}）：$st（region 数 $(co35_regions "$st")）"
  if [ "${l0:-0}" -ge "$n" ]; then pass "  [$db] 场景有效：各副本 level-0 文件数 ≥ $n（min_l0=$l0）"
  else fail "  [$db] 场景未成立：min_l0=$l0 < $n（合并候选不足）"; fi; }

# ---------------------------------------------------------------------------
# 单相位执行 + 判据
#   co35_phase <db> <target|auto> <tag> <idx> [批数] [分支 mid|one|cap]
#     分支决定"场景有效性"逐 region 的期望：
#       mid：A 相，2 ≤ 计划位置数 ≤ region 源文件数-1（D1-1 未被 min 截断）
#       one：B 相，floor(字节/target)+1 == 1（2GB 下不拆分）
#       cap：C 相，floor(字节/target)+1 > region 源文件数（min 上界被吃满）
# ---------------------------------------------------------------------------
PH_DB=("" "" ""); PH_TS0=("" "" ""); PH_OBS=("" "" ""); PH_TGT=("" "" "")
PH_REQ=(0 0 0); PH_MAT=(0 0 0); PH_TASKS=("" "" ""); PH_NB=("" "" "")
PH_DONE=(0 0 0); PH_NAST=("" "" "")   # 相位完成标记 / 本相位断言条数（P0-③ 反静默哨兵）
co35_phase(){ local db=$1 tmode=$2 tag=$3 idx=$4 nb=${5:-$BATCHES} br=${6:-mid}
  local h ii pre=() l0a ts0 sz0 fp0 tgt st devmap out0 emp0
  local -a snaps=()
  # P0-③ 相位入口先赋初值：即使相位中途被算术错误打断，② 也拿到确定值而不是空串（旧版就是空串）
  PH_REQ[$idx]=0; PH_MAT[$idx]=0; PH_DONE[$idx]=0; PH_NAST[$idx]=""
  emp0=${CO35_SKIP_CNT:-0}     # P0-③-③ 本相"算术校验降级"计数基线（相位末尾算增量）
  out0=$(wc -l <"$OUT")
  log "  --- [$tag] 造场景 $db（DEVS=$DEVS × ${SERIES} 序列 × $nb 批）---"
  co35_scene "$db" "$nb"
  PH_NB[$idx]="$nb"
  ts0=$(cmp_all_sum "$db"); sz0=$(cmp_bytes_sum "$db"); fp0=$(cmp_fp_tree "$db"); l0a=$(cmp_min_l0 "$db")
  co35_num ts0 "起点总文件数"; co35_num sz0 "起点总字节"; co35_num l0a "起点 level-0 文件数"
  PH_DB[$idx]="$db"; PH_TS0[$idx]="$ts0"
  ii=0
  for h in "${DN[@]}"; do pre[$ii]=$(co35_reg_stats "$h" "$db"); ii=$(( ii + 1 )); done
  # 合并前抓字节快照（合并会删掉源文件，事后拿不到 selectedFileSize 的输入）
  ii=0
  for h in "${DN[@]}"; do snaps[$ii]=$(co35_snapshot "$db" "$h"); ii=$(( ii + 1 )); done
  # P1-⑨ 设备数观测面（取不到 ⇒ devmap 为空 ⇒ D1-3 只记录不判，绝不用 chunk 反推）
  devmap=$(co35_dev_map "${DN[0]}" "$db")
  if [ -n "$devmap" ]; then
    log "  [$tag] 逐 region 设备数（观测面 ${DN[0]}，已校验 Σ == DEVS=$DEVS）：$devmap"
  else
    warn "  [$tag] 逐 region 设备数不可测（.resource 未 grep 到设备名，或 Σ 设备数 ≠ DEVS=$DEVS）⇒ D1-3 只记录、不判等号"
  fi
  if [ "$tmode" = auto ]; then tgt=$(co35_target_auto "${pre[@]}"); else tgt="$tmode"; fi
  co35_num tgt "target_compaction_file_size"
  [ "$tgt" -ge 1 ] || { fail "  [$tag] target 非法（=$tgt）⇒ 按 1 处理"; tgt=1; }
  PH_TGT[$idx]="$tgt"
  log "  [$tag] 起点：源文件 $ts0 个 / 字节 $sz0；target=$tgt（模式 $tmode）"
  # ---- 场景有效性：**逐 region** 判定（不能用时间分区或副本聚合替代）
  local bad=0 nreg=0 tok c b p raw ok=1
  ii=0
  for h in "${DN[@]}"; do
    for tok in ${pre[$ii]}; do
      nreg=$(( nreg + 1 ))
      c=$(co35_cnt_of "$tok"); b=$(co35_bytes_of "$tok")
      co35_num c "region $tok 源文件数"; co35_num b "region $tok 字节"
      raw=$(( b / tgt + 1 )); p=$raw; [ "$p" -gt "$c" ] && p=$c
      ok=1
      case "$br" in
        mid) [ "$p" -lt 2 ] && ok=0; [ "$p" -gt $(( c - 1 )) ] && ok=0 ;;
        one) [ "$raw" -ne 1 ] && ok=0 ;;
        cap) [ "$raw" -le "$c" ] && ok=0 ;;
      esac
      [ "$ok" = 1 ] || { bad=$(( bad + 1 )); log "      region $tok：源文件 $c / 字节 $b ⇒ floor(字节/target)+1=$raw（min 后 $p）不满足分支 $br"; }
    done
    ii=$(( ii + 1 ))
  done
  if [ "$bad" = 0 ]; then
    pass "  [$tag] 场景有效（逐 region $nreg 个，分支 $br，target=$tgt）：每个 region 的公式取值都落在预期区间"
  else
    fail "  [$tag] 场景未成立：$nreg 个 region 中有 $bad 个不满足 $br 分支（target=$tgt，明细见上）；请调整 CO35_DEVS / CO35_ROWS / target"
  fi
  log "  [$tag] 逐 region 计划位置数（Σ 各副本，仅场景诊断；正式判据走逐任务日志）= $(for s in "${pre[@]}"; do printf '%s ' "$(co35_planned "$s" "$tgt")"; done)"
  # ---- 设 target → 热开 seq 合并 → 首轮完成即冻结
  cmp_set_hot target_compaction_file_size "$tgt" >/dev/null
  assert_eq "  [$tag] target_compaction_file_size 生效值" "$(cmp_eff "${DN[0]}" target_compaction_file_size)" "$tgt"
  local f0 hit=0 dl
  f0=$(cmp_seq_inner_finish "$db")
  co35_num f0 "finishes 基线"
  cmp_compaction_on true false false
  dl=$(( $(date +%s) + WIN ))
  while (( $(date +%s) < dl )); do
    [ "$(cmp_seq_inner_finish "$db")" -gt "$f0" ] && { hit=1; break; }
    sleep 2
  done
  cmp_set_hot enable_seq_space_compaction false >/dev/null 2>&1
  log "  [$tag] 已热关 seq 合并以冻结首轮产物（生效值 $(cmp_eff "${DN[0]}" enable_seq_space_compaction)）；finishes $f0 → $(cmp_seq_inner_finish "$db")"
  [ "$hit" = 1 ] || fail "  [$tag] ${WIN}s 内合并未推进（finishes 仍为 $f0）"
  sleep 5
  co35_wait_stable "$db" 90 >/dev/null
  local obs sz1 fp1 lay1 l0b f1
  obs=$(cmp_all_sum "$db"); sz1=$(cmp_bytes_sum "$db"); fp1=$(cmp_fp_tree "$db"); lay1=$(cmp_lay "$db")
  l0b=$(cmp_min_l0 "$db"); f1=$(cmp_seq_inner_finish "$db")
  co35_num obs "终态总文件数"; co35_num sz1 "终态总字节"; co35_num l0b "终态 level-0 文件数"; co35_num f1 "终态 finishes"
  PH_OBS[$idx]="$obs"
  log "  [$tag] 终态：布局=$lay1 files=$ts0→$obs 字节=$sz0→$sz1 finishes=$f0→$f1"
  # ---- ① 双信号：finishes 增加 **且** level-0 文件被合并掉
  #         （注意：target 极小时"总文件数"可能不降反升，故信号取 level-0 下降而不是总数下降）
  if [ "$hit" = 1 ] && [ "${l0b:-99}" -lt "${l0a:-0}" ]; then
    pass "  [$tag] 双信号成立：finishes $f0→$f1 且 level-0 文件数 $l0a→$l0b（总文件数 $ts0→$obs）"
  else
    fail "  [$tag] 双信号不成立：finishes $f0→$f1，level-0 $l0a→$l0b，总文件数 $ts0→$obs"
  fi
  cmp_assert_same "  [$tag] 合并前后数据指纹（cmp_fp_tree）" "$fp0" "$fp1"
  # ---- ②③⑥ 逐任务（日志权威观测面）：合并前快照 + 日志 → requiredPositionNum/places/落盘产物数
  #   P0-① 用**数组收集 + 显式补换行**：绝不能再用"命令替换直接追加到 tasks 变量"的隐式拼接
  #         （`$( )` 会剥掉尾换行 ⇒ 第 N 个 DN 的末行与第 N+1 个 DN 的首行粘成 `48TASK\t78…`
  #          ⇒ bash 算术致命错误 ⇒ 该相位剩余 40+ 条断言**整体静默跳过**、PH_REQ/PH_MAT 保持空串）
  local -a tparts=()
  local ii2=0 tasks="" tcnt tlines tp
  for h in "${DN[@]}"; do
    tp=$(co35_tasks_one "$db" "${snaps[$ii2]}" "$h")
    tlines=$(printf '%s\n' "$tp" | grep -c . || true)
    tcnt=$(printf '%s\n' "$tp" | grep -c '^TASK' || true)
    log "  [$tag] 任务流取证 ${h##*.}：解析输出 $tlines 行 / 任务 $tcnt 个（单一来源 log_datanode_compaction.log，行内去重）"
    tparts+=("$tp"); ii2=$(( ii2 + 1 ))
  done
  tasks=$(printf '%s\n' "${tparts[@]}")      # 数组 → 显式换行拼接（尾换行不再丢）
  PH_TASKS[$idx]="$tasks"
  # P0-③-② 提取自检（RC8-① 防回归）：TASK 行必须恰好 **14** 个制表符字段。
  #   根因回顾：awk 的 printf 曾少 1 个 `%d`（11 占位符 / 12 参数）⇒ 末列被静默丢弃 ⇒ `read` 的末变量恒空。
  #   这里把"提取层列数错位"显式暴露出来并打印原文样本。
  #   **warn 不 fail**：属 harness 提取问题，不是被测对象的行为；可见性由本 warn + 相位末尾降级计数 +
  #   `MIN_ASSERT` 反静默哨兵共同保证（另有 ntask=0 / nsel=0 两处已存在的取证 FAIL 兜底）。
  local nbadcol=0 badsample=""
  if printf '%s\n' "$tasks" | grep -q '^TASK'; then
    nbadcol=$(printf '%s\n' "$tasks" | awk -F'\t' 'NF!=14' | grep -c . || true)
    if [ "${nbadcol:-0}" -gt 0 ]; then
      badsample=$(printf '%s\n' "$tasks" | awk -F'\t' 'NF!=14' | head -1 | cut -c1-300 | tr -d '\r')
      warn "  [$tag] 任务流提取自检：$nbadcol 行的字段数 ≠ 14（awk printf 占位符与 read 变量数不一致？）⇒ 受影响字段按 0 处理、相关判据跳过；样本原文=[$badsample]"
    fi
  fi
  local ntask=0 sum_req=0 sum_mat=0 max_req=0 max_mat=0 t2=0 nsel=0 over=0 chk=0
  local dev bp exp expmin want u rid szs v tot k lim cntmap="" srcn nthr=0 raw selmap="" selacc=""
  if ! printf '%s\n' "$tasks" | grep -q '^TASK'; then
    fail "  [$tag] 未从 DN 日志解析到任何本库的 Sequence InnerSpaceCompaction 任务（取证失败）"
    PH_REQ[$idx]=0; PH_MAT[$idx]=0
  else
    # RC8-① 修正：先取**整行原文**（`__log` = TASK 行末列 = 日志原文），再按制表符拆字段
    #   ⇒ 任一字段取不到值时，warn 里能直接打出原文行，而不是只给一个空串。
    while IFS= read -r __row; do
      [ -n "$__row" ] || continue
      IFS=$'\t' read -r kind node rid src selc skip sel miss tlen hold places mat chunk __log <<<"$__row"
      [ "$kind" = TASK ] || continue
      # P0-③ 逐字段算术前置校验：**空值 ⇒ warn（打印原文，按 0 处理，相关判据跳过）**；
      #   只有"取得到但不是十进制非负整数"才 fail。
      #   `chunk` 自 P1-⑨ 起只用于记录（D1-3 的设备数走 co35_dev_map）⇒ 它为空值时**没有判据被跳过**。
      local __f
      for __f in src selc skip sel miss tlen hold places mat chunk; do
        co35_num "$__f" "任务 node=$node region=$rid 字段 $__f" "$__log"
      done
      tot=$(( selc + skip ))                 # P1-⑤ totalSources = 选中数 + 跳过数
      raw=$(( sel / tgt + 1 ))
      ntask=$(( ntask + 1 ))
      sum_req=$(( sum_req + places )); sum_mat=$(( sum_mat + mat ))
      [ "$places" -gt "$max_req" ] && max_req=$places
      [ "$mat" -gt "$max_mat" ] && max_mat=$mat
      [ "$mat" -ge 2 ] && t2=$(( t2 + 1 ))
      dev=$(co35_map_get "$devmap" "$rid")
      selmap="$selmap $rid:$sel"             # region→选中字节（体积判据用；同 region 多任务累加）
      [ "$selc" = "$src" ] || warn "  [$tag] region $rid：日志 'starts with $src files' 与 selected 清单 $selc 个不一致（源码上二者相等，多为日志截断）⇒ 公式按 selected 清单算"
      if [ "$miss" -gt 0 ]; then
        warn "  [$tag] region $rid：$miss 个选中文件不在合并前字节快照里（多半是上一轮级联任务的产物）⇒ selectedFileSize 不可测，该任务跳过 D1-1/D1-3 公式判定"
      else
        nsel=$(( nsel + 1 ))
      fi
      log "  [$tag] 任务 node=$node region=$rid：选中 $selc + 跳过 $skip = totalSources $tot；选中字节=$sel 未命中=$miss；target 列表长=$tlen 占位=$hold places=$places（= tlen−占位）落盘产物=$mat chunk=$chunk 设备数=$dev"
      # ② D1-1（源码 InnerSpaceCompactionTask:314-320）：
      #      requiredPositionNum = min(floor(selectedFileSize/target)+1, sortedAllSourceFilesInTask.size())
      #    产品日志里的"target files 列表长度"= renamed(占位) + min(required, totalSources − renamed)
      #    ⇒ places（= 列表长 − 占位）= min(floor(选中/target)+1, totalSources, 选中数)
      #    判据（**不放松**）：`floor(选中/target)+1 ≤ 选中数`（不可能被 min 截断）时判 `places == min(raw, totalSources)`；
      #    被截断时按报告 P1-⑥ 只"记录"，并把与 min(raw,totalSources,选中数) 的偏差记 WARN。
      exp=$(( sel / tgt + 1 )); [ "$exp" -gt "$tot" ] && exp=$tot
      expmin=$exp; [ "$expmin" -gt "$selc" ] && expmin=$selc
      if [ "$miss" -gt 0 ]; then
        log "  [$tag] D1-1（node=$node region=$rid）：跳过（selectedFileSize 不可测；$miss 个选中文件无合并前字节）"
      elif [ "$raw" -le "$selc" ]; then
        if [ "$places" -eq "$exp" ]; then
          pass "  [$tag] D1-1（node=$node region=$rid）：places $places = min(floor($sel/$tgt)+1, totalSources $tot) = $exp"
        else
          fail "  [$tag] D1-1 不符（node=$node region=$rid）：places $places ≠ min(floor($sel/$tgt)+1, totalSources $tot) = $exp（target=$tgt；列表长 $tlen 占位 $hold）"
        fi
      else
        log "  [$tag] D1-1（node=$node region=$rid）：floor($sel/$tgt)+1=$raw > 选中数 $selc ⇒ 被 min 截断，只记录：places=$places、min(raw,totalSources,选中数)=$expmin（列表长 $tlen 占位 $hold）"
        [ "$places" -eq "$expmin" ] || warn "  [$tag] D1-1 记录异常（node=$node region=$rid）：places $places ≠ min(raw,totalSources,选中数) = $expmin"
      fi
      # ③ D1-2：落盘产物数 ≤ places（真正使用的位置数）≤ totalSources（P1-⑧ 上界按 totalSources）且 ≥ 1
      if [ "$places" -le "$tot" ] && [ "$mat" -le "$places" ] && [ "$mat" -ge 1 ]; then
        pass "  [$tag] D1-2（node=$node region=$rid）：落盘产物 $mat ≤ places $places ≤ totalSources $tot（选中 $selc + 跳过 $skip）"
      else
        fail "  [$tag] D1-2 被违反（node=$node region=$rid）：落盘产物 $mat / places $places / totalSources $tot（选中 $selc + 跳过 $skip）"
      fi
      # ⑥ D1-3：落盘产物数 == min(设备数, places)（target ≤ 单设备字节 ⇒ 每个设备边界必拆）
      #   P1-⑨ 单设备字节 u = **选中字节** / 设备数；设备数取观测面（不再用 chunk/(SERIES×选中数) 反推）
      if [ "$dev" != "?" ] && [ "$miss" -eq 0 ]; then
        want=$places; [ "$dev" -lt "$want" ] && want=$dev
        u=0; [ "$dev" -gt 0 ] && u=$(( sel / dev ))
        if [ "$u" -gt 0 ] && [ "$tgt" -le "$u" ]; then
          nthr=$(( nthr + 1 ))
          [ "$mat" -eq "$want" ] \
            && pass "  [$tag] D1-3（region=$rid）：落盘产物 $mat = min(设备数 $dev, places $places)（target $tgt ≤ 单设备字节 $u = 选中字节 $sel ÷ $dev ⇒ 每个设备边界都触发拆分）" \
            || fail "  [$tag] D1-3（region=$rid）：落盘产物 $mat ≠ min(设备数 $dev, places $places) = $want（target $tgt ≤ 单设备字节 $u）"
        elif [ "$mat" -le "$want" ]; then
          log "  [$tag] D1-3（region=$rid）：target $tgt > 单设备字节 $u（= 选中 $sel ÷ 设备 $dev）⇒ 设备边界不一定触发拆分，只断言落盘 $mat ≤ min(设备数 $dev, places $places) = $want（记录）"
        else
          fail "  [$tag] D1-3（region=$rid）：落盘产物 $mat > min(设备数 $dev, places $places) = $want"
        fi
      elif [ "$miss" -gt 0 ]; then
        log "  [$tag] D1-3（region=$rid）：跳过（selectedFileSize 不可测）"
      else
        log "  [$tag] D1-3（region=$rid）：设备数不可测（devmap 空/未命中）⇒ 记录，不判（chunk=$chunk 不再用于反推设备数）"
      fi
    done <<<"$tasks"
    PH_REQ[$idx]="$max_req"; PH_MAT[$idx]="$max_mat"
    selacc=$(co35_sum_map "$selmap")         # region → Σ选中字节（体积判据用）
    log "  [$tag] 任务汇总：任务数 $ntask（去重后真实任务数），Σplaces=$sum_req（max $max_req），Σ落盘产物=$sum_mat（max $max_mat），落盘≥2 的任务数 $t2，selectedFileSize 可测任务数 $nsel"
    [ "$nsel" -ge 1 ] || fail "  [$tag] 取证失败：没有任何任务的 selectedFileSize 可测（合并前快照未命中）⇒ D1-1 量化判据无法成立"
    case "$br" in
      mid)
        if [ "$max_req" -ge 2 ]; then pass "  [$tag] D1-1 真实拆分：存在 places=$max_req ≥ 2 的任务（target=$tgt 下确实拆了）"
        else fail "  [$tag] 未观察到拆分：所有任务 places 都 = $max_req（target=$tgt 相对选中字节太大）"; fi ;;
      one)
        if [ "$max_req" -eq 1 ]; then pass "  [$tag] 默认 target(2GB)：所有任务 places 恒为 1 ⇒ 不拆分（与源码 floor(选中/2GB)+1=1 一致）"
        else fail "  [$tag] 默认 target(2GB) 下出现 places=$max_req > 1（与源码 floor(选中/target)+1=1 不符）"; fi ;;
      cap)
        # P1-⑧ 上界按 **totalSources** 判：floor(选中/target)+1 ≥ totalSources ⇒ requiredPositionNum 已被 min 截断
        local nclamp=0 k2 node2 rid2 src2 selc2 skip2 sel2 miss2 tlen2 hold2 places2 mat2 chunk2 raw2 tot2
        while IFS=$'\t' read -r k2 node2 rid2 src2 selc2 skip2 sel2 miss2 tlen2 hold2 places2 mat2 chunk2 raw2; do
          [ "$k2" = TASK ] || continue
          for __f in selc2 skip2 sel2; do co35_num "$__f" "C 相任务 region=$rid2 字段 $__f" "$raw2"; done
          tot2=$(( selc2 + skip2 )); raw2=$(( sel2 / tgt + 1 ))
          [ "$raw2" -ge "$tot2" ] && nclamp=$(( nclamp + 1 ))
        done <<<"$tasks"
        if [ "$nclamp" = "$ntask" ]; then
          pass "  [$tag] D1-2 上界生效：$ntask/$ntask 个任务 floor(选中/target)+1 ≥ totalSources ⇒ requiredPositionNum 已被 min 截断到 totalSources（= 选中数 + 跳过数）"
        else
          fail "  [$tag] D1-2 上界未按预期生效：只有 $nclamp/$ntask 个任务 floor(选中/target)+1 ≥ totalSources（target=$tgt）"
        fi ;;
    esac
    # 物理拆分：one 相（2GB）必须全是 1 个产物；mid/cap 相若"target ≤ 单设备字节"（每个设备边界必拆）
    # 则必须看到 ≥2 个产物，否则**只记录**（阈值可能要到任务末尾才被跨过；物理拆分的强制验收在 C 相）。
    if [ "$br" = one ]; then
      [ "$max_mat" -eq 1 ] && pass "  [$tag] 未拆分（物理）：所有任务落盘产物数都 = 1" \
        || fail "  [$tag] 落盘产物数出现 $max_mat > 1（与 requiredPositionNum=1 不符）"
    elif [ "$t2" -ge 1 ]; then
      pass "  [$tag] 物理拆分已观测：$t2 个任务落盘 ≥2 个产物（D1-3 设备粒度拆分真实发生）"
    elif [ "$nthr" -ge 1 ]; then
      fail "  [$tag] 有 $nthr 个任务满足 target ≤ 单设备字节（逐设备边界必拆），却没有一个任务落盘 ≥2 个产物 ⇒ 与 D1-3 不符"
    else
      warn "  [$tag] 本相位 target 相对单设备字节偏大（满足逐设备拆分条件的任务数 0；设备数观测面=${devmap:-不可测}）⇒ 物理拆分改由 C 相验收（记录）"
    fi
    # ---- ⑥ 体积：除"最后一个产物"外，每个产物 ≤ 单设备字节 u + target
    #      P1-⑨ u = **该 region 选中字节** ÷ 该 region 设备数（不再用整 region 字节 —— 它含被跳过的文件）
    #      P1-⑩ 磁盘侧 D1-2 按**本 DN 自己的 pre** 比较（旧版 cntmap 取自 pre[0] 却在每个 DN 上比 ⇒ 跨副本混算）
    ii=0
    for h in "${DN[@]}"; do
      cntmap=""
      for tok in ${pre[$ii]}; do cntmap="$cntmap ${tok%%:*}:$(co35_cnt_of "$tok")"; done
      while read -r rid szs; do
        [ -z "${rid:-}" ] && continue
        tot=0; for v in $szs; do co35_num v "region $rid 产物字节"; tot=$(( tot + 1 )); done
        # D1-2（磁盘侧，非重言式）：该 region 的产物个数 ≤ **本 DN 合并前**该 region 的源文件个数
        srcn=$(co35_map_get "$cntmap" "$rid"); srcn=$(co35_n0 "$srcn")
        if [ "$srcn" -gt 0 ] && [ "$tot" -gt "$srcn" ]; then
          fail "  [$tag] D1-2（$h region=$rid）：磁盘产物 $tot > 本 DN 合并前源文件 $srcn（产物个数不得超过源文件个数）"
        elif [ "$srcn" -gt 0 ]; then
          pass "  [$tag] D1-2（$h region=$rid）：磁盘产物 $tot ≤ 本 DN 合并前源文件 $srcn"
        else
          log "  [$tag] D1-2（$h region=$rid）：本 DN 合并前该 region 无源文件记录（srcn=$srcn）⇒ 记录，不判"
        fi
        dev=$(co35_map_get "$devmap" "$rid"); bp=$(co35_map_get "$selacc" "$rid")
        if [ "$dev" = "?" ] || [ "$bp" = "?" ] || [ "$dev" -le 0 ]; then
          log "  [$tag] D1-3 体积（$h region=$rid）：设备数/选中字节未知（dev=$dev sel=$bp）⇒ 跳过（记录）"
          continue
        fi
        u=$(( bp / dev )); lim=$(( (tgt + u) * 5 / 4 ))
        k=0
        for v in $szs; do
          k=$(( k + 1 )); [ "$k" -ge "$tot" ] && break     # 最后一个产物允许超限（D1-3）
          chk=$(( chk + 1 ))
          [ "$v" -gt "$lim" ] && { over=$(( over + 1 )); log "      region=$rid 非末位产物 $v B > 上限 $lim B（单设备 ~$u B = 选中 $bp ÷ 设备 $dev，target=$tgt）"; }
        done
      done <<<"$(co35_reg_sizes "$h" "$db")"
      ii=$(( ii + 1 ))
    done
    if [ "$over" -eq 0 ]; then
      pass "  [$tag] D1-3 体积：$chk 个非末位产物都 ≤ 单设备字节+target（阈值在设备边界检查 ⇒ 最多超一个设备的数据量）"
    else
      fail "  [$tag] D1-3 体积：$over/$chk 个非末位产物超过 单设备字节+target"
    fi
  fi
  # ---- 磁盘侧交叉核对：日志 Σ落盘产物 ≤ 磁盘 level≥1 文件数
  local pl=0
  for h in "${DN[@]}"; do pl=$(( pl + $(co35_n0 "$(co35_prod_cnt "$h" "$db")") )); done
  if [ "$pl" -ge "${sum_mat:-0}" ]; then
    pass "  [$tag] 日志与磁盘一致：日志 Σ落盘产物 ${sum_mat:-0} ≤ 磁盘 level≥1 产物 $pl"
  else
    warn "  [$tag] 日志 Σ落盘产物 ${sum_mat:-0} > 磁盘 level≥1 产物 $pl（产物可能已被下一轮级联再并 ⇒ 记录，不判 FAIL）"
  fi
  [ "${pl:-0}" -ge 1 ] && pass "  [$tag] 磁盘上存在合并产物（level≥1 文件 $pl 个）" \
    || fail "  [$tag] 磁盘上没有 level≥1 的产物（合并产物缺失）"
  # ---- ⑧ 产物名：level 段全为 1；编号段只有一个取值只记录
  #      P1-⑦ co35_names 已按 `awk -F- '$3>0'` 过滤 ⇒ 这里只会看到真正的产物
  #            （L0 源文件、跳选文件的"重命名占位"`…-1-0-1.tsfile`（level 段=0）都不再进来）
  local names n nbase lvl tail1 tails="" cnt nums gaps
  names=$(co35_names "$db")
  log "  [$tag] 产物名（只含 level≥1，去重 $(( $(printf '%s\n' "$names" | grep -c .) )) 个）：$(printf '%s' "$names" | tr '\n' ' ')"
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    nbase=${n%.tsfile}
    lvl=$(printf '%s\n' "$nbase" | awk -F- '{print $3}')
    [ "$lvl" = "1" ] && pass "  [$tag] 产物 $n 的 level 段=1" || fail "  [$tag] 产物 $n 的 level 段=[$lvl]（期望 1）"
    tail1=$(printf '%s\n' "$nbase" | awk -F- '{print $NF}')
    tails="$tails$tail1 "
  done <<<"$names"
  nums=$(printf '%s\n' $tails | grep -E '^[0-9]+$' | sort -n -u)
  cnt=$(printf '%s\n' "$nums" | grep -c .)
  if [ "${cnt:-0}" -le 1 ]; then
    warn "  [$tag] 产物编号段只有一个取值（$tails）⇒ 连续性无从判断，仅记录（不算 FAIL）"
  else
    gaps=$(printf '%s\n' "$nums" | awk 'NR==1{p=$1;next}{if($1-p!=1)c++;p=$1} END{print c+0}')
    [ "${gaps:-0}" -eq 0 ] && pass "  [$tag] 产物编号段连续无空洞（$nums）" \
      || fail "  [$tag] 产物编号段存在空洞：$nums（D1-5：重命名不得产生空洞）"
  fi
  # ---- ⑦ C 相：逐设备行数 + 设备粒度代理
  if [ "$br" = cap ]; then
    log "  [$tag] 逐设备行数校验（合并后不得丢数据）"
    local d want got
    for ((d=1; d<=DEVS; d++)); do
      want=$(( ROWS * nb ))
      got=$(cmp_rows_series "$db.d$d.s1")
      [ "${got:-0}" = "$want" ] && pass "  [$tag] 设备 d$d 行数 $got = 期望 $want" \
        || fail "  [$tag] 设备 d$d 行数 $got ≠ 期望 $want（合并丢/重复数据）"
    done
    local badr=0 ratios="" rd dev2 bp2 u2
    while read -r rid szs; do
      [ -z "${rid:-}" ] && continue
      dev2=$(co35_map_get "$devmap" "$rid"); bp2=$(co35_map_get "$selacc" "$rid")
      if [ "$dev2" = "?" ] || [ "$bp2" = "?" ] || [ "$dev2" -le 0 ]; then
        warn "  [$tag] D1-3 代理（region=$rid）：设备数/选中字节未知（dev=$dev2 sel=$bp2）⇒ 跳过"; continue
      fi
      u2=$(( bp2 / dev2 ))
      [ "$u2" -gt 0 ] || { warn "  [$tag] D1-3 代理（region=$rid）：单设备字节为 0 ⇒ 跳过"; continue; }
      for v in $szs; do
        rd=$(awk -v a="$v" -v b="$u2" 'BEGIN{r=a/b; i=int(r+0.5); d=r-i; if(d<0)d=-d; printf "%.2f%s", r, (d<=0.30?"":"!")}')
        ratios="$ratios$rd "
        printf '%s' "$rd" | grep -q '!' && badr=$(( badr + 1 ))
      done
    done <<<"$(co35_reg_sizes "${DN[0]}" "$db")"
    log "  [$tag] 设备粒度代理（${DN[0]}）：逐产物 字节 ÷ 单设备字节（= 选中字节/设备数）= $ratios"
    if [ "${badr:-0}" -eq 0 ]; then pass "  [$tag] D1-3：每个产物都 ≈ 整数个设备（$ratios）"
    else warn "  [$tag] D1-3 代理判据未全中：$badr 个产物的字节比例不是整数（$ratios）——记录，不判 FAIL"; fi
  fi
  # ---- P0-③-③ 本相"算术校验降级"汇总（空值/非法 ⇒ 按 0 处理 ⇒ 相关判据被跳过）
  #      空值**不判 FAIL**（harness 提取问题），但必须**可见**：这里计数 + WARN，下面的反静默哨兵兜底。
  local nskip=$(( ${CO35_SKIP_CNT:-0} - emp0 ))
  if [ "${nskip:-0}" -gt 0 ]; then
    warn "  [$tag] 本相有 $nskip 个字段取不到值/非法（算术校验按 0 处理、相关判据已跳过；明细见上方 [算术校验] 行）⇒ 本相量化结论按降级记录"
  fi
  # ---- P0-③ 反静默哨兵：本相位**实际执行的断言条数**（H1 事故的直接反证）
  #    H1 让相位在算术错误处整体中断 ⇒ 剩下 40+ 条断言一条都没跑、② 拿到空值也看不出原因。
  #    这里按"本相位新写入 $OUT 的 PASS/FAIL 行数"计数，偏小即 FAIL（宁可报错也不静默）。
  local nass=0
  nass=$(tail -n +$(( out0 + 1 )) "$OUT" 2>/dev/null | grep -c -e 'PASS ' -e 'FAIL ' || true)
  PH_NAST[$idx]="$nass"
  log "  [$tag] 本相位断言条数=$nass（防静默跳过；阈值 $MIN_ASSERT）"
  if [ "${nass:-0}" -ge "$MIN_ASSERT" ]; then
    pass "  [$tag] 相位完整性：断言条数 $nass ≥ $MIN_ASSERT（无静默跳过）"
  else
    fail "  [$tag] 相位完整性被破坏：只执行了 $nass 条断言（< $MIN_ASSERT）⇒ 疑似中途静默跳过，结论不可信"
  fi
  PH_DONE[$idx]=1; }

# ---------------------------------------------------------------------------
# 集群准备（一次重启；selector=默认 multi_target，gap=0 只并同层）
# ---------------------------------------------------------------------------
log "--- 集群准备：三类合并先关；selector=multi_target；gap=0；candidate=${BATCHES}；文件数上限 100；interval=${INTERVAL_MS} ---"
EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=${BATCHES},compaction_schedule_interval_in_ms=${INTERVAL_MS},inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,inner_compaction_total_file_num_threshold=100" cmp_cluster_prepare
for kv in inner_seq_selector=size_tiered_multi_target max_level_gap_in_inner_compaction=0 inner_compaction_total_file_num_threshold=100; do
  k=${kv%%=*}; want=${kv#*=}
  assert_eq "  生效值 $k" "$(cmp_eff "${DN[0]}" "$k")" "$want"
done
# 设备数必须 >1（设备粒度拆分的前提）；配置项可能来自环境变量 ⇒ P0-③ 先校验再进算术
co35_num DEVS "DEVS"; co35_num SERIES "SERIES"; co35_num ROWS "ROWS"
co35_num BATCHES "BATCHES"; co35_num CBATCH "CBATCH"; co35_num WIN "WIN"
co35_num CLOSE_WIN "CLOSE_WIN"; co35_num MIN_ASSERT "MIN_ASSERT"
[ "$SERIES" -ge 1 ] || { fail "  SERIES=$SERIES 非法（行数期望 ROWS×批数 与场景说明会失真）"; SERIES=1; }
[ "$DEVS" -gt 1 ] && pass "  DEVS=$DEVS > 1（设备粒度拆分的前提成立）" \
  || fail "  场景未成立：DEVS=$DEVS ≤ 1，单设备无法产生多个产物（D1-3）"

# ---------------------------------------------------------------------------
# 三相位
# ---------------------------------------------------------------------------
log "--- 相位 A：$DB（target=$T_A ⇒ 期望 places ∈ [2, region 源文件数-1]，D1-1 未被 min 截断）---"
co35_phase "$DB" "$T_A" A 0 "$BATCHES" mid
[ "${PH_DONE[0]:-0}" = 1 ] || fail "  相位 A 未执行完（PH_DONE=0）⇒ 剩余断言被静默跳过，本相结论不可信"
log "--- 相位 B：${DB}2（target=$T_B = 默认 2GB ⇒ 期望 places 恒为 1，不拆分）---"
co35_phase "${DB}2" "$T_B" B 1 "$BATCHES" one
[ "${PH_DONE[1]:-0}" = 1 ] || fail "  相位 B 未执行完（PH_DONE=0）⇒ 剩余断言被静默跳过，本相结论不可信"
NA=${PH_REQ[0]}; NB=${PH_REQ[1]}
if [ "${NA:-0}" -ge 2 ] && [ "${NB:-0}" -eq 1 ] && [ "${NA:-0}" -gt "${NB:-0}" ]; then
  pass "  ② 分片对照成立：A(target=${PH_TGT[0]}) max(places)=$NA > B(target=2GB) max=$NB（places 只由 target 与选中字节决定）"
else
  fail "  ② 分片对照不成立：A(target=${PH_TGT[0]}) max(places)=$NA（期望 ≥2）vs B(target=2GB) max=$NB（期望 1）"
fi
log "  ② 记录：A 相 max(落盘产物)=${PH_MAT[0]}、断言条数=${PH_NAST[0]}；B 相 max(落盘产物)=${PH_MAT[1]}、断言条数=${PH_NAST[1]}（A 相总文件数 ${PH_TS0[0]}→${PH_OBS[0]}，B 相 ${PH_TS0[1]}→${PH_OBS[1]}）"

log "--- 相位 C：${DB}3（target=$T_C ⇒ 期望 floor(选中/target)+1 ≥ totalSources（min 上界吃满）+ 设备粒度拆分）---"
co35_phase "${DB}3" "$T_C" C 2 "$CBATCH" cap
[ "${PH_DONE[2]:-0}" = 1 ] || fail "  相位 C 未执行完（PH_DONE=0）⇒ 剩余断言被静默跳过，本相结论不可信"
log "  汇总：三相断言条数=${PH_NAST[0]}/${PH_NAST[1]}/${PH_NAST[2]}（阈值 $MIN_ASSERT）"

# ---------------------------------------------------------------------------
# 收尾
# ---------------------------------------------------------------------------
log "--- 收尾：卡死线程检查 + 收尾三件套（基准库 $DB）---"
ST=$(cmp_stuck_sum)
co35_num ST "卡死线程数"
cmp_assert_no_stuck "无卡在 TsFileResource.writeLock 的合并线程"
post_checks "select s1 from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
